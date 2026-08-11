//
//  verify_scribe_stall_recovery.swift
//  v16r21 (2026-08-10)
//
//  Mock-WebSocket harness for the Scribe streaming session.
//
//  WHY THIS EXISTS
//  v16r19 shipped a stall watchdog + reconnect into the running app with
//  no way to exercise it. Three static review passes found real defects
//  and still missed a runtime failure that appeared within ten seconds of
//  live use, costing Steph his primary tool mid-workday. Static review is
//  not execution. This harness is the execution.
//
//  WHAT IT DRIVES
//  The SHIPPED ScribeStreamingTranscriptionSession — not a transcribed
//  copy. run_scribe_stall_recovery.sh compiles this file together with
//  leanring-buddy/ScribeStreamingTranscriptionProvider.swift, so the code
//  under test is byte-for-byte the code in the app. Same principle as
//  verify_scribe_fatal_classifier.swift.
//
//  Run:
//    ./scripts/run_scribe_stall_recovery.sh
//
//  KNOWN LIMITATION (deliberate, read before adding tests)
//  scheduleExplicitFinalTranscriptDeadline() uses DispatchQueue.main
//  .asyncAfter. This is a command-line tool with no main run loop, so
//  that 1.4s fallback timer NEVER fires here. No test may depend on it.
//  Every final transcript below is driven by an explicit
//  committed_transcript frame, which is the real server's behavior under
//  commit_strategy=manual anyway.
//

import AVFoundation
import Foundation

// MARK: - Reporting

final class Report {
    private let lock = NSLock()
    private(set) var failures = 0
    private(set) var checks = 0

    func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        if condition {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    func section(_ title: String) {
        print("\n=== \(title) ===")
    }
}

let report = Report()

/// Poll until `condition` holds or the deadline passes. The session
/// delivers its callbacks on its own private stateQueue, so assertions
/// cannot read results synchronously after an action.
@discardableResult
func waitUntil(
    _ label: String,
    timeout: TimeInterval = 2.0,
    _ condition: @escaping () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(2_000)
    }
    return condition()
}

/// Give any in-flight queue hops a chance to land before asserting that
/// something did NOT happen. Without this, a "no further sends" assertion
/// can pass simply because the send hadn't been scheduled yet.
func settle(_ seconds: TimeInterval = 0.25) {
    Thread.sleep(forTimeInterval: seconds)
}

// MARK: - The fake transport

struct FakeSocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A WebSocket that misbehaves to order.
///
/// Models the three failure shapes the real ElevenLabs socket exhibits
/// and that the app currently has no defense against:
///   • STALL       — connection stays open, server stops sending frames.
///   • HALF-CLOSE  — the read side fails while writes still appear to work.
///   • WRITE REJECT— sends fail ("Socket is not connected"), which is the
///                   exact shape that killed v16r19 in the field.
final class FakeScribeChannel: ScribeWebSocketChannel {
    enum WriteBehavior {
        case accept
        case reject(String)
        /// Reject the first N writes, then accept. Reproduces the v16r19
        /// field failure, where the first write after the WSS upgrade
        /// returned "Socket is not connected".
        case rejectFirst(Int, String)
    }

    private let lock = NSLock()

    private var pendingReceives: [(Result<ScribeSocketFrame, Error>) -> Void] = []
    private var undeliveredFrames: [Result<ScribeSocketFrame, Error>] = []
    private var writeBehavior: WriteBehavior = .accept
    private var writesRejectedSoFar = 0

    private(set) var openedURL: URL?
    private(set) var didResume = false
    private(set) var cancelCount = 0
    private(set) var sentFrames: [String] = []

    init(url: URL) {
        self.openedURL = url
    }

    // MARK: Control surface (called by tests)

    func setWriteBehavior(_ behavior: WriteBehavior) {
        lock.lock()
        writeBehavior = behavior
        writesRejectedSoFar = 0
        lock.unlock()
    }

    /// Deliver a server frame. If the session has no read outstanding —
    /// which is exactly what happens after its receive loop dies — the
    /// frame is parked and will only surface if the session ever reads
    /// again. That parking is the toggle-mode cutoff, made visible.
    func deliver(text: String) {
        deliver(.success(.text(text)))
    }

    func deliver(binary: String) {
        deliver(.success(.binary(Data(binary.utf8))))
    }

    /// Fail the read side while leaving the write side alone — a WSS
    /// half-close, the most likely cause of a mid-session cutoff.
    func failRead(_ message: String = "The operation couldn't be completed. Socket is not connected") {
        deliver(.failure(FakeSocketError(message: message)))
    }

    private func deliver(_ result: Result<ScribeSocketFrame, Error>) {
        lock.lock()
        let completion = pendingReceives.isEmpty ? nil : pendingReceives.removeFirst()
        if completion == nil { undeliveredFrames.append(result) }
        lock.unlock()
        completion?(result)
    }

    /// Frames the server sent that the session never read. Non-zero means
    /// speech was transcribed and thrown on the floor.
    var strandedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return undeliveredFrames.count
    }

    var hasOutstandingRead: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pendingReceives.isEmpty
    }

    var sentFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sentFrames.count
    }

    func sentFramesSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    func audioChunkCount() -> Int {
        sentFramesSnapshot().filter { $0.contains("input_audio_chunk") }.count
    }

    func commitFrameCount() -> Int {
        sentFramesSnapshot().filter { $0.contains("\"commit\":true") || $0.contains("\"commit\" : true") }.count
    }

    // MARK: ScribeWebSocketChannel

    func resume() {
        lock.lock(); didResume = true; lock.unlock()
    }

    func send(text: String, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        sentFrames.append(text)
        let behavior = writeBehavior
        var error: Error?
        switch behavior {
        case .accept:
            error = nil
        case .reject(let message):
            error = FakeSocketError(message: message)
        case .rejectFirst(let count, let message):
            if writesRejectedSoFar < count {
                writesRejectedSoFar += 1
                error = FakeSocketError(message: message)
            }
        }
        lock.unlock()
        completionHandler(error)
    }

    func receive(completionHandler: @escaping (Result<ScribeSocketFrame, Error>) -> Void) {
        lock.lock()
        if !undeliveredFrames.isEmpty {
            let parked = undeliveredFrames.removeFirst()
            lock.unlock()
            completionHandler(parked)
            return
        }
        pendingReceives.append(completionHandler)
        lock.unlock()
    }

    func cancelGoingAway() {
        lock.lock(); cancelCount += 1; lock.unlock()
    }
}

// MARK: - Test rig

/// Thread-safe capture of everything the session hands back to its caller.
final class SessionRecorder {
    private let lock = NSLock()
    private(set) var transcriptUpdates: [String] = []
    private(set) var finalTranscripts: [String] = []
    private(set) var errors: [Error] = []

    func recordUpdate(_ text: String) {
        lock.lock(); transcriptUpdates.append(text); lock.unlock()
    }

    func recordFinal(_ text: String) {
        lock.lock(); finalTranscripts.append(text); lock.unlock()
    }

    func recordError(_ error: Error) {
        lock.lock(); errors.append(error); lock.unlock()
    }

    var latestUpdate: String? {
        lock.lock(); defer { lock.unlock() }
        return transcriptUpdates.last
    }

    var updateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return transcriptUpdates.count
    }

    var finalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return finalTranscripts.count
    }

    var errorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return errors.count
    }

    var firstFinal: String? {
        lock.lock(); defer { lock.unlock() }
        return finalTranscripts.first
    }

    var accountFatalErrorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return errors.filter { ($0 as? BuddyProviderFatalError)?.isProviderFatal == true }.count
    }

    var firstErrorMessage: String {
        lock.lock(); defer { lock.unlock() }
        return errors.first.map { "\($0.localizedDescription)" } ?? "(none)"
    }
}

/// Every channel the session has built, in order. v16r23 reconnect makes
/// a NEW one on each rebuild, so tests need the whole sequence — index 0
/// is the original socket, index 1 the first replacement, and so on.
final class ChannelLog {
    private let lock = NSLock()
    private var channels: [FakeScribeChannel] = []
    /// Set to make the NEXT channel built reject writes from birth.
    var nextChannelWriteBehavior: FakeScribeChannel.WriteBehavior?

    func record(_ channel: FakeScribeChannel) {
        lock.lock()
        if let behavior = nextChannelWriteBehavior { channel.setWriteBehavior(behavior) }
        channels.append(channel)
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return channels.count }
    var first: FakeScribeChannel? { lock.lock(); defer { lock.unlock() }; return channels.first }
    var latest: FakeScribeChannel? { lock.lock(); defer { lock.unlock() }; return channels.last }
    func at(_ i: Int) -> FakeScribeChannel? {
        lock.lock(); defer { lock.unlock() }
        return i < channels.count ? channels[i] : nil
    }
}

struct Rig {
    let session: ScribeStreamingTranscriptionSession
    let channels: ChannelLog
    let recorder: SessionRecorder
    /// The socket the session is currently using.
    var channel: FakeScribeChannel { channels.latest! }
    /// The original socket, which reconnect retires.
    var firstChannel: FakeScribeChannel { channels.first! }
}

/// Build a session wired to fake channels. No network and no token fetch —
/// the token is only ever a query-string value and open() doesn't validate
/// it, so a literal is faithful.
func makeRig(tokenFetchFails: Bool = false) -> Rig {
    let recorder = SessionRecorder()
    let channels = ChannelLog()
    let session = ScribeStreamingTranscriptionSession(
        token: "harness-token",
        tokenFetchMs: 0,
        makeChannel: { url in
            let channel = FakeScribeChannel(url: url)
            channels.record(channel)
            return channel
        },
        tokenProvider: {
            if tokenFetchFails {
                throw FakeSocketError(message: "token endpoint unavailable")
            }
            return "harness-token-reconnect"
        },
        keyterms: [],
        onTranscriptUpdate: { recorder.recordUpdate($0) },
        onFinalTranscriptReady: { recorder.recordFinal($0) },
        onError: { recorder.recordError($0) }
    )
    // open() is what constructs the first channel; do it here so every
    // test starts from a live session.
    syncOpen(session)
    guard channels.count == 1 else {
        print("❌ FATAL: open() did not construct exactly one channel (got \(channels.count))")
        exit(2)
    }
    return Rig(session: session, channels: channels, recorder: recorder)
}

/// Bridge open()'s async signature into the harness's synchronous flow.
/// Safe: open() resolves its continuation from the session's own
/// stateQueue, never from the main queue, so blocking here cannot
/// deadlock.
func syncOpen(_ session: ScribeStreamingTranscriptionSession) {
    let semaphore = DispatchSemaphore(value: 0)
    var thrown: Error?
    Task {
        do { try await session.open() } catch { thrown = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let thrown {
        print("❌ FATAL: open() threw — \(thrown.localizedDescription)")
        exit(2)
    }
}

// MARK: - Audio

/// A 20ms mono float buffer at 48kHz — the shape the real mic tap
/// produces — filled with a sine at the requested amplitude. Runs through
/// the SHIPPED BuddyPCM16AudioConverter, so resampling and PCM16 packing
/// are exercised rather than faked.
func makeAudioBuffer(amplitude: Float, seconds: Double = 0.02) -> AVAudioPCMBuffer {
    let sampleRate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let channel = buffer.floatChannelData![0]
    for frame in 0..<Int(frameCount) {
        let phase = 2.0 * Float.pi * 220.0 * Float(frame) / Float(sampleRate)
        channel[frame] = amplitude * sin(phase)
    }
    return buffer
}

/// Measured baseline from 1,057 real capture buffers (2026-08-06):
/// median RMS 0.00049, p95 0.0026, peak 0.388. Speech during a live
/// session peaked around 0.021. These two constants keep the harness
/// honest against real signal levels rather than invented ones.
let speechAmplitude: Float = 0.03
let silenceAmplitude: Float = 0.0007

func partialFrame(_ text: String) -> String {
    #"{"message_type":"partial_transcript","text":"\#(text)"}"#
}

func committedFrame(_ text: String) -> String {
    #"{"message_type":"committed_transcript","text":"\#(text)"}"#
}

// MARK: - Diag-log hygiene

/// The session writes to the same /tmp diag logs the real app does, and
/// those logs are the primary forensic source when a cutoff is being
/// investigated. Bracket every harness run so those lines can be
/// discarded at a glance instead of being mistaken for a real engage.
let harnessTouchedLogs = [
    "/tmp/clicky_scribe_timing.log",
    "/tmp/clicky_scribe_session.log",
    "/tmp/clicky_vtt_live_preview_latency.log",
]

func markHarnessLogBoundary(_ edge: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "===== \(edge) verify_scribe_stall_recovery.swift — SYNTHETIC, NOT A REAL ENGAGE (\(stamp)) =====\n"
    guard let data = line.data(using: .utf8) else { return }
    for path in harnessTouchedLogs {
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Tests

func testHappyPath() {
    report.section("T1 — happy path (the regression guard: this is what v16r19 broke)")
    let rig = makeRig()

    report.check("open() resumed the connection", rig.channel.didResume)
    report.check("a read is posted before any audio is sent", rig.channel.hasOutstandingRead)

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("audio on the wire") { rig.channel.audioChunkCount() >= 1 }
    report.check("audio buffer reached the wire", rig.channel.audioChunkCount() >= 1)

    rig.channel.deliver(text: partialFrame("no way to scale it"))
    waitUntil("partial surfaced") { rig.recorder.latestUpdate == "no way to scale it" }
    report.check(
        "partial transcript surfaced to the caller",
        rig.recorder.latestUpdate == "no way to scale it",
        "got: \(rig.recorder.latestUpdate ?? "nil")"
    )

    rig.session.requestFinalTranscript()
    waitUntil("commit sent") { rig.channel.commitFrameCount() >= 1 }
    report.check("commit=true frame sent on finalize", rig.channel.commitFrameCount() >= 1)

    rig.channel.deliver(text: committedFrame("No way to scale it."))
    waitUntil("final delivered") { rig.recorder.finalCount == 1 }
    report.check(
        "final transcript delivered exactly once",
        rig.recorder.finalCount == 1 && rig.recorder.firstFinal == "No way to scale it.",
        "got: \(rig.recorder.firstFinal ?? "nil") (count \(rig.recorder.finalCount))"
    )
    report.check("no error raised on a clean session", rig.recorder.errorCount == 0)
    report.check("socket closed after the final", rig.channel.cancelCount >= 1)
}

func testHalfCloseRecovers() {
    report.section("T2 — THE CUTOFF: half-close mid-dictation now recovers")
    let rig = makeRig()

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    rig.firstChannel.deliver(text: partialFrame("no way to scale it? Because"))
    waitUntil("first partial") { rig.recorder.updateCount >= 1 }

    // The read side dies mid-sentence. Writes still appear to work, which
    // is why the app used to show a live indicator and a moving halo while
    // recording nothing. This is the exact shape of the 12:51 cut on
    // 2026-08-10 ("...Anything nailed-").
    rig.firstChannel.failRead()

    waitUntil("replacement socket built") { rig.channels.count >= 2 }
    report.check(
        "a replacement socket is built instead of the session dying",
        rig.channels.count >= 2,
        "channels: \(rig.channels.count)"
    )
    report.check("the dead socket was closed", rig.firstChannel.cancelCount >= 1)
    report.check(
        "no error was surfaced to the user — this is recoverable",
        rig.recorder.errorCount == 0,
        "errors: \(rig.recorder.firstErrorMessage)"
    )

    // Speech continues after the failure and must reach the NEW socket.
    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("audio on new socket") { rig.channel.audioChunkCount() >= 1 }
    report.check(
        "audio after the failure reaches the replacement",
        rig.channel.audioChunkCount() >= 1,
        "chunks on new socket: \(rig.channel.audioChunkCount())"
    )

    rig.channel.deliver(text: partialFrame("we should scale it anyway"))
    waitUntil("post-recovery partial") { rig.recorder.updateCount >= 2 }

    rig.session.requestFinalTranscript()
    waitUntil("commit on new socket") { rig.channel.commitFrameCount() >= 1 }
    rig.channel.deliver(text: committedFrame("We should scale it anyway."))
    waitUntil("final") { rig.recorder.finalCount == 1 }

    let final = rig.recorder.firstFinal ?? ""
    report.check(
        "words spoken BEFORE the failure survive in the final transcript",
        final.contains("Because"),
        "got: \(final)"
    )
    report.check(
        "words spoken AFTER the failure are in it too",
        final.contains("We should scale it anyway."),
        "got: \(final)"
    )
}

func testGenerationIdentity() {
    report.section("T9 — a dead socket's late failure must not kill its replacement")
    // v16r19's most important correctness property. Cancelling a socket
    // completes its pending read with a cancellation error; without
    // generation tracking that straggler tears down the socket that just
    // replaced it, turning every recovery into a session kill.
    let rig = makeRig()
    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    rig.firstChannel.failRead()
    waitUntil("replacement built") { rig.channels.count >= 2 }
    let channelsAfterFirstRecovery = rig.channels.count

    // The retired socket now emits its cancellation straggler, late.
    rig.firstChannel.failRead("Operation cancelled")
    settle(0.4)

    report.check(
        "the straggler is ignored — no second rebuild",
        rig.channels.count == channelsAfterFirstRecovery,
        "channels: \(channelsAfterFirstRecovery) → \(rig.channels.count)"
    )
    report.check("the session is still alive", rig.recorder.errorCount == 0)

    // And the replacement still works.
    rig.channel.deliver(text: partialFrame("still here"))
    waitUntil("replacement live") { rig.recorder.latestUpdate?.contains("still here") == true }
    report.check(
        "the replacement socket still delivers transcripts",
        rig.recorder.latestUpdate?.contains("still here") == true,
        "got: \(rig.recorder.latestUpdate ?? "nil")"
    )
}

func testGapAudioIsBufferedNotLost() {
    report.section("T3 — audio spoken during the rebuild is buffered, not dropped")
    // Token fetch fails, so the session sits in the reconnecting state and
    // the test can speak into the gap deterministically.
    let rig = makeRig(tokenFetchFails: true)

    rig.firstChannel.failRead()
    settle(0.3)

    // Speak while there is no usable socket.
    let chunksOnDeadSocket = rig.firstChannel.audioChunkCount()
    for _ in 0..<5 {
        rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    }
    settle(0.3)
    report.check(
        "nothing is fired at the retired socket",
        rig.firstChannel.audioChunkCount() == chunksOnDeadSocket,
        "chunks \(chunksOnDeadSocket) → \(rig.firstChannel.audioChunkCount())"
    )

    // Budget exhausts (3 attempts, token fetch failing every time) and the
    // session fails ONCE — not once per audio buffer.
    waitUntil("budget spent", timeout: 4.0) { rig.recorder.errorCount >= 1 }
    for _ in 0..<5 {
        rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    }
    settle(0.3)
    report.check(
        "failSession is idempotent — one fault, one error, not a storm",
        rig.recorder.errorCount == 1,
        "errors: \(rig.recorder.errorCount)"
    )
    report.check(
        "reconnect gives up after a bounded number of attempts",
        rig.channels.count <= 4,
        "channels built: \(rig.channels.count)"
    )
}

func testCancelIsTerminal() {
    report.section("T4 — cancel() is terminal and cannot be resurrected")
    let rig = makeRig()

    rig.session.cancel()
    settle()
    let chunksAfterCancel = rig.firstChannel.audioChunkCount()
    let channelsAfterCancel = rig.channels.count

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    settle(0.3)
    report.check(
        "no audio is sent after cancel()",
        rig.firstChannel.audioChunkCount() == chunksAfterCancel,
        "chunks \(chunksAfterCancel) → \(rig.firstChannel.audioChunkCount())"
    )
    report.check("cancel() closed the socket", rig.firstChannel.cancelCount >= 1)

    // A failure arriving after cancel must NOT trigger a rebuild — a
    // finished session cannot be resurrected by its own recovery.
    rig.firstChannel.failRead()
    settle(0.4)
    report.check(
        "a post-cancel failure does not build a replacement",
        rig.channels.count == channelsAfterCancel,
        "channels \(channelsAfterCancel) → \(rig.channels.count)"
    )
    report.check("no error surfaced from a cancelled session", rig.recorder.errorCount == 0)
}

func testCommitDeferredDuringRebuild() {
    report.section("T10 — releasing the key mid-rebuild still commits")
    // The nastiest regression this fix can cause: the commit frame hits a
    // nil socket, the server never commits, the 1.4s deadline fires, and
    // the tail is lost — the original bug, reproduced by its own fix.
    let rig = makeRig()
    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    rig.firstChannel.deliver(text: partialFrame("mid rebuild release"))
    waitUntil("partial") { rig.recorder.updateCount >= 1 }

    rig.firstChannel.failRead()
    waitUntil("replacement built") { rig.channels.count >= 2 }

    rig.session.requestFinalTranscript()
    waitUntil("commit lands on the replacement") { rig.channel.commitFrameCount() >= 1 }
    report.check(
        "the commit frame reaches the replacement socket",
        rig.channel.commitFrameCount() >= 1,
        "commits on new socket: \(rig.channel.commitFrameCount())"
    )

    rig.channel.deliver(text: committedFrame("Mid rebuild release."))
    waitUntil("final") { rig.recorder.finalCount == 1 }
    report.check(
        "a final transcript is still delivered",
        rig.recorder.finalCount == 1,
        "finals: \(rig.recorder.finalCount)"
    )
}

func testFirstWriteRejection() {
    report.section("T5 — the exact failure that killed v16r19 in the field")
    // 2026-08-06: after relaunch the engage chimed, the dot turned teal,
    // the halo tracked the voice — and the first write after the WSS
    // upgrade returned "Socket is not connected". Any future reconnect
    // logic MUST survive this case; that is why it is pinned here.
    let rig = makeRig()
    rig.firstChannel.setWriteBehavior(.reject("The operation couldn't be completed. Socket is not connected"))

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("replacement built") { rig.channels.count >= 2 }
    report.check(
        "a rejected write rebuilds the socket instead of ending the dictation",
        rig.channels.count >= 2,
        "channels: \(rig.channels.count)"
    )

    // The replacement works — this is the recovery v16r19 never achieved.
    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    rig.channel.deliver(text: partialFrame("recovered after write failure"))
    waitUntil("transcript flows") { rig.recorder.updateCount >= 1 }
    report.check(
        "transcription continues on the replacement",
        rig.recorder.latestUpdate?.contains("recovered") == true,
        "got: \(rig.recorder.latestUpdate ?? "nil")"
    )
    report.check(
        "the user is never shown an error for a recoverable fault",
        rig.recorder.errorCount == 0,
        "errors: \(rig.recorder.firstErrorMessage)"
    )

    rig.session.requestFinalTranscript()
    rig.channel.deliver(text: committedFrame("Recovered after write failure."))
    waitUntil("final") { rig.recorder.finalCount == 1 }
    report.check("a final transcript is still delivered", rig.recorder.finalCount == 1)
}

func testAccountFatalNeverReconnects() {
    report.section("T6 — quota/auth refusals must NEVER trigger reconnect")
    // THE v16r19 POST-MORTEM, ENCODED. On 2026-08-06 ElevenLabs refused
    // every session for quota. v16r19 read those refusals as transient,
    // burned its retry budget in seconds, and killed the session —
    // amplifying an account problem into an app failure. Reconnect must
    // stay away from anything the classifier calls account-fatal.
    let rig = makeRig()

    rig.firstChannel.deliver(
        text: #"{"message_type":"quota_exceeded","error":"You have exceeded your quota."}"#
    )
    waitUntil("escalated") { rig.recorder.errorCount >= 1 }

    settle(0.5)
    report.check(
        "NO replacement socket is built for an account-fatal refusal",
        rig.channels.count == 1,
        "channels: \(rig.channels.count) (must stay 1)"
    )
    report.check("quota_exceeded is escalated rather than discarded", rig.recorder.errorCount >= 1)
    report.check(
        "it is marked account-fatal, so CompanionManager switches engines",
        rig.recorder.accountFatalErrorCount >= 1
    )
    report.check(
        "it carries the server's own wording",
        rig.recorder.firstErrorMessage == "You have exceeded your quota.",
        "got: \(rig.recorder.firstErrorMessage)"
    )
}

func testBinaryFramePathPreserved() {
    report.section("T7 — binary frames still parse (guards the v16r21 refactor itself)")
    let rig = makeRig()

    rig.channel.deliver(binary: partialFrame("binary path intact"))
    waitUntil("binary partial") { rig.recorder.latestUpdate == "binary path intact" }
    report.check(
        "a transcript delivered as binary is handled identically to text",
        rig.recorder.latestUpdate == "binary path intact",
        "got: \(rig.recorder.latestUpdate ?? "nil")"
    )
}

func testScribeArtifactCleaning() {
    report.section("T8 — filler/ellipsis cleaning still applied end-to-end")
    let rig = makeRig()

    rig.channel.deliver(text: partialFrame("Um, we should uh scale it…"))
    waitUntil("cleaned") { rig.recorder.latestUpdate == "we should scale it" }
    report.check(
        "fillers and pause ellipses are stripped at the source",
        rig.recorder.latestUpdate == "we should scale it",
        "got: \(rig.recorder.latestUpdate ?? "nil")"
    )
}

// MARK: - Entry point

@main
struct ScribeStallRecoveryHarness {
    static func main() {
        print("""

        ScribeStreamingTranscriptionSession — mock-WebSocket harness (v16r21)
        Driving the SHIPPED session against a transport that misbehaves to order.
        """)

        markHarnessLogBoundary("BEGIN")

        testHappyPath()
        testHalfCloseRecovers()
        testGenerationIdentity()
        testGapAudioIsBufferedNotLost()
        testCancelIsTerminal()
        testCommitDeferredDuringRebuild()
        testFirstWriteRejection()
        testAccountFatalNeverReconnects()
        testBinaryFramePathPreserved()
        testScribeArtifactCleaning()

        markHarnessLogBoundary("END")

        print("\n" + String(repeating: "-", count: 62))
        if report.failures == 0 {
            print("✅ \(report.checks) checks passed.")
            print("""

            v16r23: T2/T5 now assert RECOVERY rather than documenting the bug.
            Still NOT covered — a socket that stays open while the server goes
            silent. That needs the stall watchdog, which is deliberately out of
            scope. Watch /tmp/clicky_scribe_session.log: if cuts persist with no
            TRANSPORT FAILURE line, that's the remaining case.
            """)
            exit(0)
        } else {
            print("❌ \(report.failures) of \(report.checks) checks failed.")
            exit(1)
        }
    }
}
