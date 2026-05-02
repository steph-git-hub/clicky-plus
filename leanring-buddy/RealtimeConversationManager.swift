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
    private var bytesSentInCurrentPress: Int = 0
    private var maxInputLevelInCurrentPress: Float = 0
    private var pressStartedAt: Date?

    // Warm session auto-close (continuous conversation).
    private static let warmSessionTimeoutSeconds: TimeInterval = 120
    private var warmSessionAutoCloseTask: Task<Void, Never>?

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
            // clear any stale server-side audio buffer, keep going.
            cancelWarmSessionAutoClose()
            sendJSON(["type": "input_audio_buffer.clear"])
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
                let token = try await self.fetchEphemeralToken()
                try await self.openWebSocket(token: token)
                try self.startAudioCapture()
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

    /// Emergency stop: tell the server to cancel the current response
    /// and drain local playback. Session stays warm (re-press to continue).
    func cancelCurrentResponse() {
        let active: Bool = {
            audioStateLock.lock(); defer { audioStateLock.unlock() }
            return state.isActive
        }()
        guard active else { return }
        Self.appendDiag("cancelCurrentResponse — silencing model")

        sendJSON(["type": "response.cancel"])

        // Drain playback queue on the main thread (AVAudioPlayerNode
        // mutations should happen on a consistent thread).
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

        case "input_audio_buffer.speech_started":
            Task { @MainActor in
                self.state = .listening
                self.liveUserTranscript = ""
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

        case "response.done":
            writeRealtimeTurnToTranscriptLog()
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
        let shouldFlush: Bool
        if isHotkeyHeld {
            inputAudioBuffer.append(bytes)
            if rms > maxInputLevelInCurrentPress {
                maxInputLevelInCurrentPress = rms
            }
            shouldFlush = inputAudioBuffer.count >= targetInputChunkBytes
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
        Task { @MainActor in
            self.outputAudioLevel = rms
            self.outputPlayer.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
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
