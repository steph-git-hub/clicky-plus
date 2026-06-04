//
//  SpeechWakeWordManager.swift
//  leanring-buddy / Clicky+
//
//  v16 wake word: on-device "Marin" detection via Apple's Speech framework.
//  Continuous on-device SFSpeechRecognizer while idle; "marin" in the
//  transcript fires `onWake` (CompanionManager engages Marin). Gated off
//  during capture via `isGatedOut` (clickyHasActiveAction) + CompanionManager's
//  0.5s pause/resume timer (mic arbitration). Diag → /tmp/clicky_wakeword.log
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
    private var isRunning = false
    private var firedThisSession = false

    private let matchRegex = try? NSRegularExpression(
        pattern: "\\bmarin\\b", options: [.caseInsensitive])

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
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            Self.diag("start blocked: not authorized (status=\(SFSpeechRecognizer.authorizationStatus().rawValue))")
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Self.diag("start blocked: recognizer unavailable (available=\(recognizer?.isAvailable ?? false) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false))")
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
        isRunning = true
        startRecognition()
        Self.diag("listening (engine started)")
    }

    private func startRecognition() {
        guard isRunning, let recognizer else { return }
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
                if !text.isEmpty { Self.diag("heard: \(text)") }
                if !self.firedThisSession, self.matches(text) {
                    self.firedThisSession = true
                    let gated = self.isGatedOut?() == true
                    Self.diag("FIRE marin gated=\(gated)")
                    if gated {
                        self.scheduleRestart(after: 0.4)
                    } else {
                        DispatchQueue.main.async {
                            self.stop()
                            self.onWake?()
                        }
                    }
                    return
                }
            }
            if let error { Self.diag("error: \(error.localizedDescription)") }
            if error != nil || (result?.isFinal ?? false) {
                self.scheduleRestart(after: 0.4)
            }
        }
        scheduleRestart(after: 50)
    }

    private func matches(_ text: String) -> Bool {
        guard let rx = matchRegex else { return text.lowercased().contains("marin") }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func scheduleRestart(after seconds: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.task?.cancel()
            self.task = nil
            self.request?.endAudio()
            self.request = nil
            self.startRecognition()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        Self.diag("stopped")
    }

    func pauseForCapture() { stop() }
    func resumeAfterCapture() { start() }
}
