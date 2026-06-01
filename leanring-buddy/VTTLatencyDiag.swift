//
//  VTTLatencyDiag.swift
//  leanring-buddy
//
//  v15p3br (2026-05-13): per-engage latency instrumentation for the
//  VTT live-preview path. Goal: identify which segment dominates the
//  press-to-first-pixel latency so we can target it.
//
//  Four timestamps are recorded per engage:
//    T0: press (hotkey press handler entry)
//    T1: first audio buffer (tap callback fires)
//    T2: first AssemblyAI Turn message
//    T3: first UI update (live transcript variable changes)
//
//  Each engage emits one line to /tmp/clicky_vtt_live_preview_latency.log
//  in the form:
//    [ISO timestamp] firstBuffer=Xms firstTurn=Yms firstUiUpdate=Zms preview="..."
//
//  Subtracting gives the breakdown:
//    T1-T0  = audio engine warm-up (small if pre-warmed)
//    T2-T1  = WebSocket send + AssemblyAI processing
//    T3-T2  = local processing (state queue + main-actor hop)
//

import Foundation

enum VTTLatencyDiag {
    private static let logQueue = DispatchQueue(label: "com.learningbuddy.vtt-latency-diag")
    private static let logPath = "/tmp/clicky_vtt_live_preview_latency.log"

    // State for the current engage. All access serialized on logQueue.
    private nonisolated(unsafe) static var pressDate: Date?
    private nonisolated(unsafe) static var firstBufferMs: Int?
    private nonisolated(unsafe) static var firstTurnMs: Int?
    private nonisolated(unsafe) static var firstUiUpdateMs: Int?
    private nonisolated(unsafe) static var firstTurnPreview: String?
    private nonisolated(unsafe) static var firstUiPreview: String?
    /// v15p3bv (2026-05-13): which transcription provider this engage
    /// is using. Logged so the comparison file can distinguish
    /// AssemblyAI vs Deepgram entries at a glance.
    private nonisolated(unsafe) static var activeProvider: String = "?"

    /// Call at the moment the VTT hotkey press handler runs. Resets all
    /// per-engage state. Subsequent mark* calls compute their delta
    /// relative to this timestamp.
    /// `provider` identifies which transcription provider is active
    /// for this engage so head-to-head A/B data is easy to filter.
    static func markPress(provider: String = "assemblyai") {
        logQueue.async {
            // Flush prior engage if it was never completed (in case the
            // user released before any UI update arrived).
            if pressDate != nil {
                writeLine()
            }
            pressDate = Date()
            firstBufferMs = nil
            firstTurnMs = nil
            firstUiUpdateMs = nil
            firstTurnPreview = nil
            firstUiPreview = nil
            activeProvider = provider
        }
    }

    /// Call when the first audio tap buffer arrives after a press.
    /// Idempotent — only the first call per engage records a value.
    static func markFirstAudioBuffer() {
        let now = Date()
        logQueue.async {
            guard firstBufferMs == nil, let start = pressDate else { return }
            firstBufferMs = Int(now.timeIntervalSince(start) * 1000)
        }
    }

    /// Call when the first transcription provider message arrives with
    /// non-empty text (AssemblyAI Turn or Deepgram Results, whichever
    /// provider is active for this engage). Idempotent. Captures a
    /// preview of what the model first transcribed.
    static func markFirstProviderTurn(preview: String) {
        let now = Date()
        logQueue.async {
            guard firstTurnMs == nil, let start = pressDate else { return }
            firstTurnMs = Int(now.timeIntervalSince(start) * 1000)
            firstTurnPreview = String(preview.prefix(60))
        }
    }

    /// Backwards-compat alias. The old name was AssemblyAI-specific;
    /// kept so the existing call site in the AssemblyAI provider
    /// continues to compile without churn.
    static func markFirstAssemblyAITurn(preview: String) {
        markFirstProviderTurn(preview: preview)
    }

    /// Call when the live-preview UI variable receives its first update
    /// after a press. Idempotent. Once this fires, the full engage is
    /// logged and the per-engage state is reset.
    static func markFirstUiUpdate(text: String) {
        let now = Date()
        logQueue.async {
            guard firstUiUpdateMs == nil, let start = pressDate else { return }
            firstUiUpdateMs = Int(now.timeIntervalSince(start) * 1000)
            firstUiPreview = String(text.prefix(60))
            writeLine()
            // Reset so next press starts clean.
            pressDate = nil
            firstBufferMs = nil
            firstTurnMs = nil
            firstUiUpdateMs = nil
            firstTurnPreview = nil
            firstUiPreview = nil
        }
    }

    private static func writeLine() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let buf = firstBufferMs.map { "\($0)ms" } ?? "—"
        let turn = firstTurnMs.map { "\($0)ms" } ?? "—"
        let ui = firstUiUpdateMs.map { "\($0)ms" } ?? "—"
        let escape: (String) -> String = { s in
            s.replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\"", with: "'")
        }
        let preview = escape(firstUiPreview ?? firstTurnPreview ?? "")
        let line = "[\(now)] provider=\(activeProvider) firstBuffer=\(buf) firstTurn=\(turn) firstUiUpdate=\(ui) preview=\"\(preview)\"\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }
}
