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
            // v16r19 (2026-08-06): the mid-session stall watchdog needs to
            // rebuild the socket, and Scribe tokens are SINGLE-USE — the
            // one above is spent on the first connect. Hand the session a
            // way to mint a fresh one so it can reconnect on its own.
            tokenProvider: { [weak self] in
                guard let self else {
                    throw ScribeStreamingTranscriptionProviderError(
                        message: "Provider deallocated — cannot refresh token"
                    )
                }
                return try await self.fetchSingleUseToken()
            },
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
        // v16r19: bounded. This is on the mid-dictation reconnect path, and
        // the default 60s meant a slow proxy froze the session for a minute
        // per attempt — buffering audio it would then overflow and silently
        // drop. Indistinguishable from the stall we're trying to fix.
        request.timeoutInterval = 4

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
    /// A ready-result that arrived before `open()` installed its
    /// continuation. Parked here so it isn't lost — dropping it hung the
    /// caller forever.
    private var pendingReadyResult: Result<Void, Error>?
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false

    /// Committed (final) transcript segments in arrival order.
    private var finalizedSegments: [String] = []
    /// Most recent partial transcript; replaced on each partial, cleared on commit.
    private var activePartialTranscript: String = ""

    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?
    private var hasFailedOrTerminated = false

    // MARK: - Stall watchdog + reconnect (v16r19, 2026-08-06)
    //
    // Symptom: in TOGGLE mode, transcription stops partway through and
    // records nothing from that point on. Diagnosed 2026-08-06 — it also
    // caused the trailing-leak incident the same day (a session cut at
    // "...no way to scale it? Because-", and the polish model then
    // commented on the fragment it was handed).
    //
    // Three gaps made it both possible and invisible:
    //   1. `hasFailedOrTerminated` was WRITE-ONLY — set in two places,
    //      read in none. Once a session died, nothing knew.
    //   2. `appendAudioBuffer` had no dead-session guard, so audio kept
    //      being pumped into a dead socket, each send failing and
    //      re-entering failSession.
    //   3. No stall detection, keepalive, or reconnect anywhere in ANY
    //      VTT provider. The receive loop took one `.failure` and stopped
    //      reading forever.
    //
    // Why toggle only: hold sessions run 5-15s and rarely live long
    // enough for a long-lived WSS to half-die. Toggle sessions run 45-90s+.
    //
    // Approach: a stall is a stall regardless of cause (socket half-close,
    // server going quiet, token/session expiry), so recover structurally
    // rather than special-casing triggers. If we're hearing voice RIGHT NOW
    // but the server hasn't said anything for a while, rebuild the socket,
    // preserve everything already committed, and replay the audio captured
    // during the gap.

    /// Server silence tolerated while the user is actively speaking before
    /// we call the session stalled. Scribe streams partials roughly every
    /// 0.5-1s during speech, so 5s of nothing mid-sentence is decisive
    /// without being trigger-happy about transient slowness.
    private static let stallThresholdSeconds: TimeInterval = 5.0
    /// How recently voiced audio must have been seen for silence from the
    /// server to count as a stall. Without this, a long thinking pause —
    /// during which Scribe correctly sends nothing — would false-positive.
    private static let voicedAudioRecencySeconds: TimeInterval = 1.0
    /// Voiced detection is ADAPTIVE, not a fixed cutoff. Measured from
    /// 1,057 real capture buffers in /tmp/clicky_audio_diag.log: median
    /// RMS 0.00049, p95 0.0026, peak 0.388. So the noise floor here is
    /// ~-66 dBFS — three decades below a "safe-looking" fixed 0.04, which
    /// would have left the watchdog permanently inert, and above a
    /// fixed 0.01 only on loud syllables. Any constant is wrong on some
    /// mic: this is the single point of failure for the whole feature, so
    /// it tracks the observed floor instead of guessing.
    ///
    /// Voiced := RMS > max(absoluteFloor, observedNoiseFloor x margin).
    private static let voicedMarginOverNoiseFloor: Float = 8.0
    private static let voicedAbsoluteFloor: Float = 0.002
    /// Seed until the session has heard enough to estimate its own floor.
    private static let initialNoiseFloorEstimate: Float = 0.0005
    /// Consecutive voiced buffers required before we believe someone is
    /// actually talking — guards against a transient knock or key click
    /// holding `lastVoicedAudioAt` fresh through a silent pause.
    private static let voicedBufferStreakRequired = 3
    private static let watchdogTickSeconds: TimeInterval = 1.0
    /// Give up after this many rebuilds so a genuinely dead network
    /// surfaces an error instead of looping.
    private static let maxReconnectAttempts = 3
    /// ~20s of 16kHz mono PCM16 at the buffer sizes we send. Bounded so a
    /// long reconnect can't grow memory without limit.
    private static let maxBufferedAudioChunksDuringReconnect = 400

    /// ~6s of audio at the observed ~50ms/chunk cadence. The watchdog can
    /// only notice a stall `stallThresholdSeconds` AFTER the server went
    /// quiet, and that speech was sent to an already-dead socket — neither
    /// transcribed nor buffered. Without this, every "successful" recovery
    /// still left a 5-second hole mid-sentence: the same truncation
    /// symptom, just shorter. Always-on rolling capture closes the gap.
    private static let preStallRingBufferChunks = 120

    private let tokenProvider: () async throws -> String
    private var lastServerMessageAt = Date()
    private var lastVoicedAudioAt: Date?
    private var consecutiveVoicedBuffers = 0
    private var noiseFloorEstimate: Float = ScribeStreamingTranscriptionSession.initialNoiseFloorEstimate
    private var preStallAudioRing: [(base64: String, capturedAt: Date)] = []
    private var didLogReconnectBufferOverflow = false
    /// Set ONLY by partial/committed transcript frames. The watchdog must
    /// measure transcript silence, not socket silence: `session_started`,
    /// keepalives and other informational frames prove the socket is up but
    /// say nothing about whether transcription is still happening — and a
    /// half-alive server that keeps the socket warm while producing no text
    /// is exactly the failure this feature exists to catch.
    private var lastTranscriptMessageAt = Date()
    /// Rolling voiced-detection stats, emitted once per watchdog tick, so
    /// the arming threshold can be validated against real capture instead
    /// of trusted on faith. This detector is the single point of failure
    /// for the whole feature; if it never arms, the watchdog is inert and
    /// the bug looks unfixed.
    private var diagBufferCount = 0
    private var diagVoicedCount = 0
    private var diagPeakRMS: Float = 0
    /// Set when a `commit=true` finalize frame is dropped because the
    /// socket was mid-rebuild; re-issued once the new socket is up.
    private var pendingCommitAfterReconnect = false
    private var totalReconnectCount = 0
    private var stallWatchdogTimer: DispatchSourceTimer?
    private var isReconnecting = false
    private var reconnectAttempts = 0
    private var bufferedAudioBase64DuringReconnect: [String] = []
    private var didReconnectThisSession = false
    /// A reconnect attempt failed (usually the token fetch). We stay in the
    /// reconnecting state so audio keeps buffering, and the watchdog picks
    /// this up on its next tick to try again.
    private var pendingReconnectRetryAfterFailure = false

    /// Monotonic id for the CURRENT socket. Every receive/send completion
    /// captures the generation it was armed under and compares before
    /// acting.
    ///
    /// This is load-bearing. Tearing down a stalled socket completes its
    /// pending `receive` with a cancellation failure, and there are always
    /// in-flight sends. Without an identity check those stragglers are
    /// indistinguishable from a fresh failure, so the old socket's dying
    /// callbacks tear down the replacement that was just built for them —
    /// turning every stall recovery into a session kill.
    ///
    /// Bumped on every socket swap AND on every terminal transition, so a
    /// reconnect in flight when the user releases the key is orphaned
    /// rather than resurrecting a finished session.
    private var socketGeneration = 0

    /// Single source of truth for "this session is over". Checked before
    /// installing a socket, before surfacing transcripts, and before
    /// arming another reconnect.
    private var isTerminated: Bool {
        hasFailedOrTerminated || hasDeliveredFinalTranscript
    }

    init(
        token: String,
        tokenFetchMs: Int,
        urlSession: URLSession,
        keyterms: [String],
        tokenProvider: @escaping () async throws -> String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.token = token
        self.tokenProvider = tokenProvider
        self.tokenFetchMs = tokenFetchMs
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    deinit {
        // Safety net: stopStallWatchdog is otherwise only reachable via
        // cancel / final delivery / failSession. A session released without
        // any of those would leave a resumed DispatchSourceTimer that
        // libdispatch retains and fires forever.
        stallWatchdogTimer?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(token: token)
        let websocketRequest = URLRequest(url: websocketURL)
        // Auth is carried in the `token` query param — no header needed.

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        let generation: Int = stateQueue.sync {
            self.socketGeneration += 1
            self.webSocketTask = webSocketTask
            return self.socketGeneration
        }
        webSocketTask.resume()

        receiveNextMessage(on: webSocketTask, generation: generation)

        // Resolve readiness as soon as the WSS handshake completes
        // (resume() returns), mirroring the proven Deepgram flow — the
        // server buffers early audio chunks and emits `session_started`
        // shortly after. If auth/params are bad, the receive loop fails
        // and surfaces onError, aborting the engage.
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
                // A failure that landed before this block ran parked its
                // result rather than dropping it on the floor — honour that
                // instead of reporting a success that never happened.
                let result = self.pendingReadyResult ?? .success(())
                self.pendingReadyResult = nil
                self.resolveReadyContinuationIfNeeded(with: result)
            }
        }

        stateQueue.async {
            self.lastServerMessageAt = Date()
        }
        startStallWatchdog()
    }

    // MARK: - Stall watchdog

    private func startStallWatchdog() {
        stateQueue.async {
            self.stallWatchdogTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
            timer.schedule(
                deadline: .now() + Self.watchdogTickSeconds,
                repeating: Self.watchdogTickSeconds
            )
            timer.setEventHandler { [weak self] in
                self?.checkForStall()
            }
            self.stallWatchdogTimer = timer
            timer.resume()
        }
    }

    private func stopStallWatchdog() {
        stallWatchdogTimer?.cancel()
        stallWatchdogTimer = nil
    }

    /// Runs on stateQueue.
    private func checkForStall() {
        guard !isTerminated else { return }
        // Stand down once the user has released the key. The commit frame
        // is already in flight and the 1.4s deadline owns the outcome —
        // rebuilding the socket here would burn a single-use token and
        // throw away the real committed_transcript for a partial fallback.
        guard !isAwaitingExplicitFinalTranscript else { return }

        // A previous attempt failed mid-flight (usually the token fetch).
        // We stayed in the reconnecting state to keep buffering audio;
        // now take another swing.
        if pendingReconnectRetryAfterFailure {
            pendingReconnectRetryAfterFailure = false
            isReconnecting = false
            Self.appendSessionDiag("RECONNECT retrying after earlier failure")
            beginReconnect()
            return
        }

        guard !isReconnecting else { return }

        // Emit voiced-detection stats every tick. Without this there is no
        // way to tell an inert detector (never arms -> watchdog silently
        // does nothing -> bug looks unfixed) from a healthy session that
        // simply never stalled.
        if diagBufferCount > 0 {
            Self.appendSessionDiag(
                "VOICED tick — buffers=\(diagBufferCount) voiced=\(diagVoicedCount) "
                + "peakRMS=\(String(format: "%.5f", diagPeakRMS)) "
                + "noiseFloor=\(String(format: "%.5f", noiseFloorEstimate)) "
                + "threshold=\(String(format: "%.5f", max(Self.voicedAbsoluteFloor, noiseFloorEstimate * Self.voicedMarginOverNoiseFloor))) "
                + "armed=\(lastVoicedAudioAt != nil) "
                + "transcriptSilence=\(String(format: "%.1f", Date().timeIntervalSince(lastTranscriptMessageAt)))s"
            )
            diagBufferCount = 0
            diagVoicedCount = 0
            diagPeakRMS = 0
        }

        // Only meaningful once the session has actually started producing —
        // cold start legitimately takes ~2.2s to first partial.
        guard let lastVoicedAudioAt else { return }

        let now = Date()
        // Transcript silence, NOT socket silence. session_started and any
        // keepalive/informational frame prove the socket is up while saying
        // nothing about whether transcription is still happening — and a
        // half-alive server is the failure mode we're hunting.
        let serverSilence = now.timeIntervalSince(lastTranscriptMessageAt)
        let voiceRecency = now.timeIntervalSince(lastVoicedAudioAt)

        // Speaking right now, but the server has gone quiet — that's a stall.
        // A quiet server during a genuine pause is normal and ignored.
        guard serverSilence > Self.stallThresholdSeconds,
              voiceRecency < Self.voicedAudioRecencySeconds else { return }

        Self.appendSessionDiag(
            "STALL detected — serverSilence=\(String(format: "%.1f", serverSilence))s "
            + "voiceRecency=\(String(format: "%.1f", voiceRecency))s "
            + "committedSegments=\(finalizedSegments.count) "
            + "attempt=\(reconnectAttempts + 1)/\(Self.maxReconnectAttempts)"
        )
        print("[Scribe] ⚠️ Stall detected (\(String(format: "%.1f", serverSilence))s of server silence while speaking) — rebuilding socket")
        beginReconnect()
    }

    /// Runs on stateQueue.
    private func beginReconnect() {
        guard !isReconnecting, !hasFailedOrTerminated, !hasDeliveredFinalTranscript else { return }

        guard reconnectAttempts < Self.maxReconnectAttempts else {
            Self.appendSessionDiag("RECONNECT giving up after \(reconnectAttempts) attempts")
            let error = ScribeStreamingTranscriptionProviderError(
                message: "Transcription stalled and could not reconnect."
            )
            // Route through failSession so an in-flight finalize still
            // delivers whatever we captured rather than losing it.
            failSession(with: error)
            return
        }

        isReconnecting = true
        reconnectAttempts += 1
        totalReconnectCount += 1
        didReconnectThisSession = true

        // Freeze the in-flight partial into the committed list before the
        // new socket starts emitting its own partials — otherwise the fresh
        // session's first partial would overwrite it and we'd lose the
        // words spoken just before the stall.
        let trimmedPartial = activePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPartial.isEmpty {
            finalizedSegments.append(trimmedPartial)
            activePartialTranscript = ""
        }

        // Retire the old socket. Bumping the generation FIRST invalidates
        // its pending receive and every in-flight send, so the cancellation
        // failures they're about to produce are recognised as stragglers
        // instead of being mistaken for a fresh fault in the new socket.
        socketGeneration += 1
        let deadTask = webSocketTask
        webSocketTask = nil
        deadTask?.cancel(with: .goingAway, reason: nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let freshToken = try await self.tokenProvider()
                try await self.reopenSocket(token: freshToken)
            } catch {
                Self.appendSessionDiag("RECONNECT failed: \(error.localizedDescription)")
                print("[Scribe] ❌ Reconnect failed: \(error.localizedDescription)")
                self.stateQueue.async {
                    guard !self.isTerminated else { return }
                    // Stay in the reconnecting state so audio keeps being
                    // BUFFERED rather than fired at a nil socket and
                    // silently dropped. The watchdog retries on its next
                    // tick; give up only once the budget is spent.
                    if self.reconnectAttempts >= Self.maxReconnectAttempts {
                        self.isReconnecting = false
                        self.failSession(with: error)
                    } else {
                        self.pendingReconnectRetryAfterFailure = true
                    }
                }
            }
        }
    }

    /// Build a replacement socket and replay the audio captured while we
    /// were down. Does NOT touch readyContinuation — that belongs to the
    /// initial open() and is long since resolved.
    private func reopenSocket(token freshToken: String) async throws {
        let websocketURL = try Self.makeWebsocketURL(token: freshToken)
        let task = urlSession.webSocketTask(with: URLRequest(url: websocketURL))

        // The token fetch above is a network round-trip (~100-300ms). The
        // user may have released the key in that window, so the session can
        // already be over. Install only if it's still live — otherwise this
        // socket would be owned by nothing, never cancelled, and its
        // transcripts would fire callbacks into a finished session.
        let generation: Int? = stateQueue.sync {
            guard !self.isTerminated else { return nil }
            self.socketGeneration += 1
            self.webSocketTask = task
            return self.socketGeneration
        }
        guard let generation else {
            task.cancel(with: .goingAway, reason: nil)
            Self.appendSessionDiag("RECONNECT abandoned — session ended during token fetch")
            return
        }

        task.resume()
        receiveNextMessage(on: task, generation: generation)

        // Drain and send the gap audio BEFORE clearing isReconnecting.
        // Clearing first would let a live buffer race ahead of the replay
        // on sendQueue, so the server would receive newer audio before
        // older audio and garble the seam.
        // Replay = the pre-stall ring (speech sent to the dead socket in the
        // seconds BEFORE detection) + everything buffered during the gap.
        let replayed: [String] = stateQueue.sync {
            // Replay only the ring entries captured AFTER the last frame the
            // server actually acknowledged — anything older it already
            // transcribed, and re-sending it duplicates words in the output.
            let unacknowledgedSince = self.lastTranscriptMessageAt
            let recoveredRing = self.preStallAudioRing
                .filter { $0.capturedAt >= unacknowledgedSince }
                .map(\.base64)
            self.lastServerMessageAt = Date()
            self.lastTranscriptMessageAt = Date()
            self.preStallAudioRing = []
            let recovered = recoveredRing + self.bufferedAudioBase64DuringReconnect
            self.bufferedAudioBase64DuringReconnect = []
            return recovered
        }

        for chunk in replayed {
            sendJSONMessage([
                "message_type": "input_audio_chunk",
                "audio_base_64": chunk,
                "sample_rate": 16000,
            ])
        }

        // Anything captured DURING the replay loop is still classified
        // .buffered (isReconnecting is still true). Drain it in the same
        // critical section that clears the flag, or those chunks are
        // stranded — never replayed, and liable to be injected out of order
        // into a much later reconnect.
        // Enqueue the tail from INSIDE the critical section, before
        // isReconnecting is cleared. Sending it after the section released
        // reopened the same ordering hole the first drain closed: a live
        // buffer acquiring stateQueue in between would see .send and jump
        // the queue ahead of older audio.
        let (shouldReissueCommit, segmentCount, tailCount): (Bool, Int, Int) = stateQueue.sync {
            let tail = self.bufferedAudioBase64DuringReconnect
            self.bufferedAudioBase64DuringReconnect = []
            for chunk in tail {
                self.enqueueAudioChunkForSend(chunk)
            }
            self.isReconnecting = false
            self.pendingReconnectRetryAfterFailure = false
            self.didLogReconnectBufferOverflow = false
            let reissue = self.pendingCommitAfterReconnect
            self.pendingCommitAfterReconnect = false
            return (reissue, self.finalizedSegments.count, tail.count)
        }

        // The user released the key while we were rebuilding, so the
        // finalize frame hit a nil socket and was dropped. Without this the
        // server never commits, the 1.4s deadline fires, and the tail of the
        // dictation is lost — the original symptom, reproduced by the fix.
        if shouldReissueCommit {
            Self.appendSessionDiag("RECONNECT re-issuing dropped commit frame")
            sendJSONMessage([
                "message_type": "input_audio_chunk",
                "audio_base_64": "",
                "commit": true,
                "sample_rate": 16000,
            ])
        }

        Self.appendSessionDiag(
            "RECONNECT ok (gen \(generation)) — replayed \(replayed.count + tailCount) chunks, "
            + "preserved \(segmentCount) committed segments"
        )
        print("[Scribe] ✅ Reconnected — replayed \(replayed.count + tailCount) audio chunks")
    }

    /// Enqueue one audio chunk for transmission. Safe to call while holding
    /// stateQueue — the actual send hops to sendQueue.
    private func enqueueAudioChunkForSend(_ base64: String) {
        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "sample_rate": 16000,
        ])
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        // v16r19: dead-session guard. Previously absent — after a failure
        // this kept shovelling audio into a dead socket, and every send
        // error re-entered failSession.
        // Voiced-audio tracking feeds the stall watchdog: server silence
        // only counts as a stall while the user is actually speaking.
        let rms = Self.rootMeanSquare(ofPCM16: audioPCM16Data)
        let base64 = audioPCM16Data.base64EncodedString()
        if firstAudioSentMs == nil {
            firstAudioSentMs = Int(Date().timeIntervalSince(engageStartedAt) * 1000)
        }

        // ONE atomic hop onto stateQueue: classify and enqueue together.
        // Splitting them let a reconnect drain the buffer in between, which
        // orphaned the chunk — never replayed (the drain already happened)
        // and never sent. Silent audio loss at every reconnect seam.
        enum AudioDisposition { case send, buffered, dropped }
        let disposition: AudioDisposition = stateQueue.sync {
            // Adaptive noise floor. Both directions are EMAs — an
            // instantaneous snap-down would make this a running MINIMUM
            // (one digital-silence buffer pins it near zero forever), which
            // is not a floor estimate and would leave the absolute constant
            // permanently deciding the threshold.
            // Down fast (0.05) so it follows a quieting room; up very slowly
            // (0.0005, tau ~100s) so sustained speech can't drag the floor
            // up to meet itself and blind the detector.
            let adaptationRate: Float = rms < self.noiseFloorEstimate ? 0.05 : 0.0005
            self.noiseFloorEstimate += (rms - self.noiseFloorEstimate) * adaptationRate
            let voicedThreshold = max(
                Self.voicedAbsoluteFloor,
                self.noiseFloorEstimate * Self.voicedMarginOverNoiseFloor
            )

            self.diagBufferCount += 1
            self.diagPeakRMS = max(self.diagPeakRMS, rms)

            if rms > voicedThreshold {
                self.diagVoicedCount += 1
                // Clamp: an unbounded counter meant a long loud passage
                // left it in the hundreds, so a single stray knock a minute
                // later still satisfied the streak and refreshed
                // lastVoicedAudioAt — the exact false-positive the streak
                // exists to prevent.
                self.consecutiveVoicedBuffers = min(
                    self.consecutiveVoicedBuffers + 1,
                    Self.voicedBufferStreakRequired
                )
                if self.consecutiveVoicedBuffers >= Self.voicedBufferStreakRequired {
                    self.lastVoicedAudioAt = Date()
                }
            } else if self.consecutiveVoicedBuffers > 0 {
                // Decay rather than reset: inter-word gaps and stop
                // consonants dip below threshold constantly, and a hard
                // reset would stop the streak ever reaching 3 — leaving
                // lastVoicedAudioAt stale and the watchdog silently inert.
                self.consecutiveVoicedBuffers -= 1
            }

            // Dead-session guard. Previously absent — after a failure this
            // kept shovelling audio into a dead socket, and every send
            // error re-entered failSession.
            guard !self.isTerminated else { return .dropped }

            if self.isReconnecting {
                // Socket is being rebuilt — hold the audio so the words
                // spoken during the gap survive, then replay on reconnect.
                if self.bufferedAudioBase64DuringReconnect.count
                    < Self.maxBufferedAudioChunksDuringReconnect {
                    self.bufferedAudioBase64DuringReconnect.append(base64)
                } else if !self.didLogReconnectBufferOverflow {
                    self.didLogReconnectBufferOverflow = true
                    Self.appendSessionDiag(
                        "BUFFER overflow — reconnect gap exceeded "
                        + "\(Self.maxBufferedAudioChunksDuringReconnect) chunks; audio is being dropped"
                    )
                }
                return .buffered
            }

            // Rolling capture of audio we're about to SEND, timestamped.
            // Two things matter here:
            //  - It lives on the .send path only. Appending before the
            //    isReconnecting branch put every gap chunk in BOTH arrays,
            //    so the replay transmitted the gap twice, the second copy
            //    jumping backwards — duplicated, out-of-order speech on
            //    every single reconnect.
            //  - Entries carry a capture time so the replay can send only
            //    what the server had NOT already acknowledged, instead of
            //    re-sending seconds of already-transcribed speech.
            self.preStallAudioRing.append((base64, Date()))
            if self.preStallAudioRing.count > Self.preStallRingBufferChunks {
                self.preStallAudioRing.removeFirst(
                    self.preStallAudioRing.count - Self.preStallRingBufferChunks
                )
            }
            return .send
        }

        guard disposition == .send else { return }

        sendJSONMessage([
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "sample_rate": 16000,
        ])
    }

    /// RMS of little-endian PCM16 samples, normalized to 0...1.
    private static func rootMeanSquare(ofPCM16 data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumOfSquares: Double = 0
        // loadUnaligned, not bindMemory: Data gives no alignment guarantee,
        // and a misaligned Int16 bind is undefined behaviour.
        data.withUnsafeBytes { rawBuffer in
            for index in 0..<sampleCount {
                let sample = rawBuffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int16>.size,
                    as: Int16.self
                )
                let normalized = Double(Int16(littleEndian: sample)) / 32768.0
                sumOfSquares += normalized * normalized
            }
        }
        return Float((sumOfSquares / Double(sampleCount)).squareRoot())
    }

    func requestFinalTranscript() {
        let isMidReconnect: Bool = stateQueue.sync {
            guard !self.isTerminated else { return false }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
            if self.isReconnecting {
                // Socket is nil right now, so the commit below would be
                // dropped on the floor. Latch it for reopenSocket to send.
                self.pendingCommitAfterReconnect = true
                return true
            }
            return false
        }
        guard !isMidReconnect else { return }

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
            self.stopStallWatchdog()
            self.bufferedAudioBase64DuringReconnect = []
            // Cancel the socket from INSIDE stateQueue. Reading the field
            // from the caller's thread raced a reconnect that had already
            // nil'd it, so the cancel hit nothing and the rebuilt socket
            // leaked open. Bumping the generation also orphans any
            // reconnect still in flight.
            self.socketGeneration += 1
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
        }
    }

    /// Arms the read loop against a SPECIFIC socket. Taking the task as a
    /// parameter rather than re-reading `webSocketTask` matters: if another
    /// reconnect nils the field in between, the field read would be nil and
    /// the freshly-built socket would come up with no reader — permanently
    /// silent, which is the exact bug this feature exists to fix.
    private func receiveNextMessage(
        on task: URLSessionWebSocketTask,
        generation: Int
    ) {
        task.receive { [weak self] result in
            guard let self else { return }
            // Is this still the live socket? A retired socket's pending
            // read always completes (with a cancellation failure) after we
            // replace it; acting on that would tear down its replacement.
            let isCurrent: Bool = self.stateQueue.sync {
                generation == self.socketGeneration && !self.isTerminated
            }
            guard isCurrent else { return }

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
                self.receiveNextMessage(on: task, generation: generation)
            case .failure(let error):
                // v16r19: a read failure used to end the session outright —
                // one `.failure` and we stopped reading forever, which is
                // exactly the "cuts off from that point on" symptom. If the
                // session is still live, treat it as a stall and rebuild
                // instead of giving up.
                let shouldAttemptReconnect: Bool = self.stateQueue.sync {
                    !self.hasFailedOrTerminated
                        && !self.hasDeliveredFinalTranscript
                        && !self.isAwaitingExplicitFinalTranscript
                        && !self.isReconnecting
                        && self.reconnectAttempts < Self.maxReconnectAttempts
                }
                if shouldAttemptReconnect {
                    Self.appendSessionDiag(
                        "SOCKET read failure mid-session: \(error.localizedDescription) — reconnecting"
                    )
                    print("[Scribe] ⚠️ Socket read failed mid-session (\(error.localizedDescription)) — rebuilding")
                    self.stateQueue.async { self.beginReconnect() }
                } else {
                    self.failSession(with: error)
                }
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        // Any traffic from the server proves the socket is alive — this is
        // the signal the stall watchdog measures silence against.
        stateQueue.async {
            self.lastServerMessageAt = Date()
        }
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
            // A finished session must not keep mutating the caller's
            // transcript — that's a trailing-text leak of exactly the kind
            // the v16r18 guard exists to clean up after.
            guard !self.isTerminated else { return }

            // Proof that transcription — not merely the socket — is alive.
            self.lastTranscriptMessageAt = Date()

            if isFinal {
                if !transcriptText.isEmpty {
                    self.finalizedSegments.append(transcriptText)
                    // Reconnect budget is earned back only by a COMMITTED
                    // transcript — proof the new socket is actually doing
                    // useful work. Resetting on any frame (session_started
                    // arrives before the server goes quiet again) made the
                    // attempt cap unreachable and allowed an endless
                    // rebuild loop, minting a single-use token each time.
                    if self.reconnectAttempts > 0 && !self.isReconnecting {
                        self.reconnectAttempts = 0
                    }
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
        stopStallWatchdog()
        bufferedAudioBase64DuringReconnect = []
        preStallAudioRing = []
        if didReconnectThisSession {
            // totalReconnectCount, not reconnectAttempts — the latter is
            // reset to 0 by a healthy commit, so it would report 0.
            Self.appendSessionDiag(
                "DELIVERED after \(totalReconnectCount) reconnect(s) — "
                + "\(transcriptText.count) chars, \(finalizedSegments.count) segments"
            )
        }
        onFinalTranscriptReady(transcriptText)
        // Orphan any reconnect still in flight, then close.
        socketGeneration += 1
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        sendQueue.async { [weak self] in
            guard let self else { return }
            // Read task + generation together under stateQueue. The field
            // was previously read unsynchronized from three queues.
            let socket: (task: URLSessionWebSocketTask, generation: Int)? = self.stateQueue.sync {
                guard let task = self.webSocketTask, !self.isTerminated else { return nil }
                return (task, self.socketGeneration)
            }
            guard let socket else { return }

            socket.task.send(.string(jsonString)) { [weak self] error in
                guard let self, let error else { return }
                // A send failure on a socket we've already retired is
                // expected — every reconnect leaves in-flight sends behind.
                // Without the generation check those stragglers call
                // beginReconnect and immediately tear down the replacement
                // that was just built for them.
                let shouldRecover: Bool = self.stateQueue.sync {
                    guard socket.generation == self.socketGeneration else { return false }
                    return !self.isTerminated
                        && !self.isAwaitingExplicitFinalTranscript
                        && !self.isReconnecting
                        && self.reconnectAttempts < Self.maxReconnectAttempts
                }
                if shouldRecover {
                    Self.appendSessionDiag(
                        "SOCKET send failure: \(error.localizedDescription) — reconnecting"
                    )
                    self.stateQueue.async { self.beginReconnect() }
                }
                // Otherwise: a straggler from a retired socket, or the
                // session is already finishing. Nothing to do — tearing the
                // session down here is what made stall recovery fatal.
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            // Idempotent. Two callers could each pass their own pre-check
            // before either's async block ran, firing onError twice for one
            // engage.
            guard !self.isTerminated else { return }
            self.hasFailedOrTerminated = true
            self.stopStallWatchdog()
            self.bufferedAudioBase64DuringReconnect = []
            // Orphan any in-flight reconnect and close the socket, so a
            // failed session can't be resurrected by a token fetch that
            // was already in the air.
            self.socketGeneration += 1
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            let latestTranscriptText = self.bestAvailableTranscriptText()
            // Deliver whatever we captured regardless of whether the user
            // had started finalizing. Requiring isAwaitingExplicitFinalTranscript
            // meant a mid-speech failure (e.g. reconnect budget exhausted)
            // threw away every committed segment — and then, because
            // hasDeliveredFinalTranscript was still false, the key-release
            // deadline delivered it 1.4s AFTER onError anyway. Worst of both.
            if !self.hasDeliveredFinalTranscript && !latestTranscriptText.isEmpty {
                print("[Scribe] ⚠️ Session error, delivering captured transcript as fallback: \(error.localizedDescription)")
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
            // Only consume the resolution once a continuation actually
            // exists. open() arms the read loop BEFORE installing its
            // continuation, so an immediate failure in that window used to
            // flip this flag with a nil continuation — after which the
            // installing block guarded out and open() never returned.
            // startStreamingSession would hang forever with no error.
            guard let continuation = self.readyContinuation else {
                self.pendingReadyResult = result
                return
            }
            self.hasResolvedReadyContinuation = true
            self.readyContinuation = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
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

    /// v16r19: session-lifecycle diag. Scribe previously logged only
    /// timing, so a mid-session stall left no record at all — which is why
    /// the toggle cutoff went undiagnosed for so long. Stalls, socket
    /// failures, reconnects and post-reconnect deliveries all land here.
    ///
    /// Writes on its own queue: several call sites run on `stateQueue`,
    /// which `appendAudioBuffer` enters with `sync` on the audio thread.
    /// Doing file I/O inline would block audio capture for the duration
    /// of the write.
    private static let sessionDiagQueue = DispatchQueue(
        label: "com.learningbuddy.scribe.session-diag"
    )

    static func appendSessionDiag(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        sessionDiagQueue.async {
            let path = "/tmp/clicky_scribe_session.log"
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
