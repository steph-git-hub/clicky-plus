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

struct Rig {
    let session: ScribeStreamingTranscriptionSession
    let channel: FakeScribeChannel
    let recorder: SessionRecorder
}

/// Build a session wired to a fake channel. No network, no token fetch —
/// the token is only ever a query-string value, and open() does not
/// validate it, so a literal is faithful.
func makeRig() -> Rig {
    let recorder = SessionRecorder()
    var built: FakeScribeChannel?
    let session = ScribeStreamingTranscriptionSession(
        token: "harness-token",
        tokenFetchMs: 0,
        makeChannel: { url in
            let channel = FakeScribeChannel(url: url)
            built = channel
            return channel
        },
        keyterms: [],
        onTranscriptUpdate: { recorder.recordUpdate($0) },
        onFinalTranscriptReady: { recorder.recordFinal($0) },
        onError: { recorder.recordError($0) }
    )
    // open() is what constructs the channel; do it here so every test
    // starts from a live session.
    syncOpen(session)
    guard let channel = built else {
        print("❌ FATAL: channel was never constructed by open()")
        exit(2)
    }
    return Rig(session: session, channel: channel, recorder: recorder)
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

func testHalfCloseCutoff() {
    report.section("T2 — half-close = the toggle-mode cutoff, reproduced deterministically")
    let rig = makeRig()

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    rig.channel.deliver(text: partialFrame("no way to scale it? Because"))
    waitUntil("first partial") { rig.recorder.updateCount >= 1 }
    let updatesBeforeCut = rig.recorder.updateCount

    // The read side dies. Writes still succeed — which is why the app
    // shows a live indicator and a moving halo the whole time.
    rig.channel.failRead()
    waitUntil("failure surfaced") { rig.recorder.errorCount >= 1 }
    report.check("a read failure is reported to the caller", rig.recorder.errorCount >= 1)

    // The server has not stopped transcribing. The session has stopped
    // listening.
    rig.channel.deliver(text: partialFrame("we should scale it anyway"))
    settle()
    report.check(
        "CUTOFF REPRODUCED — no transcript after one read failure",
        rig.recorder.updateCount == updatesBeforeCut,
        "updates went \(updatesBeforeCut) → \(rig.recorder.updateCount)"
    )
    report.check(
        "the rest of the speech is stranded on the socket",
        rig.channel.strandedFrameCount >= 1,
        "stranded: \(rig.channel.strandedFrameCount)"
    )
    report.check("no read is ever posted again", !rig.channel.hasOutstandingRead)
}

func testDeadSessionKeepsPumping() {
    report.section("T3 — GAP: no dead-session guard on appendAudioBuffer")
    let rig = makeRig()

    rig.channel.failRead()
    waitUntil("session dead") { rig.recorder.errorCount >= 1 }
    let chunksAtDeath = rig.channel.audioChunkCount()

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("post-mortem audio") { rig.channel.audioChunkCount() > chunksAtDeath }
    report.check(
        "GAP CONFIRMED — audio is still pumped into a dead session",
        rig.channel.audioChunkCount() > chunksAtDeath,
        "chunks \(chunksAtDeath) → \(rig.channel.audioChunkCount())"
    )

    // And once the socket also starts rejecting writes, every buffer
    // re-enters failSession, because failSession has no idempotency
    // guard. One fault becomes a fault per 20ms of speech.
    rig.channel.setWriteBehavior(.reject("Socket is not connected"))
    let errorsBeforeStorm = rig.recorder.errorCount
    for _ in 0..<5 {
        rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    }
    waitUntil("storm") { rig.recorder.errorCount >= errorsBeforeStorm + 5 }
    report.check(
        "GAP CONFIRMED — failSession is not idempotent, so errors multiply",
        rig.recorder.errorCount >= errorsBeforeStorm + 5,
        "errors \(errorsBeforeStorm) → \(rig.recorder.errorCount)"
    )
}

func testTerminalFlagIsWriteOnly() {
    report.section("T4 — GAP: hasFailedOrTerminated is write-only")
    let rig = makeRig()

    rig.session.cancel()
    settle()
    let chunksAfterCancel = rig.channel.audioChunkCount()

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("post-cancel audio") { rig.channel.audioChunkCount() > chunksAfterCancel }
    report.check(
        "GAP CONFIRMED — audio is still sent after cancel()",
        rig.channel.audioChunkCount() > chunksAfterCancel,
        "chunks \(chunksAfterCancel) → \(rig.channel.audioChunkCount())"
    )
    report.check("cancel() did close the socket", rig.channel.cancelCount >= 1)
}

func testFirstWriteRejection() {
    report.section("T5 — the exact failure that killed v16r19 in the field")
    // 2026-08-06: after relaunch the engage chimed, the dot turned teal,
    // the halo tracked the voice — and the first write after the WSS
    // upgrade returned "Socket is not connected". Any future reconnect
    // logic MUST survive this case; that is why it is pinned here.
    let rig = makeRig()
    rig.channel.setWriteBehavior(.reject("The operation couldn't be completed. Socket is not connected"))

    rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    waitUntil("write rejected") { rig.recorder.errorCount >= 1 }
    report.check("a rejected write is reported, not swallowed", rig.recorder.errorCount >= 1)
    report.check(
        "the reported error carries the transport's own wording",
        rig.recorder.firstErrorMessage.contains("Socket is not connected"),
        "got: \(rig.recorder.firstErrorMessage)"
    )
    report.check("no transcript is produced", rig.recorder.finalCount == 0)

    // Pin today's behavior so the next attempt has something to beat:
    // one write error per buffer, forever, with no recovery and no cap.
    let errorsBefore = rig.recorder.errorCount
    for _ in 0..<4 {
        rig.session.appendAudioBuffer(makeAudioBuffer(amplitude: speechAmplitude))
    }
    waitUntil("unbounded") { rig.recorder.errorCount >= errorsBefore + 4 }
    report.check(
        "BASELINE — every rejected write is its own session failure (no cap, no recovery)",
        rig.recorder.errorCount >= errorsBefore + 4,
        "errors \(errorsBefore) → \(rig.recorder.errorCount)"
    )
}

func testAccountFatalFrameStillEscalates() {
    report.section("T6 — v16r20 quota/auth escalation survives the seam")
    let rig = makeRig()

    rig.channel.deliver(
        text: #"{"message_type":"quota_exceeded","error":"You have exceeded your quota."}"#
    )
    waitUntil("escalated") { rig.recorder.errorCount >= 1 }
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
        testHalfCloseCutoff()
        testDeadSessionKeepsPumping()
        testTerminalFlagIsWriteOnly()
        testFirstWriteRejection()
        testAccountFatalFrameStillEscalates()
        testBinaryFramePathPreserved()
        testScribeArtifactCleaning()

        markHarnessLogBoundary("END")

        print("\n" + String(repeating: "-", count: 62))
        if report.failures == 0 {
            print("✅ \(report.checks) checks passed.")
            print("""

            NOTE: T2–T5 passing means the DEFECTS ARE STILL PRESENT and are now
            pinned. They are the specification for the next attempt: when the
            stall watchdog is re-added, those four tests must be rewritten to
            assert recovery, and T1 must still pass unchanged.
            """)
            exit(0)
        } else {
            print("❌ \(report.failures) of \(report.checks) checks failed.")
            exit(1)
        }
    }
}
