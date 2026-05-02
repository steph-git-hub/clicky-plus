//
//  RealtimeConversationManager.swift
//  leanring-buddy / Clicky+
//
//  Created 2026-05-01 (v15p) — OpenAI Realtime API integration.
//  Rewritten 2026-05-02 (v15p2) — addresses the audio-thread starvation
//  bug from v15p where the input tap stalled after one ~100ms callback.
//
//  The v15p version made the class @MainActor, which forced every audio-
//  thread access of `appendInputAudio` and friends to synchronously hop
//  to the main actor. That hop blocked the audio render thread, so after
//  the first tap callback the audio system effectively stopped delivering
//  buffers. The result: 4800 bytes of audio captured per session followed
//  by zero, leading the server to interpret near-silent buffers as speech
//  and hallucinate responses (sometimes in Spanish).
//
//  v15p2 design:
//   • Class is NOT @MainActor. It's nonisolated by default.
//   • Audio-thread shared state lives behind `audioStateLock` (NSLock).
//   • Audio tap callback runs on the audio thread end-to-end. No
//     synchronous main-actor hops. The callback locks, mutates buffer
//     state, then asynchronously dispatches state updates to MainActor.
//   • AVAudioConverter resets between buffers so per-buffer state from
//     `.endOfStream` doesn't corrupt the streaming sample-rate conversion.
//   • Two separate AVAudioEngines for input and output so format choices
//     in one graph don't perturb the other (the v15q hotfix3 design,
//     kept because it's good practice even if it wasn't yesterday's bug).
//
//  Architecture:
//    [Mac app: hotkey pressed]
//        ↓ POST /realtime-session
//    [Cloudflare Worker uses OPENAI_API_KEY secret to mint ephemeral token]
//        ↓ ephemeral client_secret (~60s TTL)
//    [Mac app opens wss://api.openai.com/v1/realtime?model=gpt-realtime]
//        ↓ session.update + audio frames
//    [OpenAI Realtime: streams response audio + transcripts]
//        ↓ output audio frames (PCM16 24kHz mono)
//    [AVAudioEngine playback]
//

import AppKit
import AVFoundation
import Combine
import Foundation

/// Possible states of a Realtime conversation session.
enum RealtimeSessionState: Equatable {
    case idle
    case connecting
    case listening
    case responding
    case errored(String)

    var isActive: Bool {
        switch self {
        case .idle, .errored:
            return false
        case .connecting, .listening, .responding:
            return true
        }
    }
}

/// NOT @MainActor on purpose. Only @Published property writes are
/// marshaled to MainActor; everything audio-side runs on the audio
/// render thread without expensive main-actor hops.
final class RealtimeConversationManager: NSObject, ObservableObject {
    // MARK: - Published state for SwiftUI / indicator subscribers
    //
    // All @Published mutations MUST happen on the main actor because
    // SwiftUI subscribers read these. The audio thread updates them via
    // `Task { @MainActor in self.foo = ... }` so the audio thread never
    // blocks waiting for the main thread.

    @Published private(set) var state: RealtimeSessionState = .idle
    @Published private(set) var inputAudioLevel: Float = 0
    @Published private(set) var outputAudioLevel: Float = 0
    @Published private(set) var liveUserTranscript: String = ""
    @Published private(set) var liveAssistantTranscript: String = ""

    // MARK: - Configuration

    private let workerSessionURL = URL(string: "https://clicky-proxy.sapierso.workers.dev/realtime-session")!
    private let openAIRealtimeURL = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!

    // MARK: - WebSocket + audio plumbing

    private let urlSession: URLSession = .shared
    /// Atomic-ish reference to the current websocket task. Reads/writes
    /// must hold `audioStateLock` to be safe across threads.
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    // Two engines. Input only captures, output only plays. Independent.
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let outputPlayer = AVAudioPlayerNode()

    /// PCM16 24kHz mono format — what OpenAI Realtime expects.
    private let pcm16Format: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Failed to create PCM16 24kHz mono format")
        }
        return format
    }()

    /// Single converter created once per audio capture session and
    /// reused across all tap callbacks. Reset between buffers below.
    private var inputConverter: AVAudioConverter?
    private var inputDeviceFormat: AVAudioFormat?

    // MARK: - Audio-thread shared state (protected by audioStateLock)
    //
    // The lock is held only briefly — never across an `await`, never
    // across a network call, only around field mutations. Audio thread
    // is the writer for buffer state; main thread reads counters when
    // logging diagnostics.

    private let audioStateLock = NSLock()
    private var inputAudioBuffer = Data()
    private let targetInputChunkBytes = 24_000 * 2 / 20 // 50ms of PCM16 mono = 2400 bytes
    private var isHotkeyHeld: Bool = false
    /// v15p2 (2026-05-02): hands-free mode flag. When true, audio
    /// streams continuously regardless of hotkey state and the server
    /// uses VAD turn detection to auto-respond. Toggled by Marin via
    /// the set_listening_mode tool. Lives under audioStateLock since
    /// the audio thread reads it on every tap callback.
    private var isContinuousListening: Bool = false

    /// v15p2 (2026-05-02): true while Marin is generating/speaking a
    /// response. Used to drop incoming mic audio so the server's VAD
    /// can't trigger a new response off Marin's own voice played
    /// through the speakers (classic feedback loop). Set on
    /// response.created, cleared on response.done / response.cancel.
    ///
    /// Hotfix2: clearing it requires BOTH `responseDoneReceived` AND
    /// `outputBuffersInFlight == 0` — `response.done` fires when the
    /// model is done GENERATING, but audio is still playing through
    /// the speakers for another ~200-500ms. Re-opening the mic before
    /// playback drains lets server VAD trigger off the speaker echo.
    private var isModelSpeaking: Bool = false
    private var responseDoneReceived: Bool = false
    private var outputBuffersInFlight: Int = 0
    private var bytesSentInCurrentPress: Int = 0
    private var maxInputLevelInCurrentPress: Float = 0
    private var pressStartedAt: Date?

    // Warm session auto-close (continuous conversation).
    private static let warmSessionTimeoutSeconds: TimeInterval = 120
    private var warmSessionAutoCloseTask: Task<Void, Never>?

    // MARK: - Function calling state (v15p2 Chunk 1, 2026-05-02)
    //
    // The Realtime model emits a function_call output item when it
    // wants to invoke one of our locally-defined tools. The lifecycle:
    //   1. response.output_item.added with item.type=function_call →
    //      we record (call_id, name) so we know what tool to dispatch.
    //   2. response.function_call_arguments.delta (zero or more) →
    //      streaming JSON args; we don't need to act on partial args.
    //   3. response.function_call_arguments.done → full args available;
    //      we look up name from pendingFunctionCalls, dispatch.
    //   4. We send conversation.item.create with function_call_output
    //      including the same call_id + the result, then response.create
    //      so Marin continues speaking with the result in context.
    //
    // Pending calls are kept under audioStateLock since both the audio
    // thread and main thread can read the websocket state and these
    // dispatches go through sendJSON which itself locks.

    private var pendingFunctionCalls: [String: String] = [:] // call_id → name

    /// On-screen highlight overlay used by the `highlight_element` tool.
    /// Lazily created on first use; lives on MainActor since it manages
    /// AppKit windows.
    @MainActor private var highlightOverlay: RealtimeHighlightOverlayManager?

    // MARK: - Diagnostics
    //
    // File-based diagnostic so failures surface even when print() doesn't
    // make it to Console. nonisolated so it's callable from any thread.

    static func appendDiag(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/clicky_realtime_diag.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            _ = try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Public API

    /// Start a new session OR resume a warm one. Safe to call from any
    /// thread — internally hops to MainActor for @Published state writes.
    func startSession() {
        // Take the audio lock briefly to update press-state. This MUST
        // happen synchronously on whatever thread called us so audio
        // bytes stop being dropped immediately.
        audioStateLock.lock()
        isHotkeyHeld = true
        inputAudioBuffer.removeAll(keepingCapacity: true)
        bytesSentInCurrentPress = 0
        maxInputLevelInCurrentPress = 0
        pressStartedAt = Date()
        let alreadyActive = state.isActive
        audioStateLock.unlock()

        if alreadyActive {
            // Warm session resumption: cancel pending auto-close,
            // clear any stale server-side audio buffer, send a fresh
            // screenshot for this turn, keep going.
            cancelWarmSessionAutoClose()
            sendJSON(["type": "input_audio_buffer.clear"])
            captureAndSendActiveScreenshot()
            Self.appendDiag("startSession on warm session — continuing")
            return
        }

        Self.appendDiag("startSession requested (cold)")
        Task { @MainActor in
            self.state = .connecting
        }

        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                // v15p2 hotfix (2026-05-02): start audio capture FIRST,
                // before token mint + WebSocket open. The audio tap
                // begins delivering buffers immediately and they
                // accumulate in inputAudioBuffer (gated on isHotkeyHeld
                // = true, which we set on press). Once the WebSocket
                // is up, the accumulated audio gets force-flushed.
                // Without this, the user's first ~500ms of speech was
                // captured into nothing because the engine wasn't
                // running yet.
                try self.startAudioCapture()
                let token = try await self.fetchEphemeralToken()
                try await self.openWebSocket(token: token)
                // Flush any audio captured during the WebSocket setup
                // gap so it arrives at the server in the right order
                // (audio first, then screenshot).
                self.forceFlushAccumulatedAudio()
                // P3: capture + send active-screen screenshot. Fire-
                // and-forget — Realtime processes events in order so
                // the image arrives ahead of the audio commit.
                self.captureAndSendActiveScreenshot()
                await MainActor.run {
                    self.state = .listening
                }
                Self.appendDiag("session ready (state=listening)")
            } catch {
                Self.appendDiag("startSession failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .errored(error.localizedDescription)
                }
                self.teardown()
            }
        }
    }

    /// Hotkey released: commit pending audio + request response, schedule
    /// warm-window auto-close. Safe to call from any thread.
    func handleHotkeyRelease() {
        audioStateLock.lock()
        isHotkeyHeld = false
        let pressMs = pressStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let bytesSent = bytesSentInCurrentPress
        let maxLevel = maxInputLevelInCurrentPress
        audioStateLock.unlock()

        Self.appendDiag(
            "hotkey released — pressMs=\(pressMs) " +
            "bytesSent=\(bytesSent) " +
            "maxLevel=\(String(format: "%.3f", maxLevel)) " +
            "→ committing + warming"
        )
        commitInputAndRequestResponse()
        scheduleWarmSessionAutoClose()
    }

    /// End the active session. Idempotent.
    func endSession() {
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard active else { return }
        Self.appendDiag("endSession requested")
        cancelWarmSessionAutoClose()
        teardown()
    }

    /// v15p2 (2026-05-02): direct API for the hands-free toggle hotkey.
    /// Same effect as the model calling set_listening_mode(true), but
    /// triggered by Fn+Cmd+Opt without involving Marin. If no session
    /// is currently active, starts one in continuous mode right away.
    func engageContinuousListening() {
        // Set the gate flag first so audio flows before/after the
        // server.update arrives.
        audioStateLock.lock()
        isContinuousListening = true
        // Treat hotkey-held semantics as engaged so the audio gate
        // is open without requiring an actual press.
        isHotkeyHeld = true
        audioStateLock.unlock()

        if state.isActive {
            // Already running — push the server-side change.
            cancelWarmSessionAutoClose()
            sendJSON([
                "type": "session.update",
                "session": [
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 800,
                    ],
                ],
            ])
            Self.appendDiag("engageContinuousListening: live toggle on existing session")
        } else {
            // Start cold. Same path as a normal startSession but the
            // gate flag is already set so as soon as the WebSocket
            // opens the session.update we send below will switch
            // turn_detection. Also, the warm-session timeout won't
            // fire because we'll keep cancelling it via continuous
            // mode.
            Self.appendDiag("engageContinuousListening: starting fresh session in continuous mode")
            Task { @MainActor in
                self.state = .connecting
            }
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    try self.startAudioCapture()
                    let token = try await self.fetchEphemeralToken()
                    try await self.openWebSocket(token: token)
                    self.forceFlushAccumulatedAudio()
                    // Push hands-free turn_detection up-front so the
                    // server enters VAD mode from the start.
                    self.sendJSON([
                        "type": "session.update",
                        "session": [
                            "turn_detection": [
                                "type": "server_vad",
                                "threshold": 0.5,
                                "prefix_padding_ms": 300,
                                "silence_duration_ms": 800,
                            ],
                        ],
                    ])
                    self.captureAndSendActiveScreenshot()
                    await MainActor.run {
                        self.state = .listening
                    }
                    Self.appendDiag("engageContinuousListening: session ready")
                } catch {
                    Self.appendDiag("engageContinuousListening failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.state = .errored(error.localizedDescription)
                    }
                    self.teardown()
                }
            }
        }
    }

    /// v15p2 (2026-05-02): direct API to disengage hands-free.
    func disengageContinuousListening() {
        audioStateLock.lock()
        isContinuousListening = false
        isHotkeyHeld = false
        audioStateLock.unlock()
        if state.isActive {
            sendJSON([
                "type": "session.update",
                "session": ["turn_detection": NSNull()],
            ])
            sendJSON(["type": "input_audio_buffer.clear"])
            Self.appendDiag("disengageContinuousListening: back to PTT")
        }
    }

    /// Returns true if Marin is currently generating or playing an
    /// audio response. Used by CompanionManager's Esc handler to
    /// distinguish "interrupt the speech" from "end the session."
    func isModelCurrentlySpeaking() -> Bool {
        audioStateLock.lock(); defer { audioStateLock.unlock() }
        return isModelSpeaking || outputBuffersInFlight > 0
    }

    /// Emergency stop: tell the server to cancel the current response
    /// and drain local playback. Session stays alive — user can keep
    /// speaking immediately.
    ///
    /// v15p2 hotfix (2026-05-02): mic reopen now goes through the
    /// grace-period path. Without it, the mic re-opened the instant
    /// cancel was called, while speaker tail audio was still emitting,
    /// causing server VAD to pick up the echo as user speech and
    /// chain into runaway feedback turns.
    func cancelCurrentResponse() {
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard active else { return }
        Self.appendDiag("cancelCurrentResponse — silencing model")

        sendJSON(["type": "response.cancel"])

        // Stop the player immediately (cuts audio) but keep the
        // isModelSpeaking gate CLOSED so server VAD can't re-trigger
        // off speaker tail. The grace will flip it false safely.
        Task { @MainActor in
            if self.outputPlayer.isPlaying {
                self.outputPlayer.stop()
            }
            if self.outputEngine.isRunning {
                self.outputPlayer.play()
            }
            self.state = .listening
            self.liveAssistantTranscript = ""
            self.outputAudioLevel = 0
        }

        audioStateLock.lock()
        // isModelSpeaking stays TRUE; the grace timer below will
        // flip it to false once any echo tail has died down.
        responseDoneReceived = true
        outputBuffersInFlight = 0
        audioStateLock.unlock()

        // Schedule mic reopen after grace, but DO NOT end session
        // — user explicitly interrupted to speak again.
        scheduleMicReopenAfterGrace(naturalCompletion: false)
    }

    // MARK: - Token mint

    private func fetchEphemeralToken() async throws -> String {
        var request = URLRequest(url: workerSessionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 10
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ClickyRealtimeError",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker /realtime-session returned \(http.statusCode): \(bodyText)"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientSecret = json["client_secret"] as? [String: Any],
              let token = clientSecret["value"] as? String else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Realtime session response missing client_secret.value"]
            )
        }
        return token
    }

    // MARK: - WebSocket lifecycle

    private func openWebSocket(token: String) async throws {
        var request = URLRequest(url: openAIRealtimeURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = urlSession.webSocketTask(with: request)
        audioStateLock.lock()
        webSocketTask = task
        audioStateLock.unlock()
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func runReceiveLoop() async {
        let task: URLSessionWebSocketTask? = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return webSocketTask
        }()
        guard let task = task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleServerEvent(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleServerEvent(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                Self.appendDiag("receive loop ended: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .errored(error.localizedDescription)
                }
                return
            }
        }
    }

    private func handleServerEvent(text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            Self.appendDiag("malformed server event: \(text.prefix(200))")
            return
        }

        switch type {
        case "session.created", "session.updated":
            Self.appendDiag(type)

        case "response.created":
            // Marin is about to speak — silence the mic until both
            // (a) response.done fires AND (b) playback queue drains.
            // v15p2 hotfix2 (2026-05-02).
            audioStateLock.lock()
            isModelSpeaking = true
            responseDoneReceived = false
            // Don't reset outputBuffersInFlight — buffers from a prior
            // response (rare) shouldn't be forgotten. They'll drain on
            // their own.
            audioStateLock.unlock()

        case "input_audio_buffer.speech_started":
            // v15p2 (2026-05-02): if Marin is currently speaking
            // when the user starts a new turn, that's a barge-in
            // (interruption). Server VAD will cancel her response
            // automatically; we need to drain the local playback
            // queue so the audio she already streamed stops coming
            // out of the speakers.
            let wasSpeaking: Bool = {
                audioStateLock.lock(); defer { audioStateLock.unlock() }
                return isModelSpeaking
            }()
            if wasSpeaking {
                Self.appendDiag("speech_started during model response — barge-in detected, draining playback")
                Task { @MainActor in
                    if self.outputPlayer.isPlaying {
                        self.outputPlayer.stop()
                    }
                    if self.outputEngine.isRunning {
                        self.outputPlayer.play()
                    }
                    self.outputAudioLevel = 0
                    self.liveAssistantTranscript = ""
                }
                audioStateLock.lock()
                isModelSpeaking = false
                responseDoneReceived = false
                outputBuffersInFlight = 0
                audioStateLock.unlock()
            }

            Task { @MainActor in
                self.state = .listening
                self.liveUserTranscript = ""
            }
            // v15p2 (2026-05-02): in hands-free mode, refresh the
            // active-screen screenshot at the start of each user turn
            // so Marin sees the CURRENT view rather than whatever was
            // on screen when the session started. Without this, if
            // Steph navigates between turns Marin keeps responding
            // based on the stale screen.
            //
            // Fire-and-forget. By the time the user finishes speaking
            // (~1-2s) and server VAD commits, the screenshot
            // (~50-200ms to capture) has already arrived in the
            // conversation context for the upcoming response.
            //
            // Only fires in continuous mode — PTT already captures
            // per-press in startSession.
            let inContinuous: Bool = {
                audioStateLock.lock(); defer { audioStateLock.unlock() }
                return isContinuousListening
            }()
            if inContinuous {
                captureAndSendActiveScreenshot()
            }

        case "input_audio_buffer.speech_stopped":
            Task { @MainActor in
                self.state = .responding
            }

        case "response.audio.delta":
            if let base64 = json["delta"] as? String,
               let pcmData = Data(base64Encoded: base64) {
                playPCM16Chunk(pcmData)
            }

        case "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                Task { @MainActor in
                    self.liveAssistantTranscript += delta
                }
            }

        // ── Function calling events (v15p2 Chunk 1) ──────────────
        case "response.output_item.added":
            // The model added an output item to the current response.
            // If it's a function_call, capture the call_id → name
            // mapping so we know which tool to dispatch when args arrive.
            if let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                audioStateLock.lock()
                pendingFunctionCalls[callId] = name
                audioStateLock.unlock()
                Self.appendDiag("function_call started: name=\(name) call_id=\(callId)")
            }

        case "response.function_call_arguments.done":
            // Args are complete. Look up the function name, dispatch.
            guard let callId = json["call_id"] as? String,
                  let argumentsJSON = json["arguments"] as? String else {
                Self.appendDiag("function_call_arguments.done malformed: \(text.prefix(200))")
                break
            }
            // Some events include `name` directly; fall back to our map.
            let name: String
            if let directName = json["name"] as? String {
                name = directName
            } else {
                audioStateLock.lock()
                name = pendingFunctionCalls[callId] ?? ""
                audioStateLock.unlock()
            }
            guard !name.isEmpty else {
                Self.appendDiag("function_call: no name for call_id=\(callId)")
                break
            }
            Self.appendDiag("function_call ready: name=\(name) call_id=\(callId) args=\(argumentsJSON.prefix(200))")
            dispatchFunctionCall(name: name, callId: callId, argumentsJSON: argumentsJSON)
            // Clean up pending tracking.
            audioStateLock.lock()
            pendingFunctionCalls.removeValue(forKey: callId)
            audioStateLock.unlock()

        case "response.done":
            writeRealtimeTurnToTranscriptLog()
            // v15p2 hotfix2 (2026-05-02): mark response as done. Mic
            // does NOT reopen yet — wait for the playback queue to
            // drain via handleOutputBufferCompleted. If buffers are
            // already at zero (rare — usually some still queued when
            // response.done arrives), trigger the grace-period reopen
            // here.
            audioStateLock.lock()
            responseDoneReceived = true
            let canReopenNow = outputBuffersInFlight == 0
            audioStateLock.unlock()
            if canReopenNow {
                // Natural completion — PTT mode will auto-end session.
                scheduleMicReopenAfterGrace(naturalCompletion: true)
            }
            Task { @MainActor in
                self.state = .listening
                self.liveAssistantTranscript = ""
                self.liveUserTranscript = ""
            }

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String {
                Task { @MainActor in
                    self.liveUserTranscript += delta
                }
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                Task { @MainActor in
                    self.liveUserTranscript = transcript
                }
            }

        case "error":
            let errorJSON = (json["error"] as? [String: Any]) ?? [:]
            let message = (errorJSON["message"] as? String) ?? text
            Self.appendDiag("server error: \(message)")
            Task { @MainActor in
                self.state = .errored(message)
            }

        default:
            break
        }
    }

    // MARK: - Audio capture (mic → server)
    //
    // CRITICAL: this runs on the audio thread. NO synchronous main-actor
    // hops, NO `await`, NO blocking work. State mutations go through
    // audioStateLock, @Published state goes through async Task @MainActor.

    private func startAudioCapture() throws {
        // ── OUTPUT ENGINE ─ player → mainMixer → speakers ─────────
        if !outputEngine.attachedNodes.contains(outputPlayer) {
            outputEngine.attach(outputPlayer)
        }
        let outputMixer = outputEngine.mainMixerNode
        outputEngine.connect(outputPlayer, to: outputMixer, format: pcm16Format)
        try outputEngine.start()
        if !outputPlayer.isPlaying {
            outputPlayer.play()
        }

        // ── INPUT ENGINE ─ mic → tap (capture only) ───────────────
        let inputNode = inputEngine.inputNode

        // v15p2 (2026-05-02): voice processing was tried for AEC +
        // noise suppression but on Steph's audio device setup it
        // forced a 9-channel input format that broke the PCM16 mono
        // converter (bytesSent=0). Reverted. We rely on the
        // mute-during-speech logic to break the feedback loop and
        // accept that natural voice interruption isn't supported on
        // this hardware — Esc is the kill switch.

        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputDeviceFormat = inputFormat
        Self.appendDiag(
            "input device format: sampleRate=\(inputFormat.sampleRate) " +
            "channels=\(inputFormat.channelCount) " +
            "common=\(inputFormat.commonFormat.rawValue)"
        )

        // One converter, reused across all taps. Reset before each
        // conversion in the tap closure so per-buffer state from
        // `.endOfStream` doesn't accumulate.
        guard let converter = AVAudioConverter(from: inputFormat, to: pcm16Format) else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"]
            )
        }
        inputConverter = converter

        // 100ms tap interval. Can't be too small or we burn CPU on
        // tiny conversions; can't be too large or we add latency.
        let tapBufferSize: AVAudioFrameCount = AVAudioFrameCount(inputFormat.sampleRate * 0.1)

        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handleInputTapBuffer(buffer)
        }

        try inputEngine.start()
        Self.appendDiag("input engine started — tap installed")
    }

    /// Called on the audio render thread. Must be cheap and non-blocking.
    private func handleInputTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = inputConverter,
              let inputFormat = inputDeviceFormat else { return }

        // Compute RMS for level meter — pure math, no I/O.
        let rms = Self.computeRMS(of: buffer)

        // Compute output buffer size for sample-rate conversion.
        let inputFrames = Double(buffer.frameLength)
        let outputFrames = AVAudioFrameCount(inputFrames * 24_000.0 / inputFormat.sampleRate)
        guard outputFrames > 0,
              let pcm16Buffer = AVAudioPCMBuffer(
                pcmFormat: pcm16Format,
                frameCapacity: outputFrames
              ) else { return }

        // Reset converter so per-buffer .endOfStream signaling doesn't
        // corrupt the streaming sample-rate conversion state.
        converter.reset()

        var conversionError: NSError?
        var bufferConsumed = false
        converter.convert(to: pcm16Buffer, error: &conversionError) { _, statusPtr in
            if bufferConsumed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            bufferConsumed = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if let conversionError {
            Self.appendDiag("conversion error: \(conversionError.localizedDescription)")
            return
        }

        let bytes = Self.pcm16Bytes(from: pcm16Buffer)
        guard !bytes.isEmpty else { return }

        // Lock-protected buffer accumulation. NO @MainActor hop here.
        audioStateLock.lock()
        // v15p2 (2026-05-02): hands-free mode treats audio as
        // always-streaming, regardless of hotkey state. Server VAD
        // handles turn detection.
        //
        // While Marin is speaking we DROP mic input. Voice processing
        // (AEC) would let us avoid this and support natural voice
        // interruption, but on Steph's hardware it broke the audio
        // pipeline — see comment above the inputNode setup. So we
        // mute during her speech to prevent feedback. Esc remains
        // the interrupt mechanism.
        let shouldStreamAudio = (isHotkeyHeld || isContinuousListening) && !isModelSpeaking
        let shouldFlush: Bool
        if shouldStreamAudio {
            inputAudioBuffer.append(bytes)
            if rms > maxInputLevelInCurrentPress {
                maxInputLevelInCurrentPress = rms
            }
            // v15p2 hotfix: only flush if the WebSocket is actually
            // open. If we're still in cold-start setup, KEEP
            // accumulating — the audio captured during setup will be
            // force-flushed by `forceFlushAccumulatedAudio` once the
            // WebSocket comes up. Without this gate, sendAudioChunk
            // silently drops bytes when webSocketTask is nil.
            shouldFlush = inputAudioBuffer.count >= targetInputChunkBytes
                && webSocketTask != nil
        } else {
            // Drop buffered bytes from previous press so they don't
            // leak into the next response.
            inputAudioBuffer.removeAll(keepingCapacity: true)
            shouldFlush = false
        }
        let bytesToFlush: Data?
        if shouldFlush {
            bytesToFlush = inputAudioBuffer
            inputAudioBuffer.removeAll(keepingCapacity: true)
            bytesSentInCurrentPress += bytesToFlush?.count ?? 0
        } else {
            bytesToFlush = nil
        }
        audioStateLock.unlock()

        if let bytesToFlush {
            sendAudioChunk(bytesToFlush)
        }

        // Update level meter on main actor without blocking audio thread.
        Task { @MainActor in
            self.inputAudioLevel = rms
        }
    }

    /// Send a chunk of PCM16 bytes to the server.
    /// URLSessionWebSocketTask.send is thread-safe.
    private func sendAudioChunk(_ bytes: Data) {
        let task: URLSessionWebSocketTask? = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return webSocketTask
        }()
        guard let task else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": bytes.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                Self.appendDiag("audio send error: \(error.localizedDescription)")
            }
        }
    }

    /// v15p2 hotfix (2026-05-02): flush all currently-buffered audio
    /// to the server, regardless of chunk threshold. Called once after
    /// the WebSocket comes up during cold-start so audio that was
    /// captured during the token-mint + WebSocket-open gap (~500ms)
    /// reaches the server. Without this, the user's first words are
    /// lost.
    private func forceFlushAccumulatedAudio() {
        audioStateLock.lock()
        let bytesToFlush: Data?
        if !inputAudioBuffer.isEmpty {
            bytesToFlush = inputAudioBuffer
            inputAudioBuffer.removeAll(keepingCapacity: true)
            bytesSentInCurrentPress += bytesToFlush?.count ?? 0
        } else {
            bytesToFlush = nil
        }
        audioStateLock.unlock()
        if let bytesToFlush, !bytesToFlush.isEmpty {
            sendAudioChunk(bytesToFlush)
            Self.appendDiag(
                "post-connect flush: \(bytesToFlush.count) bytes of pre-WebSocket audio"
            )
        }
    }

    /// Tell the server "I'm done speaking, generate a response now."
    private func commitInputAndRequestResponse() {
        // Flush any leftover client-side bytes < threshold.
        audioStateLock.lock()
        let leftover = inputAudioBuffer
        inputAudioBuffer.removeAll(keepingCapacity: true)
        if !leftover.isEmpty {
            bytesSentInCurrentPress += leftover.count
        }
        audioStateLock.unlock()
        if !leftover.isEmpty {
            sendAudioChunk(leftover)
        }
        sendJSON(["type": "input_audio_buffer.commit"])
        sendJSON(["type": "response.create"])
    }

    // MARK: - Vision (active screen capture per press)
    //
    // v15p2 P3 (2026-05-02): per-press screenshot of the cursor's active
    // screen, sent as a conversation.item.create with an input_image
    // content block before the audio commit fires. The model gets fresh
    // visual context every turn so it can answer "what's on my screen"
    // questions truthfully instead of hallucinating.
    //
    // Reuses CompanionScreenCaptureUtility.captureAllScreensAsJPEG —
    // that utility already excludes Clicky's own windows and sorts so
    // the cursor screen is at index 0. We just take that one.

    /// Fire-and-forget screenshot capture + send. Safe to call from any
    /// thread; the actual capture work runs on MainActor (the underlying
    /// utility is @MainActor-isolated).
    ///
    /// v15p2 (2026-05-02): switched from `captureAllScreensAsJPEG` →
    /// `captureActiveScreenAsJPEG`. The all-screens helper sorted by
    /// cursor position then took index 0, but on multi-monitor setups
    /// the cursor-containment check could fail and fall back to the
    /// original SCShareableContent order — leading to "always picks
    /// secondary monitor" behavior. The active-screen helper uses
    /// `NSScreen.main` (the focused-window screen), which is exactly
    /// what users mean by "active screen."
    private func captureAndSendActiveScreenshot() {
        Task { @MainActor in
            do {
                let active = try await CompanionScreenCaptureUtility.captureActiveScreenAsJPEG()
                let base64 = active.imageData.base64EncodedString()
                let payload: [String: Any] = [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": "[\(active.label) — visible to you for this turn]",
                            ],
                            [
                                "type": "input_image",
                                "image_url": "data:image/jpeg;base64,\(base64)",
                            ],
                        ],
                    ],
                ]
                self.sendJSON(payload)
                Self.appendDiag(
                    "vision: sent screenshot — \(active.imageData.count) bytes, " +
                    "\(active.screenshotWidthInPixels)x\(active.screenshotHeightInPixels) px, " +
                    "label=\"\(active.label)\""
                )
            } catch {
                Self.appendDiag("vision: capture failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Tool dispatcher (v15p2 Chunk 1, 2026-05-02)
    //
    // Routes a function call from Marin to a local Swift handler.
    // Handlers can be sync (return value immediately) or async (wrap
    // in a Task and call sendFunctionCallResult when done). After the
    // handler returns, we send `conversation.item.create` with the
    // function_call_output item (includes the same call_id) and then
    // a `response.create` so Marin continues speaking with the
    // result in context.
    //
    // Adding a new tool = three steps:
    //   1. Define it in the Worker /realtime-session route
    //   2. Add a case here that runs the work
    //   3. Make sure the persona / instructions know it's available
    //
    // Errors from tool execution should NOT crash the app. If a tool
    // fails, send back a JSON object like {"error": "<reason>"} so
    // Marin can verbalize the failure.

    private func dispatchFunctionCall(name: String, callId: String, argumentsJSON: String) {
        // Parse arguments. Tools that take no parameters get an
        // empty dictionary.
        let args: [String: Any] = {
            guard let data = argumentsJSON.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return parsed
        }()

        switch name {
        case "get_current_time":
            let result = toolGetCurrentTime(args: args)
            sendFunctionCallResult(callId: callId, name: name, result: result)

        case "set_listening_mode":
            let continuous = (args["continuous"] as? Bool) ?? false
            let result = toolSetListeningMode(continuous: continuous)
            sendFunctionCallResult(callId: callId, name: name, result: result)

        // ── Research tools (v15p2, 2026-05-02) ────────────────
        case "list_scheduled_tasks":
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.listScheduledTasks()
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "list_skills":
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.listSkills()
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "list_plugins":
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.listPlugins()
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "search_obsidian":
            let query = (args["query"] as? String) ?? ""
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.searchObsidian(query: query)
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "read_obsidian_note":
            let path = (args["path"] as? String) ?? ""
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.readObsidianNote(path: path)
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "search_clicky_codebase":
            let query = (args["query"] as? String) ?? ""
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.searchClickyCodebase(query: query)
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "read_clicky_roadmap":
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.readClickyRoadmap()
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "list_memory_files":
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.listMemoryFiles()
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "read_memory_file":
            let memoryName = (args["name"] as? String) ?? ""
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.readMemoryFile(name: memoryName)
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        case "highlight_element":
            // Async because AX search + drawing happens on MainActor.
            // We hop to MainActor, do the work, then call back to send
            // the result. This keeps the audio thread / receive loop
            // unblocked.
            let description = (args["description"] as? String) ?? ""
            let dwellSeconds = (args["dwell_seconds"] as? Double) ?? 4.0
            Task { [weak self] in
                guard let self else { return }
                let result = await self.toolHighlightElement(
                    description: description,
                    dwellSeconds: dwellSeconds
                )
                self.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        default:
            Self.appendDiag("unknown tool: \(name) — sending error to model")
            let errorResult: [String: Any] = ["error": "Tool '\(name)' is not implemented on the Mac client."]
            sendFunctionCallResult(callId: callId, name: name, result: errorResult)
        }
    }

    /// Send the function-call result back to the Realtime session so
    /// Marin can continue speaking. Two events: (1) the conversation
    /// item carrying the result, (2) response.create to trigger the
    /// next speech turn.
    private func sendFunctionCallResult(callId: String, name: String, result: Any) {
        // Stringify the result. The server expects `output` to be a
        // string (typically JSON), even for trivial values.
        let outputString: String
        if let str = result as? String {
            outputString = str
        } else if let data = try? JSONSerialization.data(withJSONObject: result),
                  let json = String(data: data, encoding: .utf8) {
            outputString = json
        } else {
            outputString = "{}"
        }

        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputString,
            ],
        ]
        sendJSON(item)
        sendJSON(["type": "response.create"])
        Self.appendDiag("function_call result sent: name=\(name) call_id=\(callId) output=\(outputString.prefix(200))")
    }

    // MARK: - Tool implementations

    /// Returns true if the given app's AX tree is too sparse / noisy
    /// to use for element finding. These are mostly browsers (Chrome,
    /// Safari, etc.) where AX only exposes the chrome (tabs, toolbar)
    /// rather than page content, and Electron apps where AX coverage
    /// is unreliable.
    ///
    /// For these, the highlight_element tool skips AX entirely and
    /// goes straight to vision. v15p2 hotfix3 (2026-05-02).
    private func isAXUnreliableApp(bundleID: String) -> Bool {
        let unreliable: Set<String> = [
            // Browsers — only browser chrome exposed via AX.
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.google.Chrome.beta",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "org.mozilla.nightly",
            "company.thebrowser.Browser", // Arc
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            // Electron / Chromium-based desktop apps — AX is patchy.
            "com.anthropic.claudefordesktop",  // Cowork / Claude desktop
            "com.openai.chat",                 // ChatGPT Atlas
            "com.tinyspeck.slackmacgap",       // Slack
            "com.hnc.Discord",                 // Discord
            "com.microsoft.teams2",            // Microsoft Teams
            "com.figma.Desktop",               // Figma
            "com.notion.id",                   // Notion
            "md.obsidian",                     // Obsidian
            "com.linear",                      // Linear
            "com.electron.cursor",             // Cursor
            "com.todesktop.230313mzl4w4u92",   // Cursor (alt bundle)
        ]
        return unreliable.contains(bundleID)
    }

    /// v15p2 (2026-05-02): hands-free toggle. Switches the session
    /// between push-to-talk (default) and continuous listening with
    /// server-side VAD turn detection.
    ///
    /// Implementation: send `session.update` to flip turn_detection
    /// (null ↔ server_vad), and toggle the local audio gate. The
    /// audio engine + tap stay running across the toggle so there's
    /// no setup latency.
    private func toolSetListeningMode(continuous: Bool) -> [String: Any] {
        // Update the local gate first so audio behavior switches
        // before we send the session.update event (avoids a brief
        // window where the server expects continuous audio but we're
        // still gating on hotkey).
        audioStateLock.lock()
        isContinuousListening = continuous
        audioStateLock.unlock()

        if continuous {
            // Switch the server to use VAD turn detection. Threshold
            // tuned a bit higher than default 0.5 to reduce false
            // triggers from background noise during tutoring.
            let updatePayload: [String: Any] = [
                "type": "session.update",
                "session": [
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 800,
                    ],
                ],
            ]
            sendJSON(updatePayload)
            Self.appendDiag("set_listening_mode: ENGAGED hands-free (server_vad)")
            return [
                "status": "ok",
                "mode": "continuous",
                "note": "Hands-free engaged. Steph can speak naturally without holding any keys.",
            ]
        } else {
            // Switch back to manual mode (client commits explicitly
            // on hotkey release).
            let updatePayload: [String: Any] = [
                "type": "session.update",
                "session": [
                    "turn_detection": NSNull(),
                ],
            ]
            sendJSON(updatePayload)
            // Clear any in-flight audio buffer on the server side so
            // residual noise from the transition doesn't trigger a
            // bonus response.
            sendJSON(["type": "input_audio_buffer.clear"])
            Self.appendDiag("set_listening_mode: DISENGAGED hands-free (back to PTT)")
            return [
                "status": "ok",
                "mode": "push_to_talk",
                "note": "Back to push-to-talk. Steph holds Fn+Opt for each turn.",
            ]
        }
    }

    /// Returns the current local date/time. Trivial sanity-check tool
    /// for Chunk 1 — proves the function-calling round trip works.
    private func toolGetCurrentTime(args: [String: Any]) -> [String: Any] {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let humanReadable = formatter.string(from: now)
        let iso = ISO8601DateFormatter().string(from: now)
        return [
            "human_readable": humanReadable,
            "iso8601": iso,
            "timezone_identifier": TimeZone.current.identifier,
        ]
    }

    /// Find a UI element matching the description and draw a magenta
    /// highlight on it for the dwell duration. Strategy:
    ///
    ///   1. AX search (fast, ~50ms when it works). Native macOS apps,
    ///      most well-built apps. Strong score → use the AX rect.
    ///   2. Vision fallback (~1-2s). Capture the active screen, send
    ///      to Sonnet with the description, get a bounding box back.
    ///      Used when AX has no match, OR when AX has a weak match
    ///      (low score → likely false positive on a single keyword).
    ///
    /// Returns a JSON-friendly status describing what was found.
    @MainActor
    private func toolHighlightElement(
        description: String,
        dwellSeconds: Double
    ) async -> [String: Any] {
        guard !description.isEmpty else {
            return ["status": "error", "reason": "empty description"]
        }
        let clampedDwell = max(1.0, min(15.0, dwellSeconds))

        // Lazily create the overlay manager on first use.
        if highlightOverlay == nil {
            highlightOverlay = RealtimeHighlightOverlayManager()
        }

        // ── Path 1: AX search (skipped for web/Electron) ──────────
        // For browsers and Electron apps, the AX tree only exposes
        // the chrome (tabs, menu bar, toolbar buttons) — never the
        // actual page content the user is asking about. Going to
        // vision directly avoids guaranteed false positives like
        // "highlight the email body" → "New Tab" (the tab strip's
        // role description happened to contain 'tab').
        // v15p2 hotfix3 (2026-05-02).
        let frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let shouldSkipAX = isAXUnreliableApp(bundleID: frontAppBundleID)
        if shouldSkipAX {
            Self.appendDiag(
                "highlight_element: skipping AX for app=\(frontAppBundleID) (web/Electron) — straight to vision"
            )
        }

        // Threshold for "AX is confident": score must be >= 6. Below
        // that, the match is likely a single-keyword false positive.
        let axHit = shouldSkipAX ? nil : AXElementSearch.find(description: description)
        if let hit = axHit, hit.score >= 6 {
            highlightOverlay?.show(
                screenRect: hit.screenRect,
                label: hit.matchedDescription,
                dwellSeconds: clampedDwell
            )
            Self.appendDiag(
                "highlight_element AX hit: \"\(hit.matchedDescription)\" " +
                "score=\(hit.score) " +
                "rect=\(Int(hit.screenRect.origin.x)),\(Int(hit.screenRect.origin.y)) " +
                "\(Int(hit.screenRect.width))x\(Int(hit.screenRect.height)) " +
                "dwell=\(clampedDwell)s"
            )
            return [
                "status": "ok",
                "method": "ax",
                "matched_label": hit.matchedDescription,
                "match_score": hit.score,
                "dwell_seconds": clampedDwell,
            ]
        }

        // ── Path 2: Vision fallback ──────────────────────────────
        // AX missed (or was too weak) — capture the active screen
        // and ask Sonnet to find the element. Slower but works on
        // web pages, Electron, anywhere AX can't see.
        if let axHit {
            Self.appendDiag(
                "highlight_element AX weak (score=\(axHit.score), label=\"\(axHit.matchedDescription)\") — falling back to vision"
            )
        } else {
            Self.appendDiag("highlight_element AX miss — falling back to vision")
        }

        do {
            let visionRect = try await findElementViaVision(description: description)
            if let visionRect {
                highlightOverlay?.show(
                    screenRect: visionRect,
                    label: description,
                    dwellSeconds: clampedDwell
                )
                Self.appendDiag(
                    "highlight_element vision hit: " +
                    "rect=\(Int(visionRect.origin.x)),\(Int(visionRect.origin.y)) " +
                    "\(Int(visionRect.width))x\(Int(visionRect.height)) " +
                    "dwell=\(clampedDwell)s"
                )
                return [
                    "status": "ok",
                    "method": "vision",
                    "matched_label": description,
                    "dwell_seconds": clampedDwell,
                ]
            } else {
                Self.appendDiag("highlight_element vision: not found")
                return [
                    "status": "not_found",
                    "reason": "I couldn't find that element on screen, even with vision. Could you describe it differently?",
                ]
            }
        } catch {
            Self.appendDiag("highlight_element vision error: \(error.localizedDescription)")
            return [
                "status": "error",
                "reason": "Vision lookup failed: \(error.localizedDescription)",
            ]
        }
    }

    /// Capture the active screen, send the screenshot + description
    /// to the Worker's /find-ui-element route, parse Sonnet's bounding
    /// box, scale from screenshot pixel space back to screen point
    /// space, return as a CGRect ready for the highlight overlay.
    /// Returns nil if Sonnet says the element isn't visible.
    @MainActor
    private func findElementViaVision(description: String) async throws -> CGRect? {
        // Fresh capture for the lookup. We could reuse the per-press
        // screenshot we already sent to Marin, but a dedicated capture
        // is simpler and the user might have changed screens since.
        let screen = try await CompanionScreenCaptureUtility.captureActiveScreenAsJPEG()
        let base64 = screen.imageData.base64EncodedString()

        guard let url = URL(string: "https://clicky-proxy.sapierso.workers.dev/find-ui-element") else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Bad Worker URL for /find-ui-element"]
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "description": description,
            "imageBase64": base64,
            "imageWidth": screen.screenshotWidthInPixels,
            "imageHeight": screen.screenshotHeightInPixels,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ClickyRealtimeError",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker /find-ui-element returned \(http.statusCode): \(bodyText)"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Could not parse vision response"]
            )
        }
        guard let found = json["found"] as? Bool, found,
              let bbox = json["bbox_pixels"] as? [String: Any],
              let bx = (bbox["x"] as? NSNumber).map({ $0.doubleValue }),
              let by = (bbox["y"] as? NSNumber).map({ $0.doubleValue }),
              let bw = (bbox["w"] as? NSNumber).map({ $0.doubleValue }),
              let bh = (bbox["h"] as? NSNumber).map({ $0.doubleValue }),
              bw > 0, bh > 0 else {
            // Sonnet said "not found" or the response shape was off.
            return nil
        }

        // Scale from screenshot pixel coords (origin top-left) to
        // screen point coords on the active screen, then convert to
        // global AppKit coords (bottom-left origin) by adding the
        // active screen's frame origin.
        let imgW = Double(screen.screenshotWidthInPixels)
        let imgH = Double(screen.screenshotHeightInPixels)
        let scaleX = Double(screen.displayWidthInPoints) / imgW
        let scaleY = Double(screen.displayHeightInPoints) / imgH
        let pointWidth = bw * scaleX
        let pointHeight = bh * scaleY
        // Image origin is top-left; flip y to AppKit bottom-left
        // origin within the screen, then offset by the screen's
        // global AppKit origin.
        let pointX_local = bx * scaleX
        let pointTop_localFromTop = by * scaleY  // distance from top of screen
        let pointY_localFromBottom = Double(screen.displayHeightInPoints) - pointTop_localFromTop - pointHeight

        let globalRect = CGRect(
            x: screen.displayFrame.origin.x + CGFloat(pointX_local),
            y: screen.displayFrame.origin.y + CGFloat(pointY_localFromBottom),
            width: CGFloat(pointWidth),
            height: CGFloat(pointHeight)
        )
        return globalRect
    }

    // MARK: - Audio playback (server → speakers)

    private func playPCM16Chunk(_ pcmData: Data) {
        let bytesPerFrame = 2
        let frameCount = AVAudioFrameCount(pcmData.count / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: pcm16Format,
                frameCapacity: frameCount
              ) else { return }
        pcmBuffer.frameLength = frameCount

        pcmData.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress,
                  let dst = pcmBuffer.int16ChannelData?.pointee else { return }
            memcpy(dst, baseAddress, pcmData.count)
        }

        let rms = Self.computeRMS(of: pcmBuffer)
        // Track this buffer as "in flight" so we know when playback
        // truly finishes. Server's response.done fires when generation
        // is complete, but the queue here may still have several
        // chunks of audio left to play. Mic must stay muted until
        // these all finish, otherwise speaker echo re-triggers VAD.
        audioStateLock.lock()
        outputBuffersInFlight += 1
        audioStateLock.unlock()
        Task { @MainActor in
            self.outputAudioLevel = rms
            self.outputPlayer.scheduleBuffer(
                pcmBuffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }
                self.handleOutputBufferCompleted()
            }
        }
    }

    /// Called from the audio thread when an output buffer finishes
    /// playing through the speakers. Decrements the in-flight counter
    /// and, if both `response.done` has arrived AND no buffers remain,
    /// re-opens the mic gate after a small grace period for any
    /// acoustic echo tail.
    private func handleOutputBufferCompleted() {
        audioStateLock.lock()
        outputBuffersInFlight = max(0, outputBuffersInFlight - 1)
        let shouldReopenMic = responseDoneReceived && outputBuffersInFlight == 0
        audioStateLock.unlock()
        if shouldReopenMic {
            // Buffer-completion path = natural response end (response.done
            // already fired and last buffer just finished). PTT will
            // auto-end session.
            scheduleMicReopenAfterGrace(naturalCompletion: true)
        }
    }

    /// v15p2 hotfix (2026-05-02): bumped from 250ms → 500ms. Speaker
    /// tail can outlast the player.completionCallback by ~100-300ms
    /// due to OS audio output buffering. Longer grace prevents server
    /// VAD from triggering on echo.
    private static let micReopenGraceSeconds: Double = 0.5

    /// Schedule the mic to re-open after a grace period for echo tail.
    ///
    /// - Parameter naturalCompletion: true if `response.done` fired
    ///   normally (not cancelled). When true AND in PTT mode, we
    ///   also end the session (no warm window). When false (Esc
    ///   cancellation), we never end the session — user wants to
    ///   keep talking.
    private func scheduleMicReopenAfterGrace(naturalCompletion: Bool) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micReopenGraceSeconds * 1_000_000_000))
            guard let self else { return }
            self.audioStateLock.lock()
            // Re-check conditions in case a new response started
            // during the grace period.
            let stillSafe = self.responseDoneReceived && self.outputBuffersInFlight == 0
            let isContinuous = self.isContinuousListening
            if stillSafe {
                self.isModelSpeaking = false
                self.inputAudioBuffer.removeAll(keepingCapacity: true)
            }
            self.audioStateLock.unlock()
            guard stillSafe else { return }

            Self.appendDiag("mic reopened after playback drain + grace")

            // PTT mode + natural completion → end session. No warm
            // window. Cancellation paths pass naturalCompletion=false
            // so the user can keep talking after they Esc-interrupted.
            if naturalCompletion && !isContinuous {
                Self.appendDiag("PTT mode — ending session after response complete (no warm window)")
                self.endSession()
            }
        }
    }

    // MARK: - Send helpers

    private func sendJSON(_ payload: [String: Any]) {
        let task: URLSessionWebSocketTask? = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return webSocketTask
        }()
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                Self.appendDiag("send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Warm session auto-close

    private func cancelWarmSessionAutoClose() {
        warmSessionAutoCloseTask?.cancel()
        warmSessionAutoCloseTask = nil
    }

    private func scheduleWarmSessionAutoClose() {
        cancelWarmSessionAutoClose()
        // v15p2 (2026-05-02): when hands-free is engaged, don't
        // schedule the warm-session timeout. The user explicitly asked
        // for an open mic; auto-closing would frustrate them mid-tutorial.
        let isHandsFree: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return isContinuousListening
        }()
        if isHandsFree {
            return
        }
        warmSessionAutoCloseTask = Task { [weak self] in
            let seconds = Self.warmSessionTimeoutSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Self.appendDiag("warm session timeout — closing")
            self?.endSession()
        }
    }

    // MARK: - Teardown

    private func teardown() {
        warmSessionAutoCloseTask?.cancel()
        warmSessionAutoCloseTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        let task: URLSessionWebSocketTask? = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            let t = webSocketTask
            webSocketTask = nil
            return t
        }()
        task?.cancel(with: .goingAway, reason: nil)

        // Audio engine teardown happens on whatever thread we're on.
        // AVAudioEngine.stop is synchronous and safe.
        if inputEngine.isRunning {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        }
        inputConverter = nil
        inputDeviceFormat = nil

        Task { @MainActor in
            if self.outputPlayer.isPlaying {
                self.outputPlayer.stop()
            }
            if self.outputEngine.isRunning {
                self.outputEngine.stop()
            }
        }

        audioStateLock.lock()
        inputAudioBuffer.removeAll()
        isHotkeyHeld = false
        // v15p2: each new session starts in PTT mode; Marin can
        // toggle hands-free on again if she's tutoring.
        isContinuousListening = false
        isModelSpeaking = false
        responseDoneReceived = false
        outputBuffersInFlight = 0
        audioStateLock.unlock()

        Task { @MainActor in
            self.inputAudioLevel = 0
            self.outputAudioLevel = 0
            self.liveUserTranscript = ""
            self.liveAssistantTranscript = ""
            if self.state.isActive {
                self.state = .idle
            }
        }
    }

    // MARK: - Transcript log

    private func writeRealtimeTurnToTranscriptLog() {
        // Snapshot transcripts on the main actor since they're @Published.
        Task { @MainActor in
            let userTranscript = self.liveUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantTranscript = self.liveAssistantTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userTranscript.isEmpty || !assistantTranscript.isEmpty else {
                Self.appendDiag("turn complete but both transcripts empty — skipping log")
                return
            }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            let log = ClickyInteractionLog(
                id: ClickyTranscriptLogger.newInteractionId(),
                timestamp: Date(),
                mode: .realtime,
                rawTranscript: userTranscript.isEmpty ? nil : userTranscript,
                finalOutput: nil,
                claudeResponse: assistantTranscript.isEmpty ? nil : assistantTranscript,
                polishModifier: nil,
                appName: appName,
                screenshotPaths: [],
                polishStatus: nil
            )
            ClickyTranscriptLogger.shared.log(log)
            Self.appendDiag("turn logged: user=\(userTranscript.count) chars, assistant=\(assistantTranscript.count) chars")
        }
    }

    // MARK: - Static helpers (pure, thread-safe)

    private static func computeRMS(of buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        if let int16Data = buffer.int16ChannelData?.pointee {
            var sum: Double = 0
            for i in 0..<frameCount {
                let sample = Double(int16Data[i]) / Double(Int16.max)
                sum += sample * sample
            }
            let rms = sqrt(sum / Double(frameCount))
            return Float(min(1.0, rms * 2.0))
        }
        if let floatData = buffer.floatChannelData?.pointee {
            var sum: Double = 0
            for i in 0..<frameCount {
                let sample = Double(floatData[i])
                sum += sample * sample
            }
            let rms = sqrt(sum / Double(frameCount))
            return Float(min(1.0, rms * 2.0))
        }
        return 0
    }

    private static func pcm16Bytes(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        let byteCount = frameCount * 2
        guard byteCount > 0,
              let int16Data = buffer.int16ChannelData?.pointee else {
            return Data()
        }
        return Data(bytes: int16Data, count: byteCount)
    }
}
