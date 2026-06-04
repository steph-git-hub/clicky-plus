//
//  SpeechWakeWordManager.swift
//  leanring-buddy / Clicky+
//
//  v16 wake word: on-device "Marin" detection via Apple's Speech framework
//  (no account, no model, no extra dependency). Runs a continuous on-device
//  SFSpeechRecognizer while Clicky is idle; when "marin" appears in the
//  transcript it fires `onWake` (CompanionManager engages Marin).
//
//  Design notes:
//   - One AVAudioEngine kept running; only the recognition task/request is
//     swapped on restart (gentler on CoreAudio than cycling the engine).
//   - Periodic restart (~50s) dodges the on-device session length limit.
//   - `isGatedOut` (CompanionManager's clickyHasActiveAction) suppresses
//     firing while any capture mode is active — Steph only says "Marin"
//     while dictating, so this kills the false-trigger case. Capture starts
//     should also call stop()/pauseForCapture() for mic arbitration.
//   - Requires on-device recognition; if unavailable we don't start (no
//     always-on network STT).
//

import AVFoundation
import Foundation
import Speech

final class SpeechWakeWordManager {
    /// Called on the main thread when "marin" is detected AND not gated.
    var onWake: (() -> Void)?
    /// Return true when a capture mode is active (clickyHasActiveAction).
    var isGatedOut: (() -> Bool)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var firedThisSession = false

    /// Word-bounded, case-insensitive "marin" so it ignores "marine",
    /// "marina", etc. and mid-word matches.
    private let matchRegex = try? NSRegularExpression(
        pattern: "\\bmarin\\b", options: [.caseInsensitive])

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    }

    func start() {
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            print("👂 wake word: on-device recognition unavailable — not starting")
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
            print("👂 wake word: audio engine failed — \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        isRunning = true
        startRecognition()
        print("👂 wake word: listening for 'Marin'")
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
                if !self.firedThisSession, self.matches(text) {
                    self.firedThisSession = true
                    if self.isGatedOut?() != true {
                        DispatchQueue.main.async { self.onWake?() }
                    }
                    self.scheduleRestart(after: 0.5)   // fresh session, don't re-fire
                    return
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.scheduleRestart(after: 0.2)
            }
        }
        scheduleRestart(after: 50)   // dodge the on-device session-length limit
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
        print("👂 wake word: stopped")
    }

    /// Mic arbitration — pause while Clicky captures, resume when idle.
    func pauseForCapture() { stop() }
    func resumeAfterCapture() { start() }
}
