//
//  DeepgramStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by Deepgram's Nova-3
//  Live Audio websocket API.
//
//  v15p3bu (2026-05-13): added as a side-by-side alternative to
//  AssemblyAI's u3-rt-pro for evaluation. Conforms to
//  BuddyTranscriptionProvider so it slots into BuddyDictationManager
//  with no architectural changes — provider selection happens at the
//  factory level (or via a hotkey-scoped override for active A/B
//  testing). The active dictation path picks whichever provider was
//  named at session start; the live preview, repunctuate, polish,
//  and paste downstream layers are unchanged.
//
//  Endpoint: wss://api.deepgram.com/v1/listen
//  Auth: short-lived JWT minted server-side by the clicky-proxy
//        Worker's /deepgram-token route. The master DEEPGRAM_API_KEY
//        lives only in Worker secrets.
//  Model: nova-3 (best accuracy + latency, supports keyterm prompting)
//

import AVFoundation
import Foundation

struct DeepgramStreamingTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class DeepgramStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private static let tokenProxyURL = "https://clicky-proxy.sapierso.workers.dev/deepgram-token"

    let displayName = "Deepgram"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Long-lived URLSession shared across all streaming sessions.
    /// Same rationale as the AssemblyAI provider — per-session
    /// invalidation corrupts the connection pool and causes
    /// "Socket is not connected" errors on rapid reconnect.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let temporaryToken = try await fetchTemporaryToken()
        print("🎙️ Deepgram: fetched temporary token (\(temporaryToken.prefix(20))...)")

        let session = DeepgramStreamingTranscriptionSession(
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

    private func fetchTemporaryToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw DeepgramStreamingTranscriptionProviderError(
                message: "Failed to fetch Deepgram token (HTTP \(statusCode)): \(body)"
            )
        }

        // Deepgram's grant-token response: { access_token: string, expires_in: number }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw DeepgramStreamingTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class DeepgramStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    // Deepgram Results message shape:
    // {
    //   "type": "Results",
    //   "is_final": bool,
    //   "speech_final": bool,
    //   "channel": { "alternatives": [{ "transcript": "..." }] },
    //   ...
    // }
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct ResultsAlternative: Decodable {
        let transcript: String?
    }

    private struct ResultsChannel: Decodable {
        let alternatives: [ResultsAlternative]?
    }

    private struct ResultsMessage: Decodable {
        let type: String
        let channel: ResultsChannel?
        let is_final: Bool?
        let speech_final: Bool?
    }

    private struct ErrorMessage: Decodable {
        let type: String
        let description: String?
        let message: String?
        let reason: String?
    }

    private static let websocketBaseURLString = "wss://api.deepgram.com/v1/listen"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    /// Slightly tighter than AssemblyAI's 2.8s — Deepgram typically
    /// delivers the post-Finalize transcript in well under a second.
    /// If we miss it, the audio diag's EMPTY_TRANSCRIPT_ON_FINALIZE
    /// path still captures the failure.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    /// v15p3gx (2026-05-18): trailing-audio grace window. Deepgram's
    /// smart_format pipeline frequently drops the last word when the
    /// mic tap is removed at key-release — partly because
    /// AVAudioEngine's tap doesn't flush partial buffers, partly
    /// because Deepgram's endpointer (300ms) needs trailing silence
    /// to confirm an utterance boundary cleanly. BuddyDictationManager
    /// holds the tap open up to this many seconds after release,
    /// gated by audio-power-level silence detection — so users who
    /// pause naturally before releasing pay zero added latency, while
    /// fast releases mid-word get the audio captured.
    let trailingAudioGraceSeconds: TimeInterval = 0.2

    private let temporaryToken: String
    private let keyterms: [String]
    private var onTranscriptUpdate: (String) -> Void
    private var onFinalTranscriptReady: (String) -> Void
    private var onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.deepgram.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.deepgram.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false

    /// Finalized transcript segments in arrival order. Each entry is
    /// the `transcript` field from a Results message with is_final=true.
    private var finalizedSegments: [String] = []

    /// The most recent partial transcript (Results with is_final=false).
    /// Replaced on every new partial, cleared when a final lands.
    private var activePartialTranscript: String = ""

    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?
    private var hasFailedOrTerminated = false

    init(
        temporaryToken: String,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.temporaryToken = temporaryToken
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(keyterms: keyterms)
        var websocketRequest = URLRequest(url: websocketURL)
        // Deepgram supports two auth styles for WSS:
        //   1. Authorization: Bearer <jwt> (works in URLSession)
        //   2. Sec-WebSocket-Protocol: token, <jwt> (for browsers)
        // We have URLRequest so style 1 is fine.
        websocketRequest.setValue("Bearer \(temporaryToken)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        // Deepgram doesn't send a separate "ready" message before
        // accepting audio — the WebSocket handshake completing IS the
        // ready signal. URLSession's webSocketTask.resume() completes
        // when the handshake is done. We send the first audio
        // immediately after; Deepgram buffers it server-side.
        //
        // We still wait for the first Results message (or a Metadata)
        // to confirm the session is alive. That's what
        // readyContinuation does — the first valid message resolves it.
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
                // Deepgram is ready as soon as the WSS handshake
                // completes (URLSession returns from resume()).
                // Resolve immediately so the audio handoff can flush.
                // If the server rejects auth or params, the receive
                // loop will fail and call onError downstream — by
                // which point the dictation manager has already
                // started streaming, which is OK because the failure
                // surfaces as an error and aborts the engage.
                self.resolveReadyContinuationIfNeeded(with: .success(()))
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

        // Deepgram's Finalize flushes any buffered audio and forces
        // emission of an is_final=true Results message for the
        // current segment. Equivalent to AssemblyAI's ForceEndpoint.
        sendJSONMessage(["type": "Finalize"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
            self.hasFailedOrTerminated = true
        }
        // CloseStream signals graceful shutdown — Deepgram flushes
        // and closes the WSS cleanly. .goingAway on the WS task is a
        // belt-and-suspenders to ensure the socket teardown.
        sendJSONMessage(["type": "CloseStream"])
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

            switch envelope.type {
            case "Results":
                let results = try JSONDecoder().decode(ResultsMessage.self, from: messageData)
                handleResultsMessage(results, withPreview: text)
            case "Metadata":
                // Final metadata after CloseStream. No-op for us.
                break
            case "UtteranceEnd":
                // Fires when Deepgram's endpointing detects end of
                // speech. With our hold-mode VTT the user-release
                // signal drives finalization, so this is mostly
                // informational. Don't act on it.
                break
            case "SpeechStarted":
                // Informational. No-op.
                break
            case "Error":
                let errorMessage = (try? JSONDecoder().decode(ErrorMessage.self, from: messageData))
                let messageText = errorMessage?.description
                    ?? errorMessage?.message
                    ?? errorMessage?.reason
                    ?? "Deepgram returned an error."
                failSession(with: DeepgramStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            // Unparseable messages — log + continue. A bad JSON shape
            // from Deepgram shouldn't kill the session.
            print("⚠️ Deepgram: failed to parse message (\(error)) — \(text.prefix(120))")
        }
    }

    private func handleResultsMessage(_ message: ResultsMessage, withPreview rawJSON: String) {
        let transcriptText = message.channel?.alternatives?.first?.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // v15p3bv (2026-05-13): mark first non-empty provider response
        // in the latency diag. Mirrors the AssemblyAI Turn marker so
        // both providers contribute the firstTurn column.
        if !transcriptText.isEmpty {
            VTTLatencyDiag.markFirstProviderTurn(preview: transcriptText)
        }

        stateQueue.async {
            let isFinal = message.is_final == true

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

            // If the user already released (sent Finalize) and we
            // just received the first is_final=true Results after
            // that, deliver the final transcript and tear down.
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
        let composed = composeFullTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        return composed
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
        // Tell Deepgram we're done so it releases server resources.
        sendJSONMessage(["type": "CloseStream"])
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
                print("[Deepgram] ⚠️ WebSocket error during active session, delivering partial as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[Deepgram] ❌ Session failed with error: \(error.localizedDescription)")
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

    private static func makeWebsocketURL(keyterms: [String]) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw DeepgramStreamingTranscriptionProviderError(
                message: "Deepgram websocket URL is invalid."
            )
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            // interim_results=true is THE key for live preview —
            // without it, Deepgram only sends finals.
            URLQueryItem(name: "interim_results", value: "true"),
            // Punctuation + smart formatting handled here in the
            // streaming output. Polish + /repunctuate still apply
            // downstream same as AssemblyAI.
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            // Default endpointing is 10ms; bumping slightly helps
            // avoid premature finals during mid-sentence pauses.
            // Mirrors the rationale behind AssemblyAI's min_turn_silence
            // tune, scaled to Deepgram's much lower default.
            URLQueryItem(name: "endpointing", value: "300"),
        ]

        // Deepgram Nova-3 supports keyterm prompting. Send each
        // keyterm as its own query item — multiple `keyterm=` params
        // accumulate server-side.
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for term in normalizedKeyterms {
            queryItems.append(URLQueryItem(name: "keyterm", value: term))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw DeepgramStreamingTranscriptionProviderError(
                message: "Deepgram websocket URL could not be created."
            )
        }
        return websocketURL
    }
}
