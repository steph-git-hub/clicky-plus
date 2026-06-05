//
//  SpeechWakeWordManager.swift
//  leanring-buddy / Clicky+
//
//  v16 wake word: on-device "Marin" detection via Apple's Speech framework.
//  Continuous on-device SFSpeechRecognizer while idle; "marin"/"maren" in the
//  transcript fires `onWake` (CompanionManager engages Marin). Gated off during
//  capture via `isGatedOut` (clickyHasActiveAction) + CompanionManager's 0.5s
//  pause/resume timer (mic arbitration). Diag → /tmp/clicky_wakeword.log
//
//  v16pi: every restart fully rebuilds the audio engine (lightweight task-only
//  restarts got the recognizer stuck in a "No speech detected" loop). Backoff
//  on repeated no-speech so prolonged silence doesn't churn the engine.
//

import AVFoundation
import Foundation
import Speech

final class SpeechWakeWordManager {
    var onWake: (() -> Void)?
    var isGatedOut: (() -> Bool)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var active = false            // wants to be listening (start/stop own this)
    private var firedThisSession = false
    private var consecutiveNoSpeech = 0   // backoff counter

    // On-device recognizer spells "Marin" as "Marin" OR "Maren". \b stops it
    // from matching "marine"/"marina". "Hey Marin" matches via the inner word.
    private let matchRegex = try? NSRegularExpression(
        pattern: "\\bmar[ie]n\\b", options: [.caseInsensitive])

    private static func diag(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        let path = "/tmp/clicky_wakeword.log"
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

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    }

    func start() {
        guard !active else { return }
        active = true
        consecutiveNoSpeech = 0
        beginSession()
    }

    func stop() {
        guard active else { return }
        active = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        tearDown()
        Self.diag("stopped")
    }

    func pauseForCapture() { stop() }
    func resumeAfterCapture() { start() }

    // MARK: - internals

    private func beginSession() {
        guard active else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            Self.diag("blocked: not authorized (status=\(SFSpeechRecognizer.authorizationStatus().rawValue))")
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Self.diag("blocked: recognizer unavailable")
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            Self.diag("audio engine failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }

        firedThisSession = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .search
        req.requiresOnDeviceRecognition = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    Self.diag("heard: \(text)")
                    self.consecutiveNoSpeech = 0
                }
                if !self.firedThisSession, self.matches(text) {
                    self.firedThisSession = true
                    let gated = self.isGatedOut?() == true
                    Self.diag("FIRE marin gated=\(gated)")
                    if gated {
                        self.restartSession(after: 0.5)
                    } else {
                        DispatchQueue.main.async {
                            self.stop()
                            self.onWake?()
                        }
                    }
                    return
                }
            }
            if let error {
                let msg = error.localizedDescription
                if msg.contains("No speech") {
                    self.consecutiveNoSpeech += 1
                } else {
                    Self.diag("error: \(msg)")
                }
                // Back off during prolonged silence so we don't churn the engine.
                let delay = min(3.0, 0.6 * Double(max(1, self.consecutiveNoSpeech)))
                self.restartSession(after: delay)
            } else if result?.isFinal == true {
                self.restartSession(after: 0.6)
            }
        }
        Self.diag("listening (engine started)")

        // Safety net: rebuild well before the on-device session-length limit.
        scheduleHardRestart(after: 45)
    }

    private func tearDown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// FULL rebuild (engine + tap + request + task) — the robust restart.
    private func restartSession(after seconds: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.tearDown()
            self.beginSession()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func scheduleHardRestart(after seconds: TimeInterval) {
        // Only used as the long-interval safety rebuild; restartSession owns
        // the work item, so a sooner error-driven restart supersedes this.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.active else { return }
            self.restartSession(after: 0)
        }
    }

    private func matches(_ text: String) -> Bool {
        guard let rx = matchRegex else {
            let t = text.lowercased(); return t.contains("marin") || t.contains("maren")
        }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
