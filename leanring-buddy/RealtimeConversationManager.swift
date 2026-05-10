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
import CoreAudio
import Foundation

/// A completed Marin conversation turn — used by the panel's live
/// log view. Identifiable so SwiftUI can render in a ForEach.
struct RealtimeTurn: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let user: String
    let assistant: String
}

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

    /// v15p2 (2026-05-03): rolling log of completed turns in the
    /// current session, surfaced in the panel as a scrollable
    /// conversation view. Capped at 30 entries; cleared on cold
    /// session start (so each session is its own conversation).
    /// In-flight turn is shown separately via the live transcripts.
    @Published private(set) var completedTurns: [RealtimeTurn] = []
    static let maxCompletedTurnsInLog = 30

    // MARK: - Configuration

    private let workerSessionURL = URL(string: "https://clicky-proxy.sapierso.workers.dev/realtime-session")!
    // v15p3e (2026-05-08): upgraded to gpt-realtime-2 (GPT-5-class reasoning,
    // 128K context, GA). Worker side migrated to /v1/realtime/client_secrets.
    private let openAIRealtimeURL = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2")!

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

    /// v15p2 (2026-05-03): suspend-during-other-modes. When Steph
    /// holds a non-Marin chord (VTT/Typing/Polish/Capture/Burst/
    /// Base PTT) while a Marin session is active, this gate goes
    /// high — we mute mic input, cancel any in-flight response,
    /// and stop TTS playback so the modes don't fight. Released
    /// when ALL other-mode chords are released.
    private var isSuspendedByOtherMode: Bool = false

    // Warm session auto-close (continuous conversation).
    private static let warmSessionTimeoutSeconds: TimeInterval = 120
    private var warmSessionAutoCloseTask: Task<Void, Never>?

    /// v15p2 (2026-05-03): incremented on every startSession /
    /// engageContinuousListening. Grace tasks (scheduleMicReopen-
    /// AfterGrace) capture the value at schedule time and refuse to
    /// fire their endSession if the generation has changed since —
    /// prevents an old PTT session's pending teardown from killing
    /// a freshly-engaged hands-free session.
    private var sessionGeneration: UInt64 = 0

    /// v15p3 (2026-05-06): track the detached engagement task from
    /// `engageContinuousListening` so `disengageContinuousListening`
    /// can cancel it. Previously fire-and-forget — if the user
    /// double-toggled hands-free during a slow token-mint or WebSocket
    /// open, the original engagement task would continue, eventually
    /// call `startBridgePolling()` and set `state = .listening`, and
    /// resurrect a session the user just dismissed. The task itself
    /// uses the `aborted()` generation check internally, but disengage
    /// previously didn't bump the generation — so the check wasn't
    /// enough on its own. Now we track + cancel explicitly.
    private var continuousEngagementTask: Task<Void, Never>?

    /// v15p2 (2026-05-03): set true when cancelCurrentResponse fires.
    /// Audio chunks arriving from the server after cancel are dropped
    /// instead of scheduled into the player — without this, Marin
    /// keeps speaking for a few hundred ms after Esc because the
    /// server takes time to honor response.cancel and the in-flight
    /// chunks were still being scheduled. Cleared on response.created
    /// for the next response.
    private var responseWasCancelled: Bool = false

    /// v15p2 (2026-05-03): hard timeout for PTT mode commits. After
    /// commitInputAndRequestResponse fires, we expect response.done
    /// within ~15s. If it doesn't arrive (e.g. server hung, silent
    /// commit ignored, network blip), force-end the session so we
    /// don't get a stuck zombie. Cancelled on response.done.
    private static let pttResponseTimeoutSeconds: TimeInterval = 15
    private var pttResponseTimeoutTask: Task<Void, Never>?

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

    // MARK: - Init

    override init() {
        super.init()
        // v15p3q (2026-05-08): subscribe to AVAudioEngineConfigurationChange
        // so plugging/unplugging headphones mid-conversation doesn't kill
        // mic capture. macOS reroutes default audio devices on plug/unplug
        // events; AVAudioEngine doesn't auto-follow — the input tap stays
        // bound to the now-disconnected old device and silently stops
        // delivering buffers. Steph reported: "If I take my headphones out
        // or put them in during the conversation, she can't hear me anymore."
        // The notification fires from the engine itself when its hardware
        // configuration becomes invalid; standard pattern is to restart the
        // engine in the handler.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: inputEngine
        )
        // Output engine config changes too — we listen separately so we can
        // react to either side reconfiguring.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: outputEngine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAudioEngineConfigurationChange(_ note: Notification) {
        // The engine has been auto-stopped by the system. Restart input
        // capture so the new default device starts delivering buffers.
        // Don't touch the WebSocket — the conversation continues with the
        // new mic seamlessly. Skip if we don't actually have a session
        // running (no point reinitializing audio for nothing).
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard active else {
            Self.appendDiag("audio config change ignored — no active session")
            return
        }
        Self.appendDiag("audio engine config changed (likely device plug/unplug) — restarting input capture")
        // Force the external-audio cache to refresh so barge-in re-evaluates
        // immediately under the new device, rather than waiting for the 1s TTL.
        Self.externalAudioOutputCheckedAt = .distantPast
        do {
            try startAudioCapture()
            Self.appendDiag("audio engine restart succeeded — mic capture resumed")
        } catch {
            Self.appendDiag("audio engine restart FAILED: \(error.localizedDescription)")
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
        // v15p2 (2026-05-03): bump session generation so any pending
        // grace tasks from prior sessions can't end this one.
        audioStateLock.lock()
        sessionGeneration &+= 1
        let myGeneration = sessionGeneration
        audioStateLock.unlock()
        // v15p2 (2026-05-03): clear panel log so each session is its
        // own conversation. The persistent history feeds the model
        // separately on session.created.
        Task { @MainActor in
            self.completedTurns.removeAll()
            self.state = .connecting
        }

        Task.detached { [weak self] in
            guard let self = self else { return }

            // v15p2 hotfix (2026-05-03): generation guard — abort if
            // the session was torn down before we finished startup.
            // Race: short tap fires endSession() while we're still
            // inside this Task. Without this check, the Task would
            // continue past teardown and set state back to .listening,
            // leaving a zombie session.
            func aborted() -> Bool {
                self.audioStateLock.lock()
                defer { self.audioStateLock.unlock() }
                return self.sessionGeneration != myGeneration
            }

            // v15p2 hotfix (2026-05-03): startup watchdog. If audio
            // engine init hangs (CoreAudio can stall when a previous
            // session's teardown hasn't fully settled), force-end so
            // Steph isn't stuck looking at a pink indicator forever.
            let watchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                guard let self else { return }
                guard !Task.isCancelled else { return }
                let stillStarting: Bool = {
                    self.audioStateLock.lock(); defer { self.audioStateLock.unlock() }
                    if self.sessionGeneration != myGeneration { return false }
                    return self.state == .connecting
                }()
                if stillStarting {
                    Self.appendDiag("startSession watchdog — audio init hung past 5s, force-ending stuck session")
                    self.endSession()
                }
            }

            do {
                try self.startAudioCapture()
                if aborted() { return }
                let token = try await self.fetchEphemeralToken()
                if aborted() {
                    Self.appendDiag("startSession aborted after token mint — generation changed")
                    return
                }
                try await self.openWebSocket(token: token)
                if aborted() {
                    Self.appendDiag("startSession aborted after WebSocket open — generation changed; tearing down newly-opened socket")
                    self.teardown()
                    return
                }
                self.forceFlushAccumulatedAudio()
                self.captureAndSendActiveScreenshot()
                await MainActor.run {
                    if !aborted() {
                        self.state = .listening
                    }
                }
                if aborted() {
                    Self.appendDiag("startSession aborted just before listening — tearing down")
                    self.teardown()
                    return
                }
                Self.appendDiag("session ready (state=listening)")
                // Cancel the startup watchdog — we made it through.
                watchdogTask.cancel()
            } catch {
                Self.appendDiag("startSession failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.state = .errored(error.localizedDescription)
                }
                self.teardown()
                watchdogTask.cancel()
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

        // v15p2 (2026-05-03): treat very short / silent presses as
        // misclicks. Without this, the server gets a near-empty or
        // pure-silence commit, may not produce a response.done, and
        // the session lingers forever. Three guards:
        //   • too short: pressMs < 250 (clear misclick)
        //   • too few bytes: bytesSent < 8000 (cold start race)
        //   • no actual speech: maxLevel < 0.005 (held key but
        //     never spoke — ambient noise floor is ~0.001-0.003,
        //     real speech is 0.01+)
        let pressTooShort = pressMs < 250 || bytesSent < 8000
        let noActualSpeech = maxLevel < 0.005
        if pressTooShort || noActualSpeech {
            let reason: String
            if pressTooShort && noActualSpeech {
                reason = "too short and no speech"
            } else if pressTooShort {
                reason = "too short"
            } else {
                reason = "no speech detected (maxLevel=\(String(format: "%.4f", maxLevel)))"
            }
            Self.appendDiag(
                "hotkey released — pressMs=\(pressMs) bytesSent=\(bytesSent) maxLevel=\(String(format: "%.4f", maxLevel)) → \(reason), ending session immediately (no commit)"
            )
            endSession()
            return
        }

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
        // v15p2 (2026-05-03): bump generation BEFORE the active check
        // so any in-flight startSession Task aborts even if state is
        // still .connecting (not yet .listening). Without this, a
        // short-tap PTT race where release fires during async startup
        // would let the startSession chain complete past the abort
        // checkpoints because generation hadn't changed.
        audioStateLock.lock()
        sessionGeneration &+= 1
        audioStateLock.unlock()
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
                    "type": "realtime",
                    "audio": [
                        "input": [
                            "turn_detection": [
                                "type": "server_vad",
                                "threshold": 0.5,
                                "prefix_padding_ms": 300,
                                "silence_duration_ms": 800,
                            ],
                        ],
                    ],
                ],
            ])
            Self.appendDiag("engageContinuousListening: live toggle on existing session")
            // v15p2 (2026-05-03): kick off bridge polling for the
            // already-running session too.
            startBridgePolling()
        } else {
            // Start cold. Same path as a normal startSession but the
            // gate flag is already set so as soon as the WebSocket
            // opens the session.update we send below will switch
            // turn_detection. Also, the warm-session timeout won't
            // fire because we'll keep cancelling it via continuous
            // mode.
            Self.appendDiag("engageContinuousListening: starting fresh session in continuous mode")
            // v15p2 (2026-05-03): bump session generation so any
            // pending grace tasks from prior sessions can't end this
            // one. Fixes "engage right after another mode kills the
            // new session" bug.
            audioStateLock.lock()
            sessionGeneration &+= 1
            let myGeneration = sessionGeneration
            audioStateLock.unlock()
            // v15p2 (2026-05-03): clear panel log on fresh session.
            Task { @MainActor in
                self.completedTurns.removeAll()
                self.state = .connecting
            }
            // v15p3 (2026-05-06): cancel any prior engagement task
            // before spawning a new one. Belt-and-suspenders for the
            // generation check below — explicit cancellation makes
            // `Task.isCancelled` true within the prior task too, so
            // the cooperative checks scattered through it can short-
            // circuit cleanly.
            continuousEngagementTask?.cancel()
            continuousEngagementTask = Task.detached { [weak self] in
                guard let self else { return }
                func aborted() -> Bool {
                    if Task.isCancelled { return true }
                    self.audioStateLock.lock()
                    defer { self.audioStateLock.unlock() }
                    return self.sessionGeneration != myGeneration
                }
                do {
                    try self.startAudioCapture()
                    if aborted() { return }
                    let token = try await self.fetchEphemeralToken()
                    if aborted() { return }
                    try await self.openWebSocket(token: token)
                    if aborted() { self.teardown(); return }
                    self.forceFlushAccumulatedAudio()
                    // Push hands-free turn_detection up-front so the
                    // server enters VAD mode from the start.
                    self.sendJSON([
                        "type": "session.update",
                        "session": [
                            "type": "realtime",
                            "audio": [
                                "input": [
                                    "turn_detection": [
                                        "type": "server_vad",
                                        "threshold": 0.5,
                                        "prefix_padding_ms": 300,
                                        "silence_duration_ms": 800,
                                    ],
                                ],
                            ],
                        ],
                    ])
                    self.captureAndSendActiveScreenshot()
                    await MainActor.run {
                        self.state = .listening
                    }
                    Self.appendDiag("engageContinuousListening: session ready")
                    // v15p2 (2026-05-03): kick off bridge polling now
                    // that the session is up.
                    self.startBridgePolling()
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
        // v15p3 (2026-05-06): cancel any in-flight engagement task that
        // hasn't reached `state = .listening` yet. Without this, a
        // disengage during a slow token-mint or WebSocket open would
        // race the engagement task — the task would finish, set state
        // to .listening, start bridge polling, and resurrect a session
        // the user just dismissed.
        continuousEngagementTask?.cancel()
        continuousEngagementTask = nil
        if state.isActive {
            sendJSON([
                "type": "session.update",
                "session": ["type": "realtime", "audio": ["input": ["turn_detection": NSNull()]]],
            ])
            sendJSON(["type": "input_audio_buffer.clear"])
            Self.appendDiag("disengageContinuousListening: back to PTT")
        }
        // v15p2 (2026-05-03): stop bridge polling — we only want it
        // running in continuous mode.
        stopBridgePolling()
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

        // v15p2 (2026-05-03): set the cancel gate FIRST, BEFORE
        // anything else. This drops all audio chunks scheduled or
        // arriving from this point forward.
        audioStateLock.lock()
        responseWasCancelled = true
        responseDoneReceived = true
        outputBuffersInFlight = 0
        audioStateLock.unlock()

        // Stop the player IMMEDIATELY without a MainActor hop —
        // AVAudioPlayerNode.stop() is callable from any thread, and
        // the dispatch hop was adding 10-50ms of audio leakage.
        if outputPlayer.isPlaying {
            outputPlayer.stop()
        }
        // Reset and re-prepare the player so the next response can
        // play cleanly. reset() drops any scheduled buffers we
        // hadn't yet stopped above.
        outputPlayer.reset()
        if outputEngine.isRunning {
            outputPlayer.play()
        }

        Task { @MainActor in
            self.state = .listening
            self.liveAssistantTranscript = ""
            self.outputAudioLevel = 0
        }

        // Schedule mic reopen after grace, but DO NOT end session
        // — user explicitly interrupted to speak again.
        scheduleMicReopenAfterGrace(naturalCompletion: false)
    }

    // MARK: - Suspend / resume (v15p2, 2026-05-03)

    /// Suspend Marin while another voice mode (VTT, Typing, Polish,
    /// Capture, Burst, Base PTT) is active. Mutes mic input, cancels
    /// any in-flight response, stops TTS playback queue. The
    /// WebSocket stays open — we're pausing, not ending.
    ///
    /// Idempotent: safe to call multiple times. CompanionManager
    /// refcounts other-mode chords so this method only fires on
    /// 0→1 transitions.
    func suspendForOtherMode() {
        let alreadyActive: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard alreadyActive else { return }

        let wasAlreadySuspended: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            let was = isSuspendedByOtherMode
            isSuspendedByOtherMode = true
            // Drop any buffered audio so we don't ship Steph's
            // dictation-intended speech to OpenAI as if it were
            // for Marin.
            inputAudioBuffer.removeAll(keepingCapacity: true)
            return was
        }()
        if wasAlreadySuspended { return }

        Self.appendDiag("suspendForOtherMode — pausing Marin (other-mode chord pressed)")

        // If a response is in flight, cancel it cleanly — same
        // path as Esc-during-speech.
        let modelSpeaking: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return isModelSpeaking
        }()
        if modelSpeaking {
            sendJSON(["type": "response.cancel"])
        }

        // Stop TTS playback so it doesn't bleed into Steph's other
        // mode (e.g. VTT capturing Marin's voice as input).
        Task { @MainActor in
            if self.outputPlayer.isPlaying {
                self.outputPlayer.stop()
            }
            if self.outputEngine.isRunning {
                // Keep engine running so we can resume cleanly,
                // just stop the player.
                self.outputPlayer.play()
            }
        }
    }

    /// Resume Marin after all other-mode chords have been released.
    /// Idempotent: safe to call when not suspended (no-op).
    func resumeFromOtherMode() {
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard active else { return }

        let wasSuspended: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            let was = isSuspendedByOtherMode
            isSuspendedByOtherMode = false
            // Reset response state so we don't confuse the
            // listening gate. cancelCurrentResponse already set
            // these but in case suspend was called without a live
            // response, normalize them now.
            responseDoneReceived = false
            outputBuffersInFlight = 0
            // Clear any audio that snuck in via tap during the
            // suspend window — should be empty already since the
            // shouldStreamAudio gate was closed, but defensive.
            inputAudioBuffer.removeAll(keepingCapacity: true)
            return was
        }()
        if !wasSuspended { return }

        Self.appendDiag("resumeFromOtherMode — Marin back to listening")

        Task { @MainActor in
            // Make sure isModelSpeaking is false so the audio gate
            // re-opens. (cancelCurrentResponse may have left it true
            // pending the grace timer — but if we suspended while
            // she was speaking, by now she's done.)
            self.isModelSpeaking = false
            self.state = .listening
            self.liveAssistantTranscript = ""
            self.outputAudioLevel = 0
        }
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
        // v15p3e (2026-05-08): the OpenAI-Beta: realtime=v1 header is
        // INCOMPATIBLE with GA ephemeral keys. Sending it produces:
        //   "API version mismatch. You cannot start a Realtime beta
        //    session with a GA client secret."
        // Header omitted entirely for GA. Re-add only if rolling back
        // both endpoint AND model to preview.

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
        case "session.created":
            Self.appendDiag(type)
            // v15p2 (2026-05-03): replay recent turns so Marin
            // remembers what we were just talking about. Cold
            // sessions otherwise start amnesiac.
            replayHistoryToServer()
        case "session.updated":
            Self.appendDiag(type)

        case "response.created":
            // Marin is about to speak — silence the mic until both
            // (a) response.done fires AND (b) playback queue drains.
            // v15p2 hotfix2 (2026-05-02).
            audioStateLock.lock()
            isModelSpeaking = true
            responseDoneReceived = false
            // v15p2 (2026-05-03): reset the cancel gate so this new
            // response's audio chunks aren't dropped by the previous
            // cancel.
            responseWasCancelled = false
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

                    // v15p3o (2026-05-08): inject a system note containing
                    // Marin's partial response so she can resume after the
                    // user's interjection. Without this, gpt-realtime-2
                    // treats the cancelled item as "thread closed" and
                    // ignores even explicit "then continue" instructions.
                    // Only fire if the partial transcript is substantive
                    // (>20 chars) so quick interrupts on short utterances
                    // don't spam noise.
                    let partialTranscript = self.liveAssistantTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if partialTranscript.count > 20 {
                        let note = "[System note — barge-in context: Your prior response was interrupted mid-stream. The partial response you had spoken so far was: \"\(partialTranscript)\". After addressing the user's current interjection, briefly return to that thread and continue from where you stopped — unless the user's new request makes the prior thread obviously irrelevant. If they explicitly say 'then continue' or similar, you MUST resume.]"
                        self.sendJSON([
                            "type": "conversation.item.create",
                            "item": [
                                "type": "message",
                                "role": "user",
                                "content": [["type": "input_text", "text": note]],
                            ],
                        ])
                        Self.appendDiag("barge-in: injected resume-context note (\(partialTranscript.count) chars)")
                    } else {
                        Self.appendDiag("barge-in: skipped resume-context note (partial transcript only \(partialTranscript.count) chars)")
                    }

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
            // v15p3b (2026-05-07): screenshot capture MOVED from
            // speech_started → speech_stopped (see speech_stopped case
            // below). Old design captured at start-of-utterance, but
            // Steph often navigates mid-question ("okay so now I'm
            // looking at...") — the screenshot then captured the screen
            // he was on BEFORE the navigation, and Marin would respond
            // about the wrong view. Capturing at speech_stopped means
            // we get the FINAL state Steph wants Marin reasoning about.
            // The ~100-200ms screenshot capture races the server's
            // auto-response trigger, but in practice the server takes
            // 500-2000ms to generate, so the screenshot usually lands
            // in conversation context before the response starts.
            // (This change was first attempted in v15p4 alongside the
            // broken click-await tool. v15p4 was rolled back; this
            // specific timing change is preserved as a safe forward-pick.)

        case "input_audio_buffer.speech_stopped":
            Task { @MainActor in
                self.state = .responding
            }
            // v15p3h (2026-05-08): screenshot capture deferred from
            // speech_stopped → conversation.item.input_audio_transcription.completed
            // (handled below). Steph reported gpt-realtime-2 feels slower than v1
            // partly due to per-turn screenshot upload (~200-400ms) on questions
            // that don't need vision. Sending the screenshot AFTER we have the
            // transcript lets us apply a SEND-by-default heuristic with a
            // narrow skip list for clearly non-visual queries (time, calendar,
            // unread, conversational acks). Everything ambiguous still sends.
            // Save: ~200-400ms + ~100-200KB upload + vision tokens per skipped turn.
            // Only applies to continuous mode — PTT captures at session start.

        // v15p3e (2026-05-08): GA renamed several response.* events.
        // response.audio.delta → response.output_audio.delta
        // response.audio_transcript.delta → response.output_audio_transcript.delta
        // (plus .done variants — added below). Old names kept as fallthrough
        // in case overrides revert to preview server. Without this rename
        // Marin's audio chunks were silently dropped — diag log showed
        // dozens of "unhandled server event: type=response.output_audio.delta"
        // and the user heard nothing despite the model successfully
        // generating a response.
        case "response.output_audio.delta", "response.audio.delta":
            if let base64 = json["delta"] as? String,
               let pcmData = Data(base64Encoded: base64) {
                playPCM16Chunk(pcmData)
            }

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
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
            // v15p2 (2026-05-03): cancel the PTT response timeout —
            // response arrived in time.
            cancelPTTResponseTimeout()
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
                // v15p3h (2026-05-08): per-turn screenshot decision based on
                // user's transcribed words. Continuous mode only — PTT handles
                // its own screenshot at session start. Default = SEND. Skip list
                // matches clearly-non-visual queries only.
                let inContinuous: Bool = {
                    audioStateLock.lock(); defer { audioStateLock.unlock() }
                    return isContinuousListening
                }()
                if inContinuous && Self.shouldSendScreenshotForTranscript(transcript) {
                    captureAndSendActiveScreenshot()
                } else if inContinuous {
                    Self.appendDiag("vision: SKIPPED screenshot — transcript matched non-visual skip pattern: \"\(transcript.prefix(80))\"")
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
            // v15p3e (2026-05-08) DIAGNOSTIC: log unknown event types so we
            // can see what GA is actually sending us. Switch was built for
            // preview API event names; some may have been renamed in GA.
            // Truncated to 200 chars to avoid log spam from large payloads.
            Self.appendDiag("unhandled server event: type=\(type) raw=\(text.prefix(200))")
        }
    }

    // MARK: - Audio capture (mic → server)
    //
    // CRITICAL: this runs on the audio thread. NO synchronous main-actor
    // hops, NO `await`, NO blocking work. State mutations go through
    // audioStateLock, @Published state goes through async Task @MainActor.

    private func startAudioCapture() throws {
        // v15p2 hotfix (2026-05-03): defensive cleanup. If a prior
        // session's teardown didn't fully settle (CoreAudio can be
        // slow to release the mic), starting a new session can
        // hang at inputEngine.start(). Force-stop the engines and
        // remove any lingering tap before re-configuring. removeTap
        // is a no-op if no tap is installed.
        if inputEngine.isRunning {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        } else {
            // Even if not running, clear any half-installed tap from
            // a prior aborted startup.
            inputEngine.inputNode.removeTap(onBus: 0)
        }

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
        // v15p3p (2026-05-08): barge-in is now AUTO based on audio output
        // device. Headphones / Bluetooth / USB headsets / AirPlay → mic
        // stays open during model speech (real-time interruption works).
        // Built-in speakers / HDMI → mic gates off during model speech
        // (avoids feedback loop where Marin hears herself).
        //
        // Manual override via UserDefaults:
        //   defaults write com.stephenpierson.clickyplus clicky.realtimeBargeInForce -string on
        //   defaults write com.stephenpierson.clickyplus clicky.realtimeBargeInForce -string off
        //   defaults delete com.stephenpierson.clickyplus clicky.realtimeBargeInForce
        // (Last one returns to auto.)
        //
        // Backward compat: the old bool key clicky.realtimeBargeInEnabled
        // still works as "force on" if explicitly set true.
        let bargeInEnabled: Bool = {
            let force = UserDefaults.standard.string(forKey: "clicky.realtimeBargeInForce")
            if force == "on" { return true }
            if force == "off" { return false }
            // Backward-compat path: explicit `enabled = true` forces on.
            if UserDefaults.standard.bool(forKey: "clicky.realtimeBargeInEnabled") { return true }
            // Auto.
            return Self.cachedIsExternalAudioOutput()
        }()
        let shouldStreamAudio = (isHotkeyHeld || isContinuousListening)
            && (bargeInEnabled || !isModelSpeaking)
            && !isSuspendedByOtherMode
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
        let isContinuous = isContinuousListening
        audioStateLock.unlock()
        if !leftover.isEmpty {
            sendAudioChunk(leftover)
        }
        sendJSON(["type": "input_audio_buffer.commit"])
        sendJSON(["type": "response.create"])
        // v15p2 (2026-05-03): in PTT mode, schedule a hard timeout
        // so a hung response can't leave the session stuck on. Doesn't
        // apply in continuous mode — server VAD owns turn lifecycle there.
        if !isContinuous {
            schedulePTTResponseTimeout()
        }
    }

    private func schedulePTTResponseTimeout() {
        cancelPTTResponseTimeout()
        let scheduledGen: UInt64 = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return sessionGeneration
        }()
        pttResponseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.pttResponseTimeoutSeconds * 1_000_000_000)
            )
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let currentGen: UInt64 = {
                self.audioStateLock.lock(); defer { self.audioStateLock.unlock() }
                return self.sessionGeneration
            }()
            guard currentGen == scheduledGen else { return }
            Self.appendDiag(
                "PTT response timeout — no response.done in \(Self.pttResponseTimeoutSeconds)s, force-ending stuck session"
            )
            self.endSession()
        }
    }

    private func cancelPTTResponseTimeout() {
        pttResponseTimeoutTask?.cancel()
        pttResponseTimeoutTask = nil
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
    /// v15p3h (2026-05-08): heuristic for whether the current turn's screenshot
    /// should be sent based on the user's transcribed query. Default = SEND
    /// (per Steph's "I'd rather miss the skip than miss the screenshot" bias).
    /// Skip ONLY for transcripts that clearly request a tool call or are pure
    /// conversational acks where vision wouldn't add anything.
    ///
    /// False positives (sending when we could've skipped) are the better failure
    /// mode here — they cost ~200-400ms + tokens but Marin still answers correctly.
    /// False negatives (skipping when we needed to) make Marin blind to context
    /// Steph wants her to see. Bias accordingly.
    /// v15p3p (2026-05-08): cached headphone-detection for auto barge-in.
    /// Refreshed every 1s — fast enough to react to plug/unplug events
    /// (user expects barge-in to start working ~immediately after putting
    /// in headphones), cheap enough to call from the audio thread (the
    /// underlying Core Audio query is microseconds, but we still avoid
    /// hammering it on every 100ms tap).
    private static var externalAudioOutputCachedValue = false
    private static var externalAudioOutputCheckedAt = Date.distantPast
    private static let externalAudioOutputCacheTTL: TimeInterval = 1.0

    static func cachedIsExternalAudioOutput() -> Bool {
        let now = Date()
        if now.timeIntervalSince(externalAudioOutputCheckedAt) > externalAudioOutputCacheTTL {
            externalAudioOutputCachedValue = isExternalAudioOutput()
            externalAudioOutputCheckedAt = now
        }
        return externalAudioOutputCachedValue
    }

    /// True if the system's default audio output is an external device
    /// (headphones via 3.5mm jack, Bluetooth, USB, AirPlay, etc.) — i.e.
    /// the model's audio won't bleed back into the mic. False for built-in
    /// speakers and HDMI/DisplayPort (TV/monitor speakers).
    ///
    /// Used to gate barge-in: external = mic stays open during model speech
    /// (interruption works); built-in = mic gates off (no feedback loop).
    static func isExternalAudioOutput() -> Bool {
        // Step 1: get the system default output device ID.
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceIDStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceIDAddr, 0, nil, &deviceIDSize, &deviceID
        )
        guard deviceIDStatus == noErr, deviceID != 0 else { return false }

        // Step 2: get the device's transport type.
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport
        )
        guard transportStatus == noErr else { return false }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in transport could be internal speakers OR the 3.5mm
            // headphone jack — same physical device, different data sources.
            // 'hdpn' = headphones jack, 'ispk' = internal speakers.
            var dataSource: UInt32 = 0
            var dataSourceSize = UInt32(MemoryLayout<UInt32>.size)
            var dataSourceAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let dataSourceStatus = AudioObjectGetPropertyData(
                deviceID, &dataSourceAddr, 0, nil, &dataSourceSize, &dataSource
            )
            // If we can't read the data source, default to "internal" (safer).
            guard dataSourceStatus == noErr else { return false }
            // FourCC 'hdpn' = 0x6864706e (h=0x68, d=0x64, p=0x70, n=0x6E).
            let headphonesDataSource: UInt32 = 0x6864706e
            return dataSource == headphonesDataSource

        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            // External audio path — assume safe for barge-in. Bluetooth
            // speakers are a theoretical false-positive but rare for Steph.
            return true

        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:
            // TV / external monitor speakers — feedback risk, treat as
            // built-in speakers.
            return false

        default:
            // Unknown transport — default to "no barge-in" for safety.
            return false
        }
    }

    static func shouldSendScreenshotForTranscript(_ transcript: String) -> Bool {
        let lower = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Empty transcript — safer to send (we have no info to skip on).
        if lower.isEmpty { return true }

        // Strip common trailing punctuation for matching.
        let punctuationToTrim = CharacterSet.punctuationCharacters
        let normalized = lower.trimmingCharacters(in: punctuationToTrim)

        // SKIP patterns — clearly tool-call or pure conversational queries.
        // Match either the entire utterance or an explicit prefix.
        let exactMatches: Set<String> = [
            "thanks", "thank you", "okay", "ok", "got it", "cool", "great",
            "continue", "go on", "keep going", "next", "done",
            "stop", "we're done", "turn off hands free", "turn off hands-free",
            "yes", "no", "yep", "nope", "sure",
        ]
        if exactMatches.contains(normalized) { return false }

        // Prefix matches — utterance starts with one of these and is short.
        // Length cap (60 chars) avoids skipping a long sentence that just
        // happens to start with "what time" etc. Genuinely-tool requests are short.
        let toolPrefixes: [String] = [
            "what time",
            "what's the time",
            "what is the time",
            "what time is it",
            "next meeting",
            "what's my next",
            "what is my next",
            "when's my next",
            "when is my next",
            "what's on my calendar",
            "what is on my calendar",
            "what's on my plate",
            "what do i have today",
            "any unread",
            "any new email",
            "any new emails",
            "any new slack",
            "any new messages",
            "do i have any unread",
            "do i have any new",
            "check my slack",
            "check my email",
            "check my calendar",
            "read my clipboard",
            "what's on my clipboard",
            "what is on my clipboard",
        ]
        if normalized.count <= 60 {
            for prefix in toolPrefixes {
                if normalized.hasPrefix(prefix) { return false }
            }
        }

        // Default: SEND. Anything ambiguous, anything containing visual cues
        // ("see", "this", "that", "explain", "show", "look", "screen", etc.),
        // anything genuinely complex — all default to send.
        return true
    }

    // MARK: - Cowork bridge handoff — REMOVED 2026-05-10 (v15p3y)
    //
    // The send_to_cowork tool, sendToCoworkBridge helper, bridge attachment
    // statics, and cowork-bridge-watcher scheduled task were tabled and removed.
    // Polling latency floor was unacceptable; URL-scheme alternative pulls
    // focus; clipboard handoff breaks conversation flow. Replaced by the design
    // for a Marin local-helper sub-agent (Mac-side Sonnet 4.6 with file/web/bash
    // tools) — see Roadmap "Brain-dump candidates added 2026-05-10". Bridge file
    // format + the disabled watcher retained as scaffolding if revived.

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

        // v15p3y (2026-05-10): send_to_cowork case removed — bridge tabled.
        // See MARK: - Cowork bridge handoff comment above for context.

        // v15p3u (2026-05-09): web search via Anthropic's web_search tool.
        // Marin sends a query, Worker calls Anthropic with web_search enabled,
        // Anthropic searches + synthesizes, returns answer with sources.
        case "web_search":
            let query = (args["query"] as? String) ?? ""
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/web-search",
                        body: ["query": query]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        // v15p3t (2026-05-09): on-demand fresh screenshot. Marin called the
        // tool because she suspects her visual context is stale. We capture
        // a new screenshot, send it as a conversation item (the actual image
        // payload), AND immediately resolve the function call with a tiny
        // ack so she continues. The screenshot will be in context for her
        // next response.
        case "get_current_screenshot":
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureAndSendActiveScreenshot()
                self.sendFunctionCallResult(
                    callId: callId,
                    name: name,
                    result: [
                        "status": "ok",
                        "note": "Fresh screenshot has been sent as a new user message in the conversation. Reference it in your next response.",
                    ]
                )
            }

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

        // ── Gmail (v15p2, 2026-05-02) ─────────────────────────
        case "search_gmail":
            let query = (args["query"] as? String) ?? ""
            let maxResults = (args["max_results"] as? NSNumber)?.intValue ?? 10
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/gmail/search",
                        body: [
                            "query": query,
                            "max_results": maxResults,
                        ]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        case "read_email_thread":
            let threadId = (args["thread_id"] as? String) ?? ""
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/gmail/read-thread",
                        body: ["thread_id": threadId]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        // ── Calendar (v15p2, 2026-05-02) ──────────────────────
        case "list_calendar_events":
            let timeRange = (args["time_range"] as? String) ?? "next_7_days"
            let query = (args["query"] as? String) ?? ""
            let maxResults = (args["max_results"] as? NSNumber)?.intValue ?? 15
            Task { [weak self] in
                guard let self else { return }
                do {
                    var body: [String: Any] = [
                        "time_range": timeRange,
                        "max_results": maxResults,
                    ]
                    if !query.isEmpty { body["query"] = query }
                    let result = try await self.callWorkerJSON(
                        path: "/calendar/list-events",
                        body: body
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        case "find_next_event":
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/calendar/find-next",
                        body: [:]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        // ── Slack (v15p2, 2026-05-03) ─────────────────────────
        case "search_slack":
            let query = (args["query"] as? String) ?? ""
            let maxResults = (args["max_results"] as? NSNumber)?.intValue ?? 10
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/slack/search",
                        body: [
                            "query": query,
                            "max_results": maxResults,
                        ]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        case "read_slack_thread":
            let channelId = (args["channel_id"] as? String) ?? ""
            let threadTs = (args["thread_ts"] as? String) ?? ""
            let maxReplies = (args["max_replies"] as? NSNumber)?.intValue ?? 20
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/slack/read-thread",
                        body: [
                            "channel_id": channelId,
                            "thread_ts": threadTs,
                            "max_replies": maxReplies,
                        ]
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        case "list_unread_slack":
            var body: [String: Any] = [:]
            if let types = args["types"] as? String, !types.isEmpty {
                body["types"] = types
            }
            if let maxChannels = (args["max_channels"] as? NSNumber)?.intValue {
                body["max_channels"] = maxChannels
            }
            if let mpc = (args["messages_per_channel"] as? NSNumber)?.intValue {
                body["messages_per_channel"] = mpc
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/slack/unread-inbox",
                        body: body
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        case "compose_slack_message":
            let channelId = (args["channel_id"] as? String) ?? ""
            let message = (args["message"] as? String) ?? ""
            let threadTs = args["thread_ts"] as? String
            let confirmed = (args["confirmed"] as? Bool) ?? false
            var body: [String: Any] = [
                "channel_id": channelId,
                "message": message,
                "confirmed": confirmed,
            ]
            if let threadTs, !threadTs.isEmpty {
                body["thread_ts"] = threadTs
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.callWorkerJSON(
                        path: "/slack/post-message",
                        body: body
                    )
                    self.sendFunctionCallResult(callId: callId, name: name, result: result)
                } catch {
                    self.sendFunctionCallResult(
                        callId: callId,
                        name: name,
                        result: ["status": "error", "reason": error.localizedDescription]
                    )
                }
            }

        // ── Bridge (v15p2, 2026-05-03) ────────────────────────
        // Append a message to the Claude ↔ Marin bridge file.
        // Local-only filesystem write via FileHandle. Reads use
        // the existing read_obsidian_note tool with the bridge
        // path — no separate read_bridge tool needed.
        case "append_to_bridge":
            let message = (args["message"] as? String) ?? ""
            let threadId = args["thread_id"] as? String
            Task { @MainActor [weak self] in
                let result = MarinResearchTools.appendToBridge(message: message, threadId: threadId)
                self?.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        // ── Clipboard write (v15p2, 2026-05-03) ───────────────
        // Marin → Cowork direction. NSPasteboard write on
        // MainActor. Replaces whatever's currently on the
        // clipboard. 10K char cap to discourage Marin from using
        // the clipboard as a bulk-data channel (use the bridge
        // for that).
        case "write_clipboard":
            let content = (args["content"] as? String) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trimmed = content
                let result: [String: Any]
                if trimmed.isEmpty {
                    result = [
                        "status": "error",
                        "reason": "Empty content — nothing to write to clipboard",
                    ]
                } else if trimmed.count > 10_000 {
                    result = [
                        "status": "error",
                        "reason": "Content too long (\(trimmed.count) chars). Limit is 10000. For larger payloads, use append_to_bridge or suggest Steph paste directly.",
                    ]
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    let ok = pb.setString(trimmed, forType: .string)
                    if ok {
                        result = [
                            "status": "ok",
                            "char_count": trimmed.count,
                        ]
                    } else {
                        result = [
                            "status": "error",
                            "reason": "NSPasteboard.setString returned false",
                        ]
                    }
                }
                self.sendFunctionCallResult(callId: callId, name: name, result: result)
            }

        // ── Clipboard read (v15p2, 2026-05-02) ────────────────
        // Local-only — no Worker hop. Reads NSPasteboard.general
        // on the MainActor and ships the string back. Truncated
        // at 16K chars to keep Realtime turns sane.
        case "read_clipboard":
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                let raw = pb.string(forType: .string) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let result: [String: Any]
                if trimmed.isEmpty {
                    result = [
                        "status": "empty",
                        "message": "Clipboard is empty or contains no text.",
                    ]
                } else {
                    let maxChars = 16000
                    let truncated = trimmed.count > maxChars
                    let payload = truncated
                        ? String(trimmed.prefix(maxChars)) + "\n\n[truncated — clipboard had \(trimmed.count) chars total]"
                        : trimmed
                    result = [
                        "status": "ok",
                        "char_count": trimmed.count,
                        "truncated": truncated,
                        "contents": payload,
                    ]
                }
                self.sendFunctionCallResult(callId: callId, name: name, result: result)
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

    /// v15p2 (2026-05-02): generic POST helper for tool dispatchers
    /// that need to talk to Worker routes (Gmail and future
    /// connectors). POSTs JSON body, returns parsed JSON dict.
    /// Throws on transport / HTTP errors so the caller can surface
    /// to Marin via the function_call error pattern.
    private func callWorkerJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        // workerSessionURL points at /realtime-session. Build a sibling URL.
        guard var components = URLComponents(url: workerSessionURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -50,
                userInfo: [NSLocalizedDescriptionKey: "Bad worker base URL"]
            )
        }
        components.path = path
        guard let url = components.url else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -51,
                userInfo: [NSLocalizedDescriptionKey: "Could not build worker URL for \(path)"]
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ClickyRealtimeError",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker \(path) returned \(http.statusCode): \(bodyText.prefix(300))"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ClickyRealtimeError",
                code: -52,
                userInfo: [NSLocalizedDescriptionKey: "Could not parse JSON from \(path)"]
            )
        }
        return json
    }

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
                    "type": "realtime",
                    "audio": [
                        "input": [
                            "turn_detection": [
                                "type": "server_vad",
                                "threshold": 0.5,
                                "prefix_padding_ms": 300,
                                "silence_duration_ms": 800,
                            ],
                        ],
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
                    "type": "realtime",
                    "audio": [
                        "input": [
                            "turn_detection": NSNull(),
                        ],
                    ],
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
        // v15p2 (2026-05-03): drop audio chunks if the user cancelled
        // the response. The server takes time to honor response.cancel,
        // so chunks keep arriving for a few hundred ms after Esc —
        // without this gate, those chunks would still be scheduled
        // into the player and Marin would keep talking briefly.
        audioStateLock.lock()
        let wasCancelled = responseWasCancelled
        if !wasCancelled {
            outputBuffersInFlight += 1
        }
        audioStateLock.unlock()
        if wasCancelled { return }
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
        // v15p2 (2026-05-03): capture the session generation at
        // schedule time. If a new session has started by the time
        // this fires, do not end it — it's a different session.
        // v15p3 (2026-05-06): also capture isContinuousListening
        // at schedule time. The grace task previously read the LIVE
        // value at fire time, so a continuous-mode toggle during the
        // 500ms grace window could leave server-side turn_detection
        // mismatched with client-side state — user-visible symptom
        // was Marin not responding to the user's reply because the
        // server thought we were still in PTT mode while the client
        // had already engaged hands-free. Now we honor the schedule
        // time state for the end-session decision and re-sync server
        // turn_detection if continuous mode changed during grace.
        let (scheduledGeneration, scheduledIsContinuous): (UInt64, Bool) = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return (sessionGeneration, isContinuousListening)
        }()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micReopenGraceSeconds * 1_000_000_000))
            guard let self else { return }
            self.audioStateLock.lock()
            // Re-check conditions in case a new response started
            // during the grace period.
            let stillSafe = self.responseDoneReceived && self.outputBuffersInFlight == 0
            let currentIsContinuous = self.isContinuousListening
            let currentGeneration = self.sessionGeneration
            if stillSafe {
                self.isModelSpeaking = false
                self.inputAudioBuffer.removeAll(keepingCapacity: true)
            }
            self.audioStateLock.unlock()
            guard stillSafe else { return }
            // If a new session has started since we were scheduled,
            // don't touch it. We only manage the session we were
            // scheduled for.
            guard currentGeneration == scheduledGeneration else {
                Self.appendDiag("grace task skipped — session generation changed (\(scheduledGeneration) → \(currentGeneration))")
                return
            }

            Self.appendDiag("mic reopened after playback drain + grace")

            // v15p3 (2026-05-06): if continuous-listening toggled during
            // grace, server-side turn_detection is now mismatched with
            // client state. Resync so the next user turn registers.
            if scheduledIsContinuous != currentIsContinuous {
                Self.appendDiag("continuous-listening flipped during grace (\(scheduledIsContinuous) → \(currentIsContinuous)) — resyncing turn_detection")
                if currentIsContinuous {
                    self.sendJSON([
                        "type": "session.update",
                        "session": [
                            "type": "realtime",
                            "audio": [
                                "input": [
                                    "turn_detection": [
                                        "type": "server_vad",
                                        "threshold": 0.5,
                                        "prefix_padding_ms": 300,
                                        "silence_duration_ms": 800,
                                    ],
                                ],
                            ],
                        ],
                    ])
                } else {
                    self.sendJSON([
                        "type": "session.update",
                        "session": ["type": "realtime", "audio": ["input": ["turn_detection": NSNull()]]],
                    ])
                }
            }

            // PTT mode + natural completion → end session. No warm
            // window. Cancellation paths pass naturalCompletion=false
            // so the user can keep talking after they Esc-interrupted.
            // Use scheduled value (not current) — the user's intent at
            // the time the response completed is what matters, even if
            // they've since toggled mid-grace.
            if naturalCompletion && !scheduledIsContinuous && !currentIsContinuous {
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

        // v15p2 (2026-05-03): cancel the PTT response timeout so it
        // doesn't fire after the session is already torn down.
        cancelPTTResponseTimeout()

        // v15p3 (2026-05-06): cancel any in-flight continuous-engagement
        // task. teardown() can be called from within the engagement task
        // itself (catch branch) — that's fine, Task.cancel on self is
        // safe and doesn't deadlock.
        continuousEngagementTask?.cancel()
        continuousEngagementTask = nil

        // v15p2 (2026-05-03): stop bridge polling so it doesn't outlive
        // the session.
        stopBridgePolling()

        // v15p2 hotfix (2026-05-04, QA #1): clear the cancellation
        // gate so it doesn't carry over into the next session. If the
        // user Esc'd to cancel a response and then ended the session
        // before any new response.created arrived, this flag stayed
        // true — the next session's first audio chunks would silently
        // get dropped.
        audioStateLock.lock()
        responseWasCancelled = false
        audioStateLock.unlock()

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

    // MARK: - Persistent conversation history (v15p2, 2026-05-03)
    //
    // Mirrors the Base PTT pattern (`conversation-history.json`)
    // but for Realtime turns. Two reasons:
    //   1. Continuity across cold session starts. PTT sessions die
    //      after each response, hands-free can drop on Esc, app
    //      restarts wipe live state — without persistence, every
    //      new session starts amnesiac.
    //   2. Cross-mode continuity later: same memory could feed
    //      Base PTT, the Cowork bridge, etc.
    //
    // Storage: JSON array of {timestamp, user, assistant} entries
    // at ~/Library/Application Support/com.stephenpierson.clickyplus/
    // marin-conversation-history.json. Capped at 30 entries; turns
    // older than 24h aren't replayed (kept on disk for archive).
    //
    // Replay: on `session.created`, send the recent turns as
    // `conversation.item.create` events with role: user/assistant.
    // No `response.create` follows — we just seed the conversation;
    // Marin won't speak until Steph does.

    private struct MarinHistoryEntry: Codable {
        let timestamp: Date
        let user: String
        let assistant: String
    }

    private static let maxHistoryTurnsToKeep = 30
    private static let maxHistoryTurnsToReplay = 12
    private static let maxHistoryAgeHoursForReplay: TimeInterval = 24

    private static var historyFileURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent(
            "com.stephenpierson.clickyplus", isDirectory: true
        )
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("marin-conversation-history.json")
    }

    private static func loadFullHistory() -> [MarinHistoryEntry] {
        guard let url = historyFileURL,
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MarinHistoryEntry].self, from: data)) ?? []
    }

    private static func writeFullHistory(_ entries: [MarinHistoryEntry]) {
        guard let url = historyFileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Append a completed turn to disk. Trims to the last 30 turns.
    /// Called from writeRealtimeTurnToTranscriptLog so it inherits
    /// that path's MainActor isolation. File I/O is small and fast
    /// enough to do inline.
    private func appendTurnToHistory(user: String, assistant: String) {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty || !trimmedAssistant.isEmpty else { return }
        var history = Self.loadFullHistory()
        history.append(MarinHistoryEntry(
            timestamp: Date(),
            user: trimmedUser,
            assistant: trimmedAssistant
        ))
        let cap = Self.maxHistoryTurnsToKeep
        if history.count > cap {
            history = Array(history.suffix(cap))
        }
        Self.writeFullHistory(history)
    }

    private func loadRecentHistoryForReplay() -> [MarinHistoryEntry] {
        let history = Self.loadFullHistory()
        let cutoff = Date().addingTimeInterval(-Self.maxHistoryAgeHoursForReplay * 3600)
        let recent = history.filter { $0.timestamp > cutoff }
        return Array(recent.suffix(Self.maxHistoryTurnsToReplay))
    }

    /// Send the recent turns into the new Realtime session as
    /// conversation.item.create events. Called on session.created.
    /// Does NOT send response.create — we just seed context.
    private func replayHistoryToServer() {
        let recent = loadRecentHistoryForReplay()
        guard !recent.isEmpty else { return }
        Self.appendDiag("replaying \(recent.count) prior turn(s) into Realtime session")
        for entry in recent {
            if !entry.user.isEmpty {
                sendJSON([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": entry.user]],
                    ],
                ])
            }
            if !entry.assistant.isEmpty {
                // v15p3e (2026-05-08): GA renamed assistant content type
                // "text" → "output_text". Sending "text" produces a server
                // error and breaks history replay.
                sendJSON([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": entry.assistant]],
                    ],
                ])
            }
        }
    }

    // MARK: - Bridge polling (v15p2, 2026-05-03)
    //
    // Marin polls the Claude–Marin bridge file every 30s while in
    // continuous-listening mode. New entries addressed to her (header
    // contains "→ Marin") get injected as a user-role system note.
    // Persona instructs her to mention them naturally on next turn —
    // no auto-response, no interruption.
    //
    // Last-read timestamp persisted in UserDefaults so polling doesn't
    // resurface old entries after restart. First-run init sets the
    // marker to "now" so historical entries don't all flood at once.
    //
    // Polling stops when continuous mode disengages or the session ends.

    private static let bridgePollingIntervalSeconds: TimeInterval = 30
    private static let bridgeLastReadKey = "marin.bridge.last_read_timestamp"
    private static let bridgeFilePath = NSString(
        "~/Desktop/Claude Cowork/Obsidian/Steph Vault/Bridges/Claude-Marin Channel.md"
    ).expandingTildeInPath

    private var bridgePollingTask: Task<Void, Never>?

    private struct BridgeEntry {
        let timestamp: Date
        let sender: String
        let body: String
    }

    private func startBridgePolling() {
        stopBridgePolling()
        // Initialize lastRead marker on first run so we don't surface
        // historical entries.
        if UserDefaults.standard.string(forKey: Self.bridgeLastReadKey) == nil {
            let formatter = ISO8601DateFormatter()
            UserDefaults.standard.set(
                formatter.string(from: Date()),
                forKey: Self.bridgeLastReadKey
            )
            Self.appendDiag("bridge polling: first-run lastRead marker set to now")
        }
        bridgePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.bridgePollingIntervalSeconds * 1_000_000_000)
                )
                if Task.isCancelled { return }
                self?.checkBridgeForNewEntries()
            }
        }
        Self.appendDiag("bridge polling: started (interval \(Self.bridgePollingIntervalSeconds)s)")
    }

    private func stopBridgePolling() {
        if bridgePollingTask != nil {
            Self.appendDiag("bridge polling: stopped")
        }
        bridgePollingTask?.cancel()
        bridgePollingTask = nil
    }

    private func checkBridgeForNewEntries() {
        // Don't poll while suspended-by-other-mode — Steph's actively
        // using a different mode, no point queueing notifications.
        let suspended: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return isSuspendedByOtherMode
        }()
        if suspended { return }
        // Don't poll if session went inactive between ticks.
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        if !active { return }

        guard let content = try? String(
            contentsOfFile: Self.bridgeFilePath,
            encoding: .utf8
        ) else {
            // Bridge file may not exist yet — silent skip.
            return
        }

        let formatter = ISO8601DateFormatter()
        let lastRead = UserDefaults.standard
            .string(forKey: Self.bridgeLastReadKey)
            .flatMap { formatter.date(from: $0) }
            ?? Date.distantPast

        let newEntries = Self.parseBridgeForMarinEntries(content: content, after: lastRead)
        if newEntries.isEmpty { return }

        // Update last-read marker to the newest entry's timestamp so
        // we don't reinject on the next tick.
        if let newest = newEntries.map({ $0.timestamp }).max() {
            UserDefaults.standard.set(
                formatter.string(from: newest),
                forKey: Self.bridgeLastReadKey
            )
        }

        // Build a compact summary. Body trimmed to ~600 chars per entry
        // so we don't blow context if Cowork posted a giant payload.
        let summary = newEntries.map { entry -> String in
            let truncated = entry.body.count > 600
                ? String(entry.body.prefix(600)) + "…[truncated; full content in bridge file]"
                : entry.body
            let dateString = DateFormatter.localizedString(
                from: entry.timestamp, dateStyle: .none, timeStyle: .short
            )
            return "[\(dateString) from \(entry.sender)]\n\(truncated)"
        }.joined(separator: "\n\n---\n\n")

        let entryWord = newEntries.count == 1 ? "entry" : "entries"
        let systemNote = """
        [BRIDGE UPDATE — internal notification, do not respond directly to this message]

        Cowork Claude has left \(newEntries.count) new \(entryWord) for you in the bridge file (`Bridges/Claude-Marin Channel.md`):

        \(summary)

        ON STEPH'S NEXT TURN: briefly mention this to him in a natural way — e.g. "by the way, Cowork Claude just left a note in the bridge about X — want me to read it in full?" — and keep going with whatever he's asking. DO NOT interrupt his current train of thought, just weave the heads-up in. If he asks for the full content, you can either summarize what's above or call read_obsidian_note for the full file.
        """

        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": systemNote]],
            ],
        ])
        Self.appendDiag("bridge polling: injected \(newEntries.count) new \(entryWord) as system note")
    }

    /// Parse the bridge file for entries with headers indicating
    /// Cowork Claude → Marin (or any "→ Marin" recipient match).
    /// Returns entries newer than `after`.
    private static func parseBridgeForMarinEntries(content: String, after: Date) -> [BridgeEntry] {
        // Header format: `## YYYY-MM-DD HH:MM — <Sender> → <Recipient>(...)`
        // Body runs until the next `---` separator.
        let lines = content.components(separatedBy: "\n")
        var entries: [BridgeEntry] = []
        var i = 0
        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        headerFormatter.timeZone = TimeZone.current

        while i < lines.count {
            let line = lines[i]
            // Match header lines: `## YYYY-MM-DD HH:MM — Sender → Recipient`
            if line.hasPrefix("## "),
               let headerInfo = parseHeader(line, formatter: headerFormatter) {
                let (timestamp, sender, recipient) = headerInfo
                // Filter: must be newer than lastRead, recipient must
                // include "Marin" (case-insensitive).
                if timestamp > after,
                   recipient.lowercased().contains("marin"),
                   !sender.lowercased().contains("marin") {
                    // Collect body until next `---` separator or EOF.
                    var bodyLines: [String] = []
                    i += 1
                    while i < lines.count {
                        let bodyLine = lines[i]
                        if bodyLine.trimmingCharacters(in: .whitespaces) == "---" {
                            break
                        }
                        bodyLines.append(bodyLine)
                        i += 1
                    }
                    let body = bodyLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        entries.append(BridgeEntry(
                            timestamp: timestamp,
                            sender: sender,
                            body: body
                        ))
                    }
                }
            }
            i += 1
        }
        return entries
    }

    /// Parse a single header line of the form
    /// `## YYYY-MM-DD HH:MM — Sender → Recipient (optional thread tag)`
    /// Returns (timestamp, sender, recipient) on success.
    private static func parseHeader(
        _ line: String, formatter: DateFormatter
    ) -> (Date, String, String)? {
        // Strip leading `## ` (and optional extra hashes/whitespace).
        let stripped = line.replacingOccurrences(
            of: #"^#+\s*"#, with: "", options: .regularExpression
        )
        // Split on " — " (em dash with spaces).
        let parts = stripped.components(separatedBy: " — ")
        guard parts.count >= 2 else { return nil }
        let datePart = parts[0].trimmingCharacters(in: .whitespaces)
        let rest = parts[1...].joined(separator: " — ")
        guard let timestamp = formatter.date(from: datePart) else { return nil }
        // Split rest on " → "
        guard let arrowRange = rest.range(of: " → ") else { return nil }
        let sender = String(rest[..<arrowRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var recipient = String(rest[arrowRange.upperBound...])
        // Strip trailing parenthetical thread tag if present.
        if let parenStart = recipient.firstIndex(of: "(") {
            recipient = String(recipient[..<parenStart])
        }
        recipient = recipient.trimmingCharacters(in: .whitespaces)
        return (timestamp, sender, recipient)
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
            // v15p2 (2026-05-03): persist the turn so cold session
            // starts can replay context. Survives app restarts.
            self.appendTurnToHistory(user: userTranscript, assistant: assistantTranscript)
            // v15p2 (2026-05-03): also append to the in-session
            // completedTurns log surfaced in the panel. This is
            // session-scoped — cleared on cold start.
            let entry = RealtimeTurn(
                timestamp: Date(),
                user: userTranscript,
                assistant: assistantTranscript
            )
            self.completedTurns.append(entry)
            let cap = Self.maxCompletedTurnsInLog
            if self.completedTurns.count > cap {
                self.completedTurns = Array(self.completedTurns.suffix(cap))
            }
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
