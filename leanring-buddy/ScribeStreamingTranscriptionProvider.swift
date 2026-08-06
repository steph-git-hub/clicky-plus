//
//  ScribeStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming transcription provider backed by ElevenLabs Scribe v2
//  Realtime (model scribe_v2_realtime).
//
//  v16 (2026-06-04): added for the STT bake-off (Deepgram vs Scribe v2
//  vs guarded-Parakeet). Conforms to BuddyTranscriptionProvider so it
//  drops into the existing VTT picker with no architectural changes —
//  selection is via clicky.vtt.provider = "scribe".
//
//  Endpoint: wss://api.elevenlabs.io/v1/speech-to-text/realtime
//  Auth: single-use token (token query param) minted server-side by the
//        clicky-proxy Worker's /scribe-token route. The master
//        ELEVENLABS_API_KEY lives only in Worker secrets (same key that
//        already powers TTS).
//  Protocol: client sends { message_type:"input_audio_chunk",
//        audio_base_64, sample_rate, commit } JSON text frames; server
//        sends partial_transcript / committed_transcript messages.
//        commit_strategy=manual — we drive finalization on key-release
//        by sending a chunk with commit=true (mirrors Deepgram Finalize).
//

import AVFoundation
import Foundation

struct ScribeStreamingTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ScribeStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private static let tokenProxyURL = "https://clicky-proxy.sapierso.workers.dev/scribe-token"

    let displayName = "Scribe v2"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Long-lived URLSession shared across streaming sessions — same
    /// rationale as the Deepgram/AssemblyAI providers (per-session
    /// invalidation corrupts the pool on rapid reconnect).
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    // v16 (2026-06-04): prewarm — cache a single-use token + warm the
    // realtime host's DNS/TLS at hotkey-arm so the next engage skips the
    // token POST and gets a hot WSS handshake. (Lower-risk than holding
    // a warm socket like AssemblyAI tried — no concurrent-session pileup.)
    private let warmingQueue = DispatchQueue(label: "com.learningbuddy.scribe.prewarm")
    private var cachedToken: (value: String, fetchedAt: Date)?
    private static let tokenFreshnessSeconds: TimeInterval = 13 * 60

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let tokenStart = Date()
        let token = try await tokenForEngage()
        let tokenFetchMs = Int(Date().timeIntervalSince(tokenStart) * 1000)
        print("🎙️ Scribe: using single-use token (\(token.prefix(16))...) tokenMs=\(tokenFetchMs)")

        let session = ScribeStreamingTranscriptionSession(
            token: token,
            tokenFetchMs: tokenFetchMs,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// v16: pre-fetch a single-use token + warm DNS/TLS to the realtime
    /// host so the next engage's handshake is hot. Called by
    /// BuddyDictationManager when the VTT hotkey arms. Safe on any thread;
    /// errors are swallowed (next engage just cold-starts).
    func prewarmSession(keyterms: [String]) {
        warmingQueue.async { [weak self] in
            guard let self else { return }
            if let warmURL = URL(string: "https://api.elevenlabs.io/v1/models") {
                var warm = URLRequest(url: warmURL)
                warm.httpMethod = "HEAD"
                warm.timeoutInterval = 4
                URLSession.shared.dataTask(with: warm).resume()
            }
            Task { [weak self] in
                guard let self else { return }
                if let token = try? await self.fetchSingleUseToken() {
                    self.warmingQueue.async { self.cachedToken = (token, Date()) }
                    print("🎙️ Scribe: prewarm token cached")
                }
            }
        }
    }

    /// Consume a fresh pre-warmed token if available (single-use), else
    /// fetch one on the spot.
    private func tokenForEngage() async throws -> String {
        let cached: String? = warmingQueue.sync {
            if let c = cachedToken,
               Date().timeIntervalSince(c.fetchedAt) < Self.tokenFreshnessSeconds {
                cachedToken = nil
                return c.value
            }
            cachedToken = nil
            return nil
        }
        if let cached { return cached }
        return try await fetchSingleUseToken()
    }

    private func fetchSingleUseToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ScribeStreamingTranscriptionProviderError(
                message: "Failed to fetch Scribe token (HTTP \(statusCode)): \(body)"
            )
        }

        // ElevenLabs single-use-token response: { "token": "..." }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw ScribeStreamingTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class ScribeStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    private struct MessageEnvelope: Decodable {
        let message_type: String
    }

    private struct TranscriptMessage: Decodable {
        let message_type: String
        let text: String?
    }

    private struct ScribeErrorMessage: Decodable {
        let message_type: String
        let message: String?
        let error: String?
        let reason: String?
    }

    private static let websocketBaseURLString = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    /// Manual-commit Scribe: the final is driven by our commit=true on
    /// key-release. A small trailing-audio grace (mirroring Deepgram)
    /// lets a clipped final word's audio reach the server first.
    let trailingAudioGraceSeconds: TimeInterval = 0.2

    private let token: String
    private let tokenFetchMs: Int
    private let engageStartedAt = Date()
    private var sessionStartedMs: Int?
    private var firstAudioSentMs: Int?
    private var firstPartialTimingLogged = false
    private let keyterms: [String]
    private var onTranscriptUpdate: (String) -> Void
    private var onFinalTranscriptReady: (String) -> Void
    private var onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.scribe.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.scribe.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false

    /// Committed (final) transcript segments in arrival order.
    private var finalizedSegments: [String] = []
    /// Most recent partial transcript; replaced on each partial, cleared on commit.
    private var activePartialTranscript: String = ""

    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?
    private var hasFailedOrTerminated = false

    init(
        token: String,
        tokenFetchMs: Int,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.token = token
        self.tokenFetchMs = tokenFetchMs
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(token: token)
        let websocketRequest = URLRequest(url: websocketURL)
        // Auth is carried in the `token` query param — no header needed.

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        // Resolve readiness as soon as the WSS handshake completes
        // (resume() returns), mirroring the proven Deepgram flow — the
        // server buffers early audio chunks and emits `session_started`
        // shortly after. If auth/params are bad, the receive loop fails
        // and surfaces onError, aborting the engage.
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
                self.resolveReadyContinuationIfNeeded(with: .success(()))
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        let base64 = audioPCM16Data.base64EncodedString()
        if firstAudioSentMs == nil {
            firstAudioSentMs = Int(Date().timeIntervalSince(engageStartedAt) * 1000)
        }
        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "sample_rate": 16000,
        ])
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }
        // Force a commit of the current buffer (manual commit strategy).
        // Server responds with a committed_transcript for the segment.
        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": 16000,
        ])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
            self.hasFailedOrTerminated = true
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }
        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)
            switch envelope.message_type {
            case "session_started":
                if sessionStartedMs == nil {
                    sessionStartedMs = Int(Date().timeIntervalSince(engageStartedAt) * 1000)
                }
            case "partial_transcript":
                let msg = try JSONDecoder().decode(TranscriptMessage.self, from: messageData)
                handleTranscript(text: msg.text ?? "", isFinal: false)
            case "committed_transcript":
                let msg = try JSONDecoder().decode(TranscriptMessage.self, from: messageData)
                handleTranscript(text: msg.text ?? "", isFinal: true)
            case "committed_transcript_with_timestamps":
                // We don't request timestamps; ignore if it arrives.
                break
            default:
                if envelope.message_type.lowercased().contains("error") {
                    let err = try? JSONDecoder().decode(ScribeErrorMessage.self, from: messageData)
                    let reason = err?.message ?? err?.error ?? err?.reason
                        ?? "Scribe error (\(envelope.message_type))."
                    failSession(with: ScribeStreamingTranscriptionProviderError(message: reason))
                }
                // Other informational message types: no-op.
            }
        } catch {
            print("⚠️ Scribe: failed to parse message (\(error)) — \(text.prefix(120))")
        }
    }

    private func handleTranscript(text rawText: String, isFinal: Bool) {
        // v16pb: Scribe (unlike Deepgram/Parakeet) leaves "um/uh" fillers in
        // and inserts "…" on pauses. Strip both so Scribe matches the other
        // engines — done here at the source, not in the shared repunctuate
        // prompt (which deliberately preserves fillers for other modes).
        let transcriptText = Self.cleanScribeArtifacts(rawText)

        if !transcriptText.isEmpty {
            VTTLatencyDiag.markFirstProviderTurn(preview: transcriptText)
            if !firstPartialTimingLogged {
                firstPartialTimingLogged = true
                let firstPartialMs = Int(Date().timeIntervalSince(engageStartedAt) * 1000)
                Self.appendScribeTiming(
                    tokenMs: tokenFetchMs,
                    sessionStartedMs: sessionStartedMs,
                    firstAudioSentMs: firstAudioSentMs,
                    firstPartialMs: firstPartialMs
                )
            }
        }

        stateQueue.async {
            if isFinal {
                if !transcriptText.isEmpty {
                    self.finalizedSegments.append(transcriptText)
                }
                self.activePartialTranscript = ""
            } else {
                self.activePartialTranscript = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }
            if isFinal {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func composeFullTranscript() -> String {
        var segments = finalizedSegments
        let trimmedPartial = activePartialTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            segments.append(trimmedPartial)
        }
        return segments.joined(separator: " ")
    }

    private func bestAvailableTranscriptText() -> String {
        composeFullTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            self.hasFailedOrTerminated = true
            let latestTranscriptText = self.bestAvailableTranscriptText()
            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[Scribe] ⚠️ WebSocket error during active session, delivering partial as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[Scribe] ❌ Session failed with error: \(error.localizedDescription)")
            self.onError(error)
        }
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true
            let continuation = self.readyContinuation
            self.readyContinuation = nil
            switch result {
            case .success:
                continuation?.resume()
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }

    /// v16pb: strip Scribe's filler words ("um"/"uh" + lengthened variants,
    /// with any trailing comma) and pause ellipses ("…"/"..."), then tidy
    /// whitespace/punctuation. Word-bounded so it never touches "umbrella"
    /// etc. Matches Deepgram/Parakeet, which arrive pre-stripped.
    // Quote chars (straight + smart) hugging the filler are consumed WITH it,
    // so "um" / ''um" don't leave orphaned quotes behind. Word-bounded.
    private static let scribeFillerRegex = try? NSRegularExpression(
        pattern: "[\"“”'‘’]*\\b([Uu]m+|[Uu]h+)\\b[\"“”'‘’]*,?", options: [])
    static func cleanScribeArtifacts(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "…", with: " ")
        t = t.replacingOccurrences(of: "...", with: " ")
        if let rx = scribeFillerRegex {
            t = rx.stringByReplacingMatches(
                in: t, options: [], range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        // Remove any empty quote pairs left behind (straight + smart).
        for empty in ["\"\"", "''", "“”", "‘’"] {
            t = t.replacingOccurrences(of: empty, with: "")
        }
        // Collapse runs of whitespace + fix orphaned space-before-punctuation.
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ,", with: ",")
        t = t.replacingOccurrences(of: " .", with: ".")
        t = t.replacingOccurrences(of: " ?", with: "?")
        t = t.replacingOccurrences(of: " !", with: "!")
        t = t.replacingOccurrences(of: ",,", with: ",")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// v16 diag: per-engage phase timing to /tmp/clicky_scribe_timing.log
    /// so we can see exactly where the first-partial latency goes —
    /// token fetch vs handshake (session_started) vs server first-partial.
    /// ms are relative to session creation (just after the token fetch).
    private static func appendScribeTiming(tokenMs: Int, sessionStartedMs: Int?, firstAudioSentMs: Int?, firstPartialMs: Int) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let ss = sessionStartedMs.map { "\($0)ms" } ?? "—"
        let fa = firstAudioSentMs.map { "\($0)ms" } ?? "—"
        let line = "[\(ts)] tokenFetch=\(tokenMs)ms sessionStarted=\(ss) firstAudioSent=\(fa) firstPartial=\(firstPartialMs)ms\n"
        let path = "/tmp/clicky_scribe_timing.log"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func makeWebsocketURL(token: String) throws -> URL {
        guard var components = URLComponents(string: websocketBaseURLString) else {
            throw ScribeStreamingTranscriptionProviderError(message: "Scribe websocket URL is invalid.")
        }
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "include_timestamps", value: "false"),
            // keyterms intentionally omitted in v1 (20% cost premium +
            // 20-char cap); downstream correctNames() handles proper
            // nouns. Revisit if the bake-off shows Scribe needs them.
        ]
        guard let url = components.url else {
            throw ScribeStreamingTranscriptionProviderError(message: "Scribe websocket URL could not be created.")
        }
        return url
    }
}
