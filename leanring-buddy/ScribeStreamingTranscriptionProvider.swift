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

struct ScribeStreamingTranscriptionProviderError: LocalizedError, BuddyProviderFatalError {
    let message: String
    /// True when the server refused the session for an account-level
    /// reason (quota, auth) — retrying or reconnecting cannot help, so
    /// the caller should switch engines rather than fail silently.
    var isAccountFatal: Bool = false
    var errorDescription: String? { message }

    var isProviderFatal: Bool { isAccountFatal }
    var providerFatalReason: String { message }
    var providerFatalLabel: String { "Scribe" }
}

/// v16r21 (2026-08-10): transport seam.
///
/// The session used to build its own `URLSessionWebSocketTask` inline, so
/// the only way to execute it was against the live ElevenLabs endpoint.
/// There was no way to make the connection stall, half-close, or reject a
/// write on demand — which is why v16r19's stall watchdog shipped
/// unexercised and took the app down inside ten seconds of real use.
///
/// Nothing about the session's behavior changes: in the app it is handed a
/// `URLSessionWebSocketTask` exactly as before. In
/// `scripts/verify_scribe_stall_recovery.swift` it is handed a fake that
/// misbehaves to order — and the SHIPPED session logic is what runs
/// against it, not a transcribed copy that can drift.
enum ScribeSocketFrame {
    case text(String)
    case binary(Data)
    /// A frame kind URLSession may add in future — ignored, exactly as
    /// the original `@unknown default: break` did.
    case unsupported
}

protocol ScribeWebSocketChannel: AnyObject {
    func resume()
    func send(text: String, completionHandler: @escaping (Error?) -> Void)
    func receive(completionHandler: @escaping (Result<ScribeSocketFrame, Error>) -> Void)
    /// Close with `.goingAway`, matching the original call sites.
    func cancelGoingAway()
}

extension URLSessionWebSocketTask: ScribeWebSocketChannel {
    func send(text: String, completionHandler: @escaping (Error?) -> Void) {
        send(.string(text), completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping (Result<ScribeSocketFrame, Error>) -> Void) {
        receive { result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    completionHandler(.success(.text(text)))
                case .data(let data):
                    completionHandler(.success(.binary(data)))
                @unknown default:
                    completionHandler(.success(.unsupported))
                }
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }

    func cancelGoingAway() {
        cancel(with: .goingAway, reason: nil)
    }
}

final class ScribeStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private static let tokenProxyURL = "https://clicky-proxy.sapierso.workers.dev/scribe-token"

    /// v16r20 (2026-08-06): session-lifecycle diag at
    /// /tmp/clicky_scribe_session.log. Scribe previously logged only
    /// latency, so a server-side refusal — the actual cause of the
    /// 2026-08-06 outage — left no record anywhere. Shared with the
    /// engine-fallback path in CompanionManager so the switch and its
    /// reason land in the same file.
    private static let sessionDiagQueue = DispatchQueue(
        label: "com.learningbuddy.scribe.session-diag"
    )

    static func appendSessionDiag(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        sessionDiagQueue.async {
            let path = "/tmp/clicky_scribe_session.log"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

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

        let urlSession = sharedWebSocketURLSession
        let session = ScribeStreamingTranscriptionSession(
            token: token,
            tokenFetchMs: tokenFetchMs,
            makeChannel: { url in urlSession.webSocketTask(with: URLRequest(url: url)) },
            // v16r23: reconnect needs a FRESH single-use token — the one
            // used for the original socket is spent. Bounded at 4s so a
            // slow token endpoint can't hang a recovery.
            tokenProvider: { [weak self] in
                guard let self else {
                    throw ScribeStreamingTranscriptionProviderError(
                        message: "Scribe provider deallocated during reconnect."
                    )
                }
                return try await self.fetchSingleUseToken()
            },
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
    /// v16r20 (2026-08-06): last token handed out, kept ONLY to support
    /// the fault-injection flag below.
    private var lastIssuedToken: String?

    /// Fault injection for the account-fatal path. Set with:
    ///   defaults write com.stephenpierson.clickyplus \
    ///       clicky.debug.forceScribeAuthFailure -bool true
    /// and the next engage replays a spent single-use token, which
    /// ElevenLabs refuses with a real `auth_error` — the same shape as a
    /// quota refusal. That exercises classification → error → engine
    /// fallback → user notice against the live server.
    ///
    /// Exists because the alternative is waiting for a real outage to
    /// find out whether the recovery path works. On 2026-08-06 it didn't,
    /// and the cost was a day.
    private var shouldForceAuthFailure: Bool {
        UserDefaults.standard.bool(forKey: "clicky.debug.forceScribeAuthFailure")
    }

    private func tokenForEngage() async throws -> String {
        if shouldForceAuthFailure, let spent = warmingQueue.sync(execute: { lastIssuedToken }) {
            print("🧪 Scribe: forcing auth failure — replaying spent token")
            return spent
        }
        let cached: String? = warmingQueue.sync {
            if let c = cachedToken,
               Date().timeIntervalSince(c.fetchedAt) < Self.tokenFreshnessSeconds {
                cachedToken = nil
                return c.value
            }
            cachedToken = nil
            return nil
        }
        if let cached {
            warmingQueue.async { self.lastIssuedToken = cached }
            return cached
        }
        let fresh = try await fetchSingleUseToken()
        warmingQueue.async { self.lastIssuedToken = fresh }
        return fresh
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

/// v16r21: internal rather than file-private so the standalone harness in
/// `scripts/verify_scribe_stall_recovery.swift` can construct it directly
/// with a fake channel. Nothing outside this file constructs it in the app.
final class ScribeStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
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
    /// v16r21: the connection is handed in rather than built here. In the
    /// app this returns a `URLSessionWebSocketTask`; in the harness it
    /// returns a fake that can stall, half-close, or reject writes.
    private let makeChannel: (URL) -> ScribeWebSocketChannel

    private var channel: ScribeWebSocketChannel?
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

    // MARK: - Reconnect on transport failure (v16r23, 2026-08-10)
    //
    // The toggle-mode cutoff: the receive loop took ONE `.failure` and
    // stopped reading forever. The socket was dead, the user kept talking,
    // the halo kept moving, and every word after that point was discarded.
    // Confirmed live on 2026-08-10 at 12:51 — a capture cut mid-word at
    // "...Anything nailed-".
    //
    // SCOPE: this recovers from an ACTUAL transport failure (the socket
    // errors). It deliberately does NOT include v16r19's stall watchdog,
    // which tried to infer "the server went quiet while you were talking"
    // from audio levels. That inference is the risky half and is a separate
    // job; `STALL-SUSPECT` diag lines below exist to tell us whether it's
    // even needed.
    //
    // WHY THIS IS SAFER THAN v16r19: that version shipped before the
    // v16r20 fatal classifier. During the ElevenLabs quota outage the
    // server refused every connection, reconnect read those refusals as
    // transient, burned its budget in seconds, and killed the session —
    // turning an account problem into an app failure. `shouldAttemptReconnect`
    // now refuses to reconnect on any account-fatal error, so that
    // amplification cannot recur.

    /// Fetches a fresh single-use token for a replacement socket. Injected
    /// so the harness can drive reconnect without network.
    private let tokenProvider: () async throws -> String

    /// Monotonic socket identity. EVERY receive and send completion compares
    /// this before acting. Without it, cancelling a dead socket completes its
    /// pending read with a cancellation error, which tears down the
    /// replacement — turning every recovery into a session kill. This was
    /// the single most important correctness property in v16r19.
    private var socketGeneration = 0

    private var isReconnecting = false
    private var reconnectAttempts = 0
    private var totalReconnectCount = 0
    private static let maxReconnectAttempts = 3

    /// Audio captured while there is no usable socket. Replayed in order
    /// once the replacement is live, so the gap isn't a hole in the words.
    private var bufferedAudioBase64DuringReconnect: [String] = []
    private static let maxBufferedAudioChunksDuringReconnect = 400
    private var didLogReconnectBufferOverflow = false

    /// The last few seconds of audio ALREADY sent to the (now dead) socket,
    /// timestamped. Detection is not instant, so some speech was fired at a
    /// socket that was already gone. Replaying the entries newer than the
    /// last acknowledged transcript closes that hole without duplicating
    /// words the server had already transcribed.
    private var preStallAudioRing: [(base64: String, capturedAt: Date)] = []
    private static let preStallRingBufferChunks = 120

    /// When the server last sent us a transcript frame. Used as the replay
    /// watermark, and to spot a silent stall for diagnostics.
    private var lastTranscriptMessageAt = Date()

    /// The user released the key while a rebuild was in flight, so the
    /// commit frame hit a nil socket. Latch it and re-issue on the new
    /// socket, or the server never commits and the tail is lost — the
    /// original symptom, reproduced by its own fix.
    private var pendingCommitAfterReconnect = false

    /// Terminal = nothing may act on this session any more.
    private var isTerminated: Bool {
        hasFailedOrTerminated || hasDeliveredFinalTranscript
    }

    init(
        token: String,
        tokenFetchMs: Int,
        makeChannel: @escaping (URL) -> ScribeWebSocketChannel,
        tokenProvider: @escaping () async throws -> String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.token = token
        self.tokenFetchMs = tokenFetchMs
        self.makeChannel = makeChannel
        self.tokenProvider = tokenProvider
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(token: token, keyterms: keyterms)
        // Auth is carried in the `token` query param — no header needed.

        let channel = makeChannel(websocketURL)
        let generation: Int = stateQueue.sync {
            self.socketGeneration += 1
            self.channel = channel
            return self.socketGeneration
        }
        channel.resume()

        receiveNextMessage(on: channel, generation: generation)

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

        // v16r23: route by session state instead of firing blindly.
        // Previously this pumped audio into a dead socket, and each send
        // error re-entered failSession — one fault became one fault per
        // 20ms of speech.
        enum AudioRoute { case send, buffer, drop }
        let route: AudioRoute = stateQueue.sync {
            if self.isTerminated { return .drop }
            if self.isReconnecting || self.channel == nil {
                if self.bufferedAudioBase64DuringReconnect.count
                    >= Self.maxBufferedAudioChunksDuringReconnect {
                    if !self.didLogReconnectBufferOverflow {
                        self.didLogReconnectBufferOverflow = true
                        ScribeStreamingTranscriptionProvider.appendSessionDiag(
                            "RECONNECT buffer full at "
                            + "\(Self.maxBufferedAudioChunksDuringReconnect) chunks — dropping audio"
                        )
                    }
                    return .drop
                }
                self.bufferedAudioBase64DuringReconnect.append(base64)
                return .buffer
            }
            // Live: keep a short timestamped tail so the seconds already
            // fired at a socket that turns out to be dead can be replayed.
            self.preStallAudioRing.append((base64: base64, capturedAt: Date()))
            if self.preStallAudioRing.count > Self.preStallRingBufferChunks {
                self.preStallAudioRing.removeFirst(
                    self.preStallAudioRing.count - Self.preStallRingBufferChunks
                )
            }
            return .send
        }

        guard route == .send else { return }
        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "sample_rate": 16000,
        ])
    }

    func requestFinalTranscript() {
        let deferCommit: Bool = stateQueue.sync {
            guard !self.hasDeliveredFinalTranscript else { return false }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
            // v16r23: released the key mid-rebuild. Firing the commit now
            // would send it at a nil socket, the server would never commit,
            // the 1.4s deadline would fire, and the tail of the dictation
            // would be lost — the original bug, reproduced by its own fix.
            // Latch it; reopenSocket re-issues it.
            if self.isReconnecting || self.channel == nil {
                self.pendingCommitAfterReconnect = true
                return true
            }
            return false
        }
        guard !deferCommit else {
            ScribeStreamingTranscriptionProvider.appendSessionDiag(
                "COMMIT deferred — reconnect in flight at key release"
            )
            return
        }
        requestFinalTranscriptFrame()
    }

    /// Force a commit of the current buffer (manual commit strategy). The
    /// server answers with a committed_transcript for the segment.
    private func requestFinalTranscriptFrame() {
        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": 16000,
        ])
    }

    func cancel() {
        // v16r23: retire the socket identity as part of going terminal, so
        // a reconnect already in flight sees isTerminated in reopenSocket
        // and refuses to install — a finished session can't be resurrected
        // by its own recovery.
        let doomed: ScribeWebSocketChannel? = stateQueue.sync {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
            self.hasFailedOrTerminated = true
            self.socketGeneration += 1
            self.bufferedAudioBase64DuringReconnect = []
            self.preStallAudioRing = []
            let channel = self.channel
            self.channel = nil
            return channel
        }
        doomed?.cancelGoingAway()
    }

    /// v16r23: reads are bound to the socket that issued them. A completion
    /// from a retired generation is a straggler from a socket we already
    /// cancelled — acting on it would tear down its own replacement.
    private func receiveNextMessage(on channel: ScribeWebSocketChannel, generation: Int) {
        channel.receive { [weak self] result in
            guard let self else { return }
            let isCurrent: Bool = self.stateQueue.sync {
                generation == self.socketGeneration && !self.isTerminated
            }
            guard isCurrent else { return }

            switch result {
            case .success(let frame):
                switch frame {
                case .text(let text):
                    self.handleIncomingTextMessage(text)
                case .binary(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                case .unsupported:
                    break
                }
                self.receiveNextMessage(on: channel, generation: generation)
            case .failure(let error):
                // THE CUTOFF. Before v16r23 this was `failSession(with:)`
                // and the loop simply stopped — the socket died, the user
                // kept talking, and every subsequent word was discarded.
                self.handleTransportFailure(error, generation: generation)
            }
        }
    }

    // MARK: - Reconnect

    /// Decide whether a transport fault is worth rebuilding the socket for.
    ///
    /// An account-level refusal (quota exhausted, auth revoked) must NEVER
    /// reconnect: retrying cannot help, and retrying FAST is exactly how
    /// v16r19 turned the 2026-08-06 ElevenLabs outage into an instant
    /// session kill. Those route to failSession, which hands off to the
    /// engine-fallback path built in v16r20.
    private func handleTransportFailure(_ error: Error, generation: Int) {
        if let fatal = error as? BuddyProviderFatalError, fatal.isProviderFatal {
            ScribeStreamingTranscriptionProvider.appendSessionDiag(
                "FATAL (no reconnect) — \(fatal.providerFatalReason)"
            )
            failSession(with: error)
            return
        }

        let shouldReconnect: Bool = stateQueue.sync {
            guard generation == self.socketGeneration, !self.isTerminated else { return false }
            return true
        }
        guard shouldReconnect else { return }

        ScribeStreamingTranscriptionProvider.appendSessionDiag(
            "TRANSPORT FAILURE gen=\(generation) — \(error.localizedDescription). Reconnecting."
        )
        print("[Scribe] ⚠️ Transport failure — rebuilding socket: \(error.localizedDescription)")
        beginReconnect()
    }

    private func beginReconnect() {
        let proceed: Bool = stateQueue.sync {
            guard !self.isReconnecting, !self.isTerminated else { return false }
            guard self.reconnectAttempts < Self.maxReconnectAttempts else { return false }

            self.isReconnecting = true
            self.reconnectAttempts += 1
            self.totalReconnectCount += 1

            // Freeze the in-flight partial into the committed list before
            // the replacement starts emitting its own partials — otherwise
            // the new session's first partial overwrites it and we lose the
            // words spoken immediately before the failure.
            let trimmedPartial = self.activePartialTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPartial.isEmpty {
                self.finalizedSegments.append(trimmedPartial)
                self.activePartialTranscript = ""
            }

            // Retire the old socket. Bump the generation FIRST so its
            // pending read and in-flight sends are recognised as stragglers
            // rather than mistaken for a fresh fault on the new socket.
            self.socketGeneration += 1
            let dead = self.channel
            self.channel = nil
            dead?.cancelGoingAway()
            return true
        }

        guard proceed else {
            let exhausted: Bool = stateQueue.sync {
                self.reconnectAttempts >= Self.maxReconnectAttempts && !self.isTerminated
            }
            if exhausted {
                ScribeStreamingTranscriptionProvider.appendSessionDiag(
                    "RECONNECT giving up after \(Self.maxReconnectAttempts) attempts"
                )
                failSession(with: ScribeStreamingTranscriptionProviderError(
                    message: "Transcription connection was lost and could not be re-established."
                ))
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let freshToken = try await self.tokenProvider()
                try await self.reopenSocket(token: freshToken)
            } catch {
                ScribeStreamingTranscriptionProvider.appendSessionDiag(
                    "RECONNECT failed: \(error.localizedDescription)"
                )
                print("[Scribe] ❌ Reconnect failed: \(error.localizedDescription)")
                let giveUp: Bool = self.stateQueue.sync {
                    guard !self.isTerminated else { return false }
                    self.isReconnecting = false
                    return self.reconnectAttempts >= Self.maxReconnectAttempts
                }
                if giveUp {
                    self.failSession(with: error)
                } else {
                    // Budget left — try again immediately. Audio stays
                    // buffered in the meantime rather than being fired at
                    // a nil socket and silently dropped.
                    self.beginReconnect()
                }
            }
        }
    }

    /// Build a replacement socket and replay the audio spanning the gap.
    /// Does NOT touch readyContinuation — that belongs to the original
    /// open() and resolved long ago.
    private func reopenSocket(token freshToken: String) async throws {
        let websocketURL = try Self.makeWebsocketURL(token: freshToken, keyterms: keyterms)
        let replacement = makeChannel(websocketURL)

        // The token fetch above is a network round-trip. The user may have
        // released the key in that window, so the session can already be
        // over. Install only if it's still live — otherwise this socket is
        // owned by nothing, never cancelled, and fires transcripts into a
        // finished session.
        let generation: Int? = stateQueue.sync {
            guard !self.isTerminated else { return nil }
            self.socketGeneration += 1
            self.channel = replacement
            return self.socketGeneration
        }
        guard let generation else {
            replacement.cancelGoingAway()
            ScribeStreamingTranscriptionProvider.appendSessionDiag(
                "RECONNECT abandoned — session ended during token fetch"
            )
            return
        }

        replacement.resume()
        receiveNextMessage(on: replacement, generation: generation)

        // Replay = the pre-failure ring (speech already fired at the dead
        // socket) + everything buffered while we were down. Drain BEFORE
        // clearing isReconnecting, or a live buffer races ahead of the
        // replay and the server hears newer audio before older audio.
        let replayed: [String] = stateQueue.sync {
            // Only entries newer than the last frame the server actually
            // acknowledged — anything older it already transcribed, and
            // re-sending duplicates words in the output.
            let watermark = self.lastTranscriptMessageAt
            let ring = self.preStallAudioRing
                .filter { $0.capturedAt >= watermark }
                .map(\.base64)
            self.preStallAudioRing = []
            self.lastTranscriptMessageAt = Date()
            let all = ring + self.bufferedAudioBase64DuringReconnect
            self.bufferedAudioBase64DuringReconnect = []
            return all
        }

        for chunk in replayed {
            sendJSONMessage([
                "message_type": "input_audio_chunk",
                "audio_base_64": chunk,
                "sample_rate": 16000,
            ])
        }

        // Anything captured DURING the replay loop is still classified as
        // buffered. Drain it in the SAME critical section that clears the
        // flag, or those chunks are stranded.
        let (shouldReissueCommit, segmentCount, tailCount): (Bool, Int, Int) = stateQueue.sync {
            let tail = self.bufferedAudioBase64DuringReconnect
            self.bufferedAudioBase64DuringReconnect = []
            for chunk in tail {
                self.sendJSONMessage([
                    "message_type": "input_audio_chunk",
                    "audio_base_64": chunk,
                    "sample_rate": 16000,
                ])
            }
            self.isReconnecting = false
            self.didLogReconnectBufferOverflow = false
            let reissue = self.pendingCommitAfterReconnect
            self.pendingCommitAfterReconnect = false
            return (reissue, self.finalizedSegments.count, tail.count)
        }

        if shouldReissueCommit {
            ScribeStreamingTranscriptionProvider.appendSessionDiag(
                "RECONNECT re-issuing dropped commit frame"
            )
            requestFinalTranscriptFrame()
        }

        ScribeStreamingTranscriptionProvider.appendSessionDiag(
            "RECONNECT ok (gen \(generation)) — replayed \(replayed.count + tailCount) chunks, "
            + "preserved \(segmentCount) committed segments"
        )
        print("[Scribe] ✅ Reconnected — replayed \(replayed.count + tailCount) audio chunks")
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
                // v16r20 (2026-08-06): classify explicitly instead of
                // sniffing for the substring "error". `quota_exceeded`
                // doesn't contain it, so the old heuristic dropped a
                // hard account failure into the no-op branch below and
                // the user got a live indicator with no transcript and
                // no explanation. See BuddyProviderFatalError.
                if let fatal = ScribeFatalMessageClassifier.classify(text) {
                    ScribeStreamingTranscriptionProvider.appendSessionDiag(
                        "FATAL server message type=\(envelope.message_type) "
                        + "accountFatal=\(fatal.isAccountFatal) reason=\(fatal.reason)"
                    )
                    print("[Scribe] ❌ Server refused the session (\(envelope.message_type)): \(fatal.reason)")
                    failSession(with: ScribeStreamingTranscriptionProviderError(
                        message: fatal.reason,
                        isAccountFatal: fatal.isAccountFatal
                    ))
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
            // v16r23: the server is talking to us, so this socket works.
            // Doubles as the replay watermark — audio older than this was
            // already transcribed and must not be re-sent.
            self.lastTranscriptMessageAt = Date()
            if isFinal {
                // Budget is earned back only by a COMMITTED transcript, not
                // by a partial. A socket that reconnects and then produces
                // nothing usable shouldn't get an unlimited retry supply.
                if self.reconnectAttempts > 0 {
                    ScribeStreamingTranscriptionProvider.appendSessionDiag(
                        "RECONNECT budget restored after committed transcript "
                        + "(total reconnects this session: \(self.totalReconnectCount))"
                    )
                }
                self.reconnectAttempts = 0
                if !transcriptText.isEmpty {
                    self.finalizedSegments.append(transcriptText)
                }
                // v16r31: one line per commit so a session's shape is
                // reconstructible (how many segments, how long each).
                ScribeStreamingTranscriptionProvider.appendSessionDiag(
                    "COMMIT seg#\(self.finalizedSegments.count) len=\(transcriptText.count) "
                    + "partialWasLen=\(self.activePartialTranscript.count) reconnects=\(self.totalReconnectCount)"
                )
                self.activePartialTranscript = ""
            } else {
                // v16r31 (2026-09-03): drop-fingerprint log. Steph reports
                // toggle dictations losing a middle chunk, worse after a
                // long pause. Under manual commit nothing is finalized
                // until key-release, so if the server ever RESTARTS its
                // partial (new text that doesn't continue the old one, or
                // is much shorter), the replaced partial is gone for good.
                // Log exactly that shape so the claim can be settled from
                // /tmp/clicky_scribe_session.log instead of memory.
                let previous = self.activePartialTranscript
                if previous.count >= 20 {
                    let prefix = String(previous.prefix(15))
                    let shrank = transcriptText.count < Int(Double(previous.count) * 0.6)
                    let restarted = !transcriptText.hasPrefix(prefix)
                    if shrank || restarted {
                        ScribeStreamingTranscriptionProvider.appendSessionDiag(
                            "PARTIAL-\(shrank ? "SHRINK" : "RESTART") prevLen=\(previous.count) newLen=\(transcriptText.count) "
                            + "committedSegs=\(self.finalizedSegments.count) reconnects=\(self.totalReconnectCount) "
                            + "PREV=\"\(previous.suffix(60))\" NEW=\"\(transcriptText.prefix(60))\""
                        )
                    }
                }
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
        channel?.cancelGoingAway()
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        sendQueue.async { [weak self] in
            guard let self else { return }
            // v16r23: capture the socket AND its generation together, so a
            // completion arriving after that socket was retired is ignored
            // rather than tearing down its replacement.
            let snapshot: (channel: ScribeWebSocketChannel, generation: Int)? = self.stateQueue.sync {
                guard let channel = self.channel, !self.isTerminated else { return nil }
                return (channel, self.socketGeneration)
            }
            guard let snapshot else { return }
            snapshot.channel.send(text: jsonString) { [weak self] error in
                guard let self, let error else { return }
                // A write failure means this socket is gone. Recover it the
                // same way a read failure is recovered — the old behavior
                // (straight to failSession) is what made a single dropped
                // write end the whole dictation.
                self.handleTransportFailure(error, generation: snapshot.generation)
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            // v16r23: idempotent. Without this guard one fault became one
            // onError per audio buffer — a fault storm at 50/second.
            guard !self.hasFailedOrTerminated else { return }
            self.hasFailedOrTerminated = true
            self.channel = nil
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

    /// v16r30 (2026-09-03): Scribe v2 Realtime `keyterms` — max 50 terms,
    /// each ≤20 chars, +20% on Scribe's per-minute rate (~$0.0047 →
    /// ~$0.0056/min). Wired after the 2026-09-03 Scribe-vs-Parakeet
    /// bake-off: Scribe missed "Siren's Cove"→"Simon's Cove", "Nerisa"→
    /// "Nerissa", "Love in Bloom"→"Love & Bloom" with no keyterms. The
    /// shared list arrives priority-ordered (override + collections first,
    /// hardcoded tool names last) so truncation drops the terms Scribe
    /// already gets right natively. Over-length terms are skipped, not
    /// clipped — a clipped term would bias toward a misspelling.
    static let scribeKeytermLimit = 50
    static let scribeKeytermMaxChars = 20

    static func scribeKeyterms(from keyterms: [String]) -> [String] {
        var out: [String] = []
        for term in keyterms where term.count <= scribeKeytermMaxChars {
            out.append(term)
            if out.count == scribeKeytermLimit { break }
        }
        return out
    }

    private static func makeWebsocketURL(token: String, keyterms: [String]) throws -> URL {
        guard var components = URLComponents(string: websocketBaseURLString) else {
            throw ScribeStreamingTranscriptionProviderError(message: "Scribe websocket URL is invalid.")
        }
        var items = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "include_timestamps", value: "false"),
        ]
        let selected = scribeKeyterms(from: keyterms)
        for term in selected {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        if !selected.isEmpty {
            ScribeStreamingTranscriptionProvider.appendSessionDiag("keyterms: sent \(selected.count) of \(keyterms.count) (cap \(scribeKeytermLimit), ≤\(scribeKeytermMaxChars) chars)")
        }
        components.queryItems = items
        guard let url = components.url else {
            throw ScribeStreamingTranscriptionProviderError(message: "Scribe websocket URL could not be created.")
        }
        return url
    }
}
