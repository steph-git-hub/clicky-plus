//
//  AssemblyAIStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by AssemblyAI's websocket API.
//

import AVFoundation
import Foundation

struct AssemblyAIStreamingTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AssemblyAIStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    /// URL for the Cloudflare Worker endpoint that returns a short-lived
    /// AssemblyAI streaming token. The real API key never leaves the server.
    private static let tokenProxyURL = "https://clicky-proxy.sapierso.workers.dev/transcribe-token"

    let displayName = "AssemblyAI"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after
    /// a few rapid reconnections to the same host.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    // v15p3bk (2026-05-12): warm-session cache. The biggest single
    // latency win in the audit (§8 #1) — kills 1-1.5s of cold-start
    // handshake (token fetch + WSS open + AssemblyAI "Begin" message)
    // on every VTT engage. Strategy:
    //   - At app launch and after every session ends, kick off a
    //     background prewarm that opens an idle websocket and stores
    //     it here.
    //   - On engage, if a warm session exists AND its keyterms match
    //     the upcoming request, hand it off (just swap in real callbacks)
    //     and the audio path can start streaming immediately.
    //   - Mismatch → cold start (existing path), leave warm for a later
    //     match (the 25s discard timer will evict eventually).
    //   - Server auto-terminates idle WSS after ~30s; discard timer is
    //     well under that.
    private let warmingQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.prewarm")
    private var warmSession: AssemblyAIStreamingTranscriptionSession?
    private var warmDiscardWorkItem: DispatchWorkItem?
    private static let warmIdleLifetimeSeconds: TimeInterval = 25.0

    /// Open a websocket session in the background with the given keyterms
    /// and hold it idle until either (a) an engage happens that matches
    /// these keyterms — at which point the engage path adopts it as the
    /// active session — or (b) the 25-second idle timer fires and we
    /// drop the session. Cancels and replaces any prior warm session.
    /// Safe to call from any thread; runs the actual network work in a
    /// detached Task. Errors are swallowed silently — a failed prewarm
    /// just means the next engage cold-starts as it always did.
    func prewarmSession(keyterms: [String]) {
        // v15p4co (2026-05-30): prewarm DISABLED for AssemblyAI. The warm
        // socket is a SECOND concurrent session stacked on the active one,
        // and AssemblyAI's account concurrent-session cap is low enough
        // that warm + active (plus slow server-side slot release) trips
        // Error 1008 "too many concurrent sessions" even under normal use.
        // As a secondary provider it's better active-only: one live
        // session that can't pile up, at the cost of a cold start each
        // engage. Flip to true to restore prewarming if the account's
        // concurrency limit is ever raised.
        let assemblyAIPrewarmEnabled = false
        guard assemblyAIPrewarmEnabled else { return }
        warmingQueue.async { [weak self] in
            guard let self else { return }

            // Cancel any prior warm — it's about to be replaced.
            self.warmSession?.cancel()
            self.warmSession = nil
            self.warmDiscardWorkItem?.cancel()
            self.warmDiscardWorkItem = nil

            Task { [weak self] in
                guard let self else { return }
                do {
                    let temporaryToken = try await self.fetchTemporaryToken()
                    let session = AssemblyAIStreamingTranscriptionSession(
                        apiKey: nil,
                        temporaryToken: temporaryToken,
                        urlSession: self.sharedWebSocketURLSession,
                        keyterms: keyterms,
                        onTranscriptUpdate: { _ in /* warm — no-op until adoption */ },
                        onFinalTranscriptReady: { _ in /* warm — no-op until adoption */ },
                        onError: { [weak self] _ in
                            // If the warm session errors before handoff,
                            // drop it from the cache so the next engage
                            // cold-starts cleanly.
                            self?.warmingQueue.async {
                                self?.warmSession?.cancel()
                                self?.warmSession = nil
                                self?.warmDiscardWorkItem?.cancel()
                                self?.warmDiscardWorkItem = nil
                            }
                        }
                    )
                    try await session.open()
                    self.warmingQueue.async {
                        // If someone else replaced us mid-open, discard
                        // this freshly-opened session — newest wins.
                        if self.warmSession != nil {
                            session.cancel()
                            return
                        }
                        self.warmSession = session
                        print("🎙️ AssemblyAI: warm session ready (keyterms=\(keyterms.count))")
                        // Arm the discard timer.
                        let discard = DispatchWorkItem { [weak self] in
                            self?.warmingQueue.async {
                                self?.warmSession?.cancel()
                                self?.warmSession = nil
                                self?.warmDiscardWorkItem = nil
                                print("🎙️ AssemblyAI: warm session evicted (idle > \(Int(Self.warmIdleLifetimeSeconds))s)")
                            }
                        }
                        self.warmDiscardWorkItem = discard
                        self.warmingQueue.asyncAfter(
                            deadline: .now() + Self.warmIdleLifetimeSeconds,
                            execute: discard
                        )
                    }
                } catch {
                    print("🎙️ AssemblyAI: prewarm failed (\(error.localizedDescription)) — next engage cold-starts")
                }
            }
        }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // v15p3bk: try the warm cache first.
        let normalizedRequestedKeyterms = Self.normalizeKeyterms(keyterms)
        let warmCandidate: AssemblyAIStreamingTranscriptionSession? = warmingQueue.sync {
            guard let warm = warmSession, warm.isStillUsable else { return nil }
            let warmKeyterms = Self.normalizeKeyterms(warm.openedWithKeyterms)
            guard warmKeyterms == normalizedRequestedKeyterms else { return nil }
            // Match: consume the warm session and clear the cache.
            warmSession = nil
            warmDiscardWorkItem?.cancel()
            warmDiscardWorkItem = nil
            return warm
        }

        if let warm = warmCandidate {
            warm.adoptCallbacks(
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
            print("🎙️ AssemblyAI: handed off warm session (zero handshake latency)")
            return warm
        }

        // Cold path — original behavior.
        let temporaryToken = try await fetchTemporaryToken()
        print("🎙️ AssemblyAI: fetched temporary token (\(temporaryToken.prefix(20))...) [cold start]")

        let session = AssemblyAIStreamingTranscriptionSession(
            apiKey: nil,
            temporaryToken: temporaryToken,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// Normalize a keyterms array for warm-cache equality checks: trim,
    /// drop empties, lowercase, dedupe (preserving first-occurrence order
    /// shouldn't matter for AssemblyAI but we sort to make equality
    /// order-independent). A warm session with the same SET of keyterms
    /// is equivalent to a fresh one for matching purposes.
    private static func normalizeKeyterms(_ keyterms: [String]) -> [String] {
        let normalized = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }

    /// Calls the Cloudflare Worker to get a short-lived AssemblyAI token.
    private func fetchTemporaryToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Failed to fetch AssemblyAI token (HTTP \(statusCode)): \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class AssemblyAIStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct TurnMessage: Decodable {
        let type: String
        let transcript: String?
        let turn_order: Int?
        let end_of_turn: Bool?
        let turn_is_formatted: Bool?
    }

    private struct ErrorMessage: Decodable {
        let type: String
        let error: String?
        let message: String?
    }

    private struct StoredTurnTranscript {
        var transcriptText: String
        var isFormatted: Bool
    }

    private static let websocketBaseURLString = "wss://streaming.assemblyai.com/v3/ws"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let apiKey: String?
    private let temporaryToken: String?
    private let keyterms: [String]
    // v15p3bk (2026-05-12): callbacks made mutable (with stateQueue
    // synchronization) so a pre-warmed session can adopt real callbacks
    // at handoff time. Initially set to no-ops; the provider calls
    // `adoptCallbacks` to swap in real handlers when transitioning a
    // warm session into an active one. Reads from receive thread, writes
    // from the engage path — both go through stateQueue.async.
    private var onTranscriptUpdate: (String) -> Void
    private var onFinalTranscriptReady: (String) -> Void
    private var onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var activeTurnOrder: Int?
    private var activeTurnTranscriptText = ""
    private var storedTurnTranscriptsByOrder: [Int: StoredTurnTranscript] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?
    // v15p3bk: tracks whether the session is still usable for a fresh
    // engage. Flips to false if the websocket errors or terminates
    // during the warm-idle window. Used by the provider to decide
    // whether to hand off a warm session or fall through to cold start.
    private var hasFailedOrTerminated = false

    init(
        apiKey: String?,
        temporaryToken: String?,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.temporaryToken = temporaryToken
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    // v15p3bk (2026-05-12): swap a warm session's no-op callbacks for
    // real ones at handoff time. Must be called BEFORE any audio is
    // sent — otherwise transcript updates fired during the swap window
    // would land in the wrong handler (or get dropped). All reads of
    // the callbacks are dispatched through stateQueue, so writing them
    // there is the synchronization point.
    func adoptCallbacks(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        stateQueue.sync {
            self.onTranscriptUpdate = onTranscriptUpdate
            self.onFinalTranscriptReady = onFinalTranscriptReady
            self.onError = onError
        }
    }

    // v15p3bk: snapshot of the keyterms this session was opened with.
    // The provider uses this to decide whether a warm session matches
    // the upcoming engage's keyterm set. Mismatch → cold-start that
    // engage and keep the warm session for a potential later match
    // (or let the 25s discard timer evict it).
    var openedWithKeyterms: [String] { keyterms }

    // v15p3bk: liveness check. False after any websocket error,
    // any server "Termination" message, or any call to cancel().
    // The provider checks this before handing off — a dead warm
    // session should never be returned to the engage path.
    var isStillUsable: Bool {
        stateQueue.sync { !hasFailedOrTerminated && !hasDeliveredFinalTranscript }
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(
            temporaryToken: temporaryToken,
            keyterms: keyterms
        )

        var websocketRequest = URLRequest(url: websocketURL)
        if let apiKey {
            websocketRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        }

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.data(audioPCM16Data)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage(["type": "ForceEndpoint"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
            // v15p3bk: mark dead so the provider's warm cache won't
            // attempt to hand off this session.
            self.hasFailedOrTerminated = true
        }

        sendJSONMessage(["type": "Terminate"])
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
                let code = self.webSocketTask?.closeCode.rawValue ?? -1
                let reason = self.webSocketTask?.closeReason
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                let ns = error as NSError
                Self.appendAADiag("RECV FAILURE: \(error.localizedDescription) | \(ns.domain)#\(ns.code) | closeCode=\(code) reason=\(reason)")
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)

            // v15p4cm: log every non-Turn message raw so Begin /
            // Termination / error payloads (e.g. concurrency caps) are
            // visible in /tmp/clicky_assemblyai_diag.log.
            if envelope.type.lowercased() != "turn" {
                Self.appendAADiag("MSG type=\(envelope.type): \(text.prefix(400))")
            }

            switch envelope.type.lowercased() {
            case "begin":
                resolveReadyContinuationIfNeeded(with: .success(()))
            case "turn":
                let turnMessage = try JSONDecoder().decode(TurnMessage.self, from: messageData)
                handleTurnMessage(turnMessage)
            case "termination":
                resolveReadyContinuationIfNeeded(with: .success(()))
                stateQueue.async {
                    // v15p3bk: mark dead so a warm session can't be
                    // mistakenly handed off after the server has
                    // closed its end. AssemblyAI auto-terminates idle
                    // websockets after ~30s — that path lands here.
                    self.hasFailedOrTerminated = true
                    if self.isAwaitingExplicitFinalTranscript && !self.hasDeliveredFinalTranscript {
                        self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
                    }
                }
            case "error":
                let errorMessage = try JSONDecoder().decode(ErrorMessage.self, from: messageData)
                let messageText = errorMessage.error ?? errorMessage.message ?? "AssemblyAI returned an error."
                failSession(with: AssemblyAIStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleTurnMessage(_ turnMessage: TurnMessage) {
        let transcriptText = turnMessage.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // v15p3br (2026-05-13): mark T2 in the live-preview latency
        // diag. Idempotent — only the first Turn message per engage
        // records a value. Skip empty transcripts so the timer
        // measures press → first usable content, not press → first
        // empty heartbeat.
        if !transcriptText.isEmpty {
            VTTLatencyDiag.markFirstAssemblyAITurn(preview: transcriptText)
        }

        stateQueue.async {
            let turnOrder = turnMessage.turn_order
                ?? self.activeTurnOrder
                ?? ((self.storedTurnTranscriptsByOrder.keys.max() ?? -1) + 1)

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.activeTurnOrder = nil
                self.activeTurnTranscriptText = ""
                self.storeTurnTranscript(
                    transcriptText,
                    forTurnOrder: turnOrder,
                    isFormatted: turnMessage.turn_is_formatted == true
                )
            } else {
                self.activeTurnOrder = turnOrder
                self.activeTurnTranscriptText = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            self.latestTranscriptText = fullTranscriptText

            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func storeTurnTranscript(
        _ transcriptText: String,
        forTurnOrder turnOrder: Int,
        isFormatted: Bool
    ) {
        guard !transcriptText.isEmpty else { return }

        if let existingTurnTranscript = storedTurnTranscriptsByOrder[turnOrder] {
            if existingTurnTranscript.isFormatted && !isFormatted {
                return
            }
        }

        storedTurnTranscriptsByOrder[turnOrder] = StoredTurnTranscript(
            transcriptText: transcriptText,
            isFormatted: isFormatted
        )
    }

    private func composeFullTranscript() -> String {
        let committedTranscriptSegments = storedTurnTranscriptsByOrder
            .sorted(by: { $0.key < $1.key })
            .map(\.value.transcriptText)
            .filter { !$0.isEmpty }

        var transcriptSegments = committedTranscriptSegments

        let trimmedActiveTurnTranscriptText = activeTurnTranscriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedActiveTurnTranscriptText.isEmpty {
            transcriptSegments.append(trimmedActiveTurnTranscriptText)
        }

        return transcriptSegments.joined(separator: " ")
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
        hasFailedOrTerminated = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        sendJSONMessage(["type": "Terminate"])
        // v15p4cn (2026-05-30): close the socket shortly after Terminate
        // so the concurrent-session count drops immediately. Previously
        // the success path left the socket open, relying on AssemblyAI's
        // ~30s idle auto-terminate — under rapid dictation that piled up
        // half-open sessions and tripped the "too many concurrent
        // sessions" (1008) cap, and billed idle connection time. The
        // 300ms delay lets the Terminate frame flush first.
        let taskToClose = webSocketTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            taskToClose?.cancel(with: .goingAway, reason: nil)
        }
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

    private static let aaDiagPath = "/tmp/clicky_assemblyai_diag.log"
    /// v15p4cm (2026-05-30): AssemblyAI failure diagnostics — WSS close
    /// codes/reasons + non-Turn server messages, to pin down why
    /// sessions stop returning transcripts (concurrency cap vs cleanup).
    static func appendAADiag(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: aaDiagPath) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: aaDiagPath)) {
                defer { try? h.close() }
                try? h.seekToEnd()
                try? h.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: aaDiagPath))
        }
    }

    private func failSession(with error: Error) {
        Self.appendAADiag("SESSION FAILED: \(error.localizedDescription)")
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            // v15p3bk: mark dead immediately so the provider's warm
            // cache rejects this session on the next handoff attempt.
            self.hasFailedOrTerminated = true
            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[AssemblyAI] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[AssemblyAI] ❌ Session failed with error: \(error.localizedDescription)")

            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private static func makeWebsocketURL(
        temporaryToken: String?,
        keyterms: [String]
    ) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL is invalid."
            )
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            // format_turns=false (v11h, 2026-04-27): AssemblyAI's
            // pause-detection auto-punctuation inserted commas at every
            // mid-thought pause, breaking up Steph's natural speech with
            // unwanted punctuation. We disable formatting here and run
            // the raw transcript through Haiku /repunctuate in the Mac
            // app for context-based (not pause-based) punctuation.
            // Steph's spoken-punctuation overrides ("comma", "new
            // paragraph", etc.) still win because they apply AFTER Haiku.
            URLQueryItem(name: "format_turns", value: "false"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro"),
            // v15p3bs (2026-05-13): tune partial-emission cadence for
            // smoother live preview.
            //
            // Doc deep-dive 2026-05-13 corrected yesterday's confusion:
            // for Universal-3 Pro Streaming (u3-rt-pro), the correct
            // parameter name is `min_turn_silence` (NOT the older
            // model's `min_end_of_turn_silence_when_confident`). Per
            // the docs: "Silence duration in milliseconds before a
            // speculative end-of-turn check. If terminal punctuation
            // is found, the turn ends. Otherwise, a partial is emitted
            // and the turn continues." Default: 100ms.
            //
            // The latency-diag (v15p3br) measurement on 2026-05-13
            // showed press → first-partial averaging ~1.7s with the
            // default 100ms. Steph reported: first few words appear,
            // then partials stall while he speaks continuously, then
            // updates resume after a pause. That's the silence-check
            // floor gating partial emission. Halving min_turn_silence
            // to 50ms doubles the check frequency.
            //
            // v15p3bt (2026-05-13): pushed further to 25ms. The 50ms
            // value (v15p3bs) cut first-partial latency from ~1912ms
            // → ~1356ms (29% improvement) and tightened the spread
            // from 2.6s → 0.5s. Going to 25ms doubles the check
            // frequency again — testing whether AssemblyAI has any
            // remaining slack between "audio processed and ready" and
            // "next emission check fires." max_turn_silence (1000ms
            // default) still bounds the worst case, so false end-of-
            // turn detection risk is bounded. Easy revert to 50ms if
            // partials get unstable.
            URLQueryItem(name: "min_turn_silence", value: "25")
        ]

        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedKeyterms.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: normalizedKeyterms),
           let keytermsJSONString = String(data: keytermsData, encoding: .utf8) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSONString))
        }

        if let temporaryToken {
            queryItems.append(URLQueryItem(name: "token", value: temporaryToken))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL could not be created."
            )
        }

        return websocketURL
    }
}
