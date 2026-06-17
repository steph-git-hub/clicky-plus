//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// A single user/assistant exchange. Codable so it can be persisted to disk
/// across app restarts.
struct ConversationEntry: Codable {
    let userTranscript: String
    let assistantResponse: String
    /// v16qn (2026-06-14): screenshot(s) Claude saw on this turn, kept in
    /// memory so Claude can SEE recent screens (Claude Vision Phase 1),
    /// not just read a text placeholder. EXCLUDED from Codable on purpose
    /// — disk history stays small and visual memory is a within-session
    /// thing (resets on app restart, which is fine for a conversation).
    var screenshots: [Data] = []
    enum CodingKeys: String, CodingKey { case userTranscript, assistantResponse }
}

/// v16qn: how many of the most-recent turns carry their screenshots into
/// Claude's context. Bounds tokens/cost; older turns stay text-only.
private let claudeVisualMemoryTurns = 3

// MARK: - Clicky Transcript Log (v11y, 2026-04-27)
//
// Persists every Clicky interaction to a daily JSONL + Obsidian markdown
// file so Steph never loses a thought and can browse historical context.
// Screenshots are saved alongside (ephemeral — pruned by future memory-
// scan skill after it processes them). Phase 1 = persistence layer only;
// the daily memory-scan skill is a separate ship.

/// Which Clicky mode produced the interaction.
enum ClickyInteractionMode: String, Codable {
    case basePTT = "base_ptt"
    case vttHold = "vtt_hold"
    case vttToggle = "vtt_toggle"
    case typing = "typing"
    case polish = "polish"
    case burst = "burst"
    case captureInbox = "capture_inbox"
    /// v15p2 (2026-05-02): OpenAI Realtime conversation. One log entry
    /// per turn (user utterance + Marin's response).
    case realtime = "realtime"

    var displayLabel: String {
        switch self {
        case .basePTT: return "Base PTT"
        case .vttHold: return "VTT (hold)"
        case .vttToggle: return "VTT (toggle)"
        case .typing: return "Typing"
        case .polish: return "Polish"
        case .burst: return "Burst"
        case .captureInbox: return "Capture-to-inbox"
        case .realtime: return "Realtime (Marin)"
        }
    }
}

/// One row in the daily JSONL transcript log. All fields optional except
/// id/timestamp/mode so different interaction shapes can fit a single
/// schema. Codable for direct JSON encoding.
struct ClickyInteractionLog: Codable {
    let id: String
    let timestamp: Date
    let mode: ClickyInteractionMode
    /// The original transcribed text from AssemblyAI (before any processing).
    let rawTranscript: String?
    /// What got pasted/output to the user-facing field. Includes spoken-
    /// punctuation substitutions, polish, etc.
    let finalOutput: String?
    /// Claude's spoken/typed response, for modes that involve Claude.
    let claudeResponse: String?
    /// Polish-mode "modifier" guidance, if any (e.g. "make it shorter").
    let polishModifier: String?
    /// Focused app at time of capture (best-effort).
    let appName: String?
    /// Relative paths (under ~/Library/Application Support/Clicky) to the
    /// JPEG screenshot files captured for this interaction. Empty for
    /// modes that don't capture screenshots (VTT, polish, capture-inbox).
    let screenshotPaths: [String]
    /// v15n (2026-05-01): Polish/repunctuate stage outcome, surfaced in
    /// the Obsidian transcript so silent failures stop being silent.
    /// nil = polish/repunctuate not applicable for this interaction.
    /// "ok" = succeeded.
    /// "skipped:<reason>" = intentionally not run (toggle mode skips
    ///                      repunctuate; short-utterance bypass; etc.)
    /// "failed:<reason>" = errored or timed out; final output is the
    ///                     fallback (punctuated raw or unpunctuated raw).
    let polishStatus: String?

    // v15p3gw (2026-05-18): shadow A/B fields. When a secondary
    // transcription provider runs in parallel with the primary (e.g.
    // AssemblyAI shadowing Deepgram during VTT), the parallel
    // transcript + metadata are captured here so we can compare
    // empirically. All optional so legacy log rows decode fine and
    // non-VTT modes don't need to populate them.
    /// Name of the shadow provider that ran in parallel. "assemblyai"
    /// is the only value used today; future could be "openai", etc.
    let shadowProvider: String?
    /// Raw transcript from the shadow provider, pre-/repunctuate.
    /// nil = shadow didn't run or failed to deliver before timeout.
    let shadowRawTranscript: String?
    /// Shadow transcript after running through the same /repunctuate
    /// pass the primary path used. Lets us compare apples-to-apples
    /// (both providers' final output, not raw-vs-finalized).
    let shadowFinalOutput: String?
    /// Latency from VTT key release to shadow's final transcript
    /// being available. Useful for "is AssemblyAI faster or slower?"
    let shadowTranscriptionLatencyMs: Int?
    /// Short error string if shadow failed (token fetch, WS open,
    /// mid-session error, timeout). nil = shadow succeeded or wasn't
    /// configured.
    let shadowError: String?

    // v15p3gw (2026-05-18): convenience init defaulting the shadow
    // fields to nil so the existing 8+ call sites that construct
    // ClickyInteractionLog don't all need to thread nil arguments
    // through. Only the VTT call site (which adds shadow data) uses
    // the full memberwise init explicitly.
    init(
        id: String,
        timestamp: Date,
        mode: ClickyInteractionMode,
        rawTranscript: String?,
        finalOutput: String?,
        claudeResponse: String?,
        polishModifier: String?,
        appName: String?,
        screenshotPaths: [String],
        polishStatus: String?,
        shadowProvider: String? = nil,
        shadowRawTranscript: String? = nil,
        shadowFinalOutput: String? = nil,
        shadowTranscriptionLatencyMs: Int? = nil,
        shadowError: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.rawTranscript = rawTranscript
        self.finalOutput = finalOutput
        self.claudeResponse = claudeResponse
        self.polishModifier = polishModifier
        self.appName = appName
        self.screenshotPaths = screenshotPaths
        self.polishStatus = polishStatus
        self.shadowProvider = shadowProvider
        self.shadowRawTranscript = shadowRawTranscript
        self.shadowFinalOutput = shadowFinalOutput
        self.shadowTranscriptionLatencyMs = shadowTranscriptionLatencyMs
        self.shadowError = shadowError
    }
}

/// Singleton logger that writes interactions to disk + Obsidian.
///
/// Layout:
///   ~/Library/Application Support/Clicky/transcripts/YYYY-MM-DD.jsonl
///   ~/Library/Application Support/Clicky/screenshots/YYYY-MM-DD/HHmm-id-frameN.jpg
///   <Obsidian vault>/Clicky Transcripts/YYYY-MM-DD.md
///
/// All writes are append-only. The Obsidian markdown file is built up
/// section-by-section as interactions complete, so it's always up-to-date
/// even if Clicky crashes mid-day.
@MainActor
final class ClickyTranscriptLogger {
    static let shared = ClickyTranscriptLogger()

    /// Path to the Obsidian vault folder for transcript markdown exports.
    /// Hardcoded to match Steph's setup; if the vault path ever changes,
    /// update here. Missing directory is fine — we create on first write.
    private static let obsidianTranscriptsFolderPath = "/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Transcripts"

    /// Path to the structured-log + screenshot storage. v12k (2026-04-28):
    /// moved from ~/Library/Application Support/Clicky/ (not in Cowork's
    /// allowed-folders, so the daily memory-scan task couldn't read it)
    /// to inside the Obsidian vault, which Cowork already has access to.
    /// Now the scheduled task can read JSONL + screenshots without any
    /// special permission grants.
    private static let clickyLogsBaseFolderPath = "/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs"

    private let dateFormatterISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormatterDailyKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
    private let dateFormatterTimeOfDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
    private let dateFormatterFilenameTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm"
        formatter.timeZone = .current
        return formatter
    }()

    /// Returns the base directory for Clicky persisted data — now inside
    /// the Obsidian vault so Cowork's allowed-folder access covers it.
    /// Creates it on first call if missing.
    private func clickyApplicationSupportDirectory() -> URL? {
        let baseURL = URL(fileURLWithPath: Self.clickyLogsBaseFolderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private func dailyTranscriptJSONLURL(for date: Date) -> URL? {
        guard let baseDir = clickyApplicationSupportDirectory() else { return nil }
        let transcriptsDir = baseDir.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        return transcriptsDir.appendingPathComponent("\(dateFormatterDailyKey.string(from: date)).jsonl")
    }

    private func dailyScreenshotsDirectory(for date: Date) -> URL? {
        guard let baseDir = clickyApplicationSupportDirectory() else { return nil }
        let screenshotsDir = baseDir.appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent(dateFormatterDailyKey.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        return screenshotsDir
    }

    private func obsidianDailyMarkdownURL(for date: Date) -> URL {
        let folderURL = URL(fileURLWithPath: Self.obsidianTranscriptsFolderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent("\(dateFormatterDailyKey.string(from: date)).md")
    }

    /// Save raw JPEG bytes for a single screenshot frame. Returns the
    /// RELATIVE path (inside ~/Library/Application Support/Clicky) to
    /// store in the JSONL log, OR nil if the save failed.
    func saveScreenshotJPEG(
        _ data: Data,
        forInteractionId id: String,
        frameIndex: Int,
        timestamp: Date
    ) -> String? {
        guard let dailyDir = dailyScreenshotsDirectory(for: timestamp) else { return nil }
        let filename = "\(dateFormatterFilenameTime.string(from: timestamp))-\(id)-frame\(frameIndex).jpg"
        let fileURL = dailyDir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
        } catch {
            print("⚠️ TranscriptLogger: screenshot save failed: \(error)")
            return nil
        }
        return "screenshots/\(dateFormatterDailyKey.string(from: timestamp))/\(filename)"
    }

    /// Append the interaction to today's JSONL file AND today's Obsidian
    /// markdown file. Idempotent on retry — both files are append-only.
    func log(_ interaction: ClickyInteractionLog) {
        appendToDailyJSONL(interaction)
        appendToObsidianMarkdown(interaction)
    }

    private func appendToDailyJSONL(_ interaction: ClickyInteractionLog) {
        guard let jsonlURL = dailyTranscriptJSONLURL(for: interaction.timestamp) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [] // single-line JSON per row
        guard let jsonData = try? encoder.encode(interaction) else { return }
        var line = jsonData
        line.append(0x0A) // newline byte
        do {
            if FileManager.default.fileExists(atPath: jsonlURL.path) {
                let handle = try FileHandle(forWritingTo: jsonlURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: jsonlURL)
            }
        } catch {
            print("⚠️ TranscriptLogger: JSONL append failed: \(error)")
        }
    }

    private func appendToObsidianMarkdown(_ interaction: ClickyInteractionLog) {
        let markdownURL = obsidianDailyMarkdownURL(for: interaction.timestamp)
        let timeString = dateFormatterTimeOfDay.string(from: interaction.timestamp)
        let appSuffix = (interaction.appName.flatMap { $0.isEmpty ? nil : $0 }).map { " (\($0))" } ?? ""

        var sectionLines: [String] = []
        sectionLines.append("## \(timeString) — \(interaction.mode.displayLabel)\(appSuffix)")
        sectionLines.append("")

        if let raw = interaction.rawTranscript, !raw.isEmpty {
            sectionLines.append("**Said:** \(raw)")
            sectionLines.append("")
        }
        // v15n: Always show Pasted block for VTT/polish modes so we can
        // see what actually went out, even if it's identical to the raw
        // transcript. Suppressing the block when final==raw was hiding
        // silent polish failures (the fallback IS the raw text, so they
        // looked indistinguishable from "perfectly clean transcript").
        let isVoiceMode: Bool
        switch interaction.mode {
        case .vttHold, .vttToggle, .polish:
            isVoiceMode = true
        default:
            isVoiceMode = false
        }
        let shouldShowPasted: Bool = {
            guard let final = interaction.finalOutput, !final.isEmpty else { return false }
            if isVoiceMode { return true }
            return final != interaction.rawTranscript
        }()
        if shouldShowPasted, let final = interaction.finalOutput {
            sectionLines.append("**Pasted:**")
            sectionLines.append("")
            for line in final.split(separator: "\n", omittingEmptySubsequences: false) {
                sectionLines.append("> \(line)")
            }
            sectionLines.append("")
        }
        if let claude = interaction.claudeResponse, !claude.isEmpty {
            sectionLines.append("**Clicky said:** \(claude)")
            sectionLines.append("")
        }
        if let modifier = interaction.polishModifier, !modifier.isEmpty {
            sectionLines.append("**Polish modifier:** \(modifier)")
            sectionLines.append("")
        }
        // v15n: surface polish/repunctuate outcome so silent failures
        // are visible. Only annotate non-OK outcomes to keep the log
        // readable for the common success case.
        if let status = interaction.polishStatus,
           !status.isEmpty,
           status != "ok" {
            let icon = status.hasPrefix("failed") ? "⚠️" : "ℹ️"
            sectionLines.append("\(icon) **Polish status:** `\(status)`")
            sectionLines.append("")
        }
        if !interaction.screenshotPaths.isEmpty {
            sectionLines.append("*\(interaction.screenshotPaths.count) screenshot(s) saved locally*")
            sectionLines.append("")
        }
        sectionLines.append("---")
        sectionLines.append("")

        let section = sectionLines.joined(separator: "\n")

        do {
            if FileManager.default.fileExists(atPath: markdownURL.path) {
                let handle = try FileHandle(forWritingTo: markdownURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = section.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                let header = "# Clicky Transcript — \(dateFormatterDailyKey.string(from: interaction.timestamp))\n\n"
                try (header + section).write(to: markdownURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("⚠️ TranscriptLogger: Obsidian markdown append failed: \(error)")
        }
    }

    /// Convenience helper to mint a fresh interaction id (8-char hex).
    static func newInteractionId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8).description
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    /// v15p3v (2026-05-09): live partial transcript from VTT/dictation
    /// sessions, mirrored from BuddyDictationManager. SwiftUI overlays
    /// observe this to show words as they're being recognized — gives
    /// Steph live confidence the mic + STT are working and lets him
    /// catch a misheard word mid-flight without committing to release.
    @Published private(set) var vttLiveTranscript: String = ""
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// v16qc (2026-06-06): transient "✓ Saved" badge shown in the notch
    /// pill after a Marin memory write. Confirmation is SILENT + VISUAL:
    /// code-played chimes are banned during realtime sessions (v15p4dk —
    /// audio collides with Gemini Live and hangs the notch voiceState)
    /// and Steph vetoed spoken acks 2026-06-06 (tone comes out wrong).
    @Published var memorySaveBadge: String?
    /// v16qj (2026-06-14): which destination the badge represents, so the
    /// notch can color it (memory / reminder / clickup / done / forget).
    @Published var memorySaveBadgeKind: String?
    private var memorySaveBadgeClearTask: Task<Void, Never>?
    private var memorySavedObserver: NSObjectProtocol?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    // v15p3bu (2026-05-13): Deepgram provider for the Fn+Opt A/B test
    // hotkey. Same shape as the default AssemblyAI provider — used as
    // a per-session override when handleVoiceToTextDeepgramTransition
    // fires, otherwise dormant. No bandwidth/token cost when unused.
    private let deepgramTranscriptionProvider = DeepgramStreamingTranscriptionProvider()
    // v15p3hx (2026-05-19): unified VTT provider switching — AssemblyAI
    // joins Deepgram on the same Fn+Ctrl hotkey, selectable from the
    // panel. Old Fn+Shift+Opt AssemblyAI-hold path retired.
    // v15p3hy (2026-05-19): Parakeet parked — OSS WhisperKit didn't
    // ship Parakeet TDT.
    // v15p4bm (2026-05-29): UNPARKED via FluidAudio Swift SDK.
    // Parakeet TDT v2 (English-only, highest recall) runs fully local
    // on the Apple Neural Engine. ~600MB model downloaded on first
    // use, cached forever after. Zero API cost.
    private let assemblyAITranscriptionProvider = AssemblyAIStreamingTranscriptionProvider()
    private let parakeetTranscriptionProvider = ParakeetStreamingTranscriptionProvider()
    // v16 (2026-06-04): ElevenLabs Scribe v2 Realtime — STT bake-off entrant.
    private let scribeTranscriptionProvider = ScribeStreamingTranscriptionProvider()

    /// User-selected VTT provider. Persisted to UserDefaults. Reads
    /// the key on every call so panel toggles take effect immediately.
    /// Default "deepgram" preserves prior behavior. Values: "deepgram"
    /// / "scribe" / "parakeet".
    @AppStorage("clicky.vtt.provider") private(set) var selectedVTTProvider: String = "deepgram"

    /// Returns the provider instance matching the current selection.
    /// Falls back to Deepgram if the stored value is unrecognized.
    fileprivate var activeVTTProvider: any BuddyTranscriptionProvider {
        switch selectedVTTProvider {
        case "scribe": return scribeTranscriptionProvider
        case "parakeet": return parakeetTranscriptionProvider
        default: return deepgramTranscriptionProvider
        }
    }
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.sapierso.workers.dev"

    // MARK: - Obsidian-backed memory (single source of truth)
    //
    // Clicky reads two files from Steph's Obsidian vault on every API call
    // and sends their contents as `personalFacts` to the Worker. The Worker
    // injects them into every system prompt alongside the static memory
    // block. This makes Clicky's memory live in Obsidian — same place Steph
    // already manages it for Cowork — with NO parallel state.
    //
    // v13a (2026-04-29): switched the primary file from `About Me.md` to a
    // dedicated `Clicky Profile.md`. The full About Me.md is ~65KB / 16K
    // tokens, which ballooned every voice call (the v6 revert reason).
    // Clicky Profile.md is a lean voice-optimized profile (~3-5KB) curated
    // for short bursty Clicky calls. About Me.md stays as Cowork's
    // long-form identity doc; it's no longer read by Clicky.
    //
    // Files read (both optional; missing files are silently skipped):
    //   • Claude Memory/Clicky Profile.md  → Steph's identity, role, team,
    //     tools, preferences, condensed for voice. Steph maintains this
    //     manually + a Phase 1B scheduled task will propose periodic small
    //     updates from recent transcripts.
    //   • Claude Memory/Facts.md           → micro-facts (relationships,
    //     prefs, decisions). Same file Cowork reads.
    //
    // Why fresh-read every call instead of caching: files are small (<10KB),
    // local-disk reads are sub-millisecond, and skipping the cache eliminates
    // an entire class of "Clicky's memory is stale because the cache didn't
    // invalidate" bugs. The Worker prompt-caches the contents on the
    // Anthropic side so repeated calls within a 5-minute window pay 0.1×
    // input cost on the memory portion.

    private static let obsidianClaudeMemoryDirectoryPath =
        "/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Claude Memory"
    private static let obsidianClickyProfileFileName = "Clicky Profile.md"
    private static let obsidianFactsFileName = "Facts.md"

    /// v15k: timestamp captured at VTT hotkey release. Read at paste
    /// time to compute end-to-end latency for the timing diagnostic.
    /// Static so it survives across the various closures in the VTT
    /// pipeline without needing to thread state through.
    static var lastVTTReleaseTimestamp: Date?

    /// v15k: file-based timing log for VTT sessions. One line per
    /// session: indicator style, elapsed ms, char count, mode.
    /// Tail with: tail -f /tmp/clicky_vtt_timing.log
    static func appendVTTTimingDiag(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/clicky_vtt_timing.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// v15p4ck (2026-05-30): unified VTT output log — one line per paste
    /// from EVERY provider (Parakeet/Deepgram/AssemblyAI), so engine A/B
    /// runs are gradeable from a single file regardless of which engine
    /// produced the text. Tail with: tail -f /tmp/clicky_vtt_output.log
    static func appendVTTOutputDiag(provider: String, text: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] provider=\(provider)\n  OUT: \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/clicky_vtt_output.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// UserDefaults key from the v5 persistent-facts era. Contents are
    /// migrated to `Claude Memory/Facts.md` on first launch after this
    /// ship and the key is then cleared so the migration is idempotent.
    private static let legacyClickyPersistentFactsUserDefaultsKey = "clickyPersistentFacts"

    /// Read both Obsidian memory files and return their concatenated
    /// contents, ready to send as `personalFacts` to the Worker. Each
    /// file's contents are wrapped with a labeled header so Claude can
    /// distinguish identity-level context (About Me) from per-fact
    /// micro-context (Facts).
    ///
    /// Returns an empty string if neither file exists or both are
    /// empty — caller can then pass `personalFacts: nil` (or empty),
    /// and the Worker's injection step will silently skip the block.
    private static func loadCurrentObsidianMemoryContents() -> String {
        var combinedSections: [String] = []

        // Hard size cap per file (chars, not tokens — rough proxy). Anything
        // larger gets truncated at this boundary with a logged warning. The
        // cap exists to make the v6 mistake (sending the whole 65KB About Me.md)
        // structurally impossible. ~8000 chars ≈ ~2000 tokens — comfortably
        // covers a curated Clicky Profile.md without bloating the request.
        // Combined with Facts.md (capped separately), worst case is ~16000
        // chars / ~4000 tokens of memory per request, fully prompt-cached.
        let memoryFileMaxChars = 8000

        let clickyProfileFilePath = "\(obsidianClaudeMemoryDirectoryPath)/\(obsidianClickyProfileFileName)"
        if let clickyProfileContents = try? String(contentsOfFile: clickyProfileFilePath, encoding: .utf8) {
            var trimmedClickyProfileContents = clickyProfileContents.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedClickyProfileContents.count > memoryFileMaxChars {
                let truncationIndex = trimmedClickyProfileContents.index(
                    trimmedClickyProfileContents.startIndex,
                    offsetBy: memoryFileMaxChars
                )
                trimmedClickyProfileContents = String(trimmedClickyProfileContents[..<truncationIndex])
                print("⚠️ ObsidianMemory: Clicky Profile.md exceeds \(memoryFileMaxChars) chars — truncating. Trim the file in Obsidian.")
            }
            if !trimmedClickyProfileContents.isEmpty {
                combinedSections.append(
                    "## About Steph (from Obsidian: Claude Memory/Clicky Profile.md)\n\n\(trimmedClickyProfileContents)"
                )
            }
        }

        let factsFilePath = "\(obsidianClaudeMemoryDirectoryPath)/\(obsidianFactsFileName)"
        if let factsContents = try? String(contentsOfFile: factsFilePath, encoding: .utf8) {
            var trimmedFactsContents = factsContents.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedFactsContents.count > memoryFileMaxChars {
                let truncationIndex = trimmedFactsContents.index(
                    trimmedFactsContents.startIndex,
                    offsetBy: memoryFileMaxChars
                )
                trimmedFactsContents = String(trimmedFactsContents[..<truncationIndex])
                print("⚠️ ObsidianMemory: Facts.md exceeds \(memoryFileMaxChars) chars — truncating. Trim the file in Obsidian.")
            }
            if !trimmedFactsContents.isEmpty {
                combinedSections.append(
                    "## Specific Facts & Preferences (from Obsidian: Claude Memory/Facts.md)\n\n\(trimmedFactsContents)"
                )
            }
        }

        return combinedSections.joined(separator: "\n\n")
    }

    /// One-time migration of v5-era persistent-facts data from
    /// UserDefaults into `Claude Memory/Facts.md`. Runs on app launch.
    /// Idempotent: only writes if Facts.md does NOT already exist
    /// (Steph may have already populated it manually) and only if
    /// UserDefaults actually has data. Clears the UserDefaults key
    /// after a successful write so subsequent launches no-op.
    private static func migrateLegacyClickyPersistentFactsToObsidianFactsFile() {
        let userDefaultsFactsContents = UserDefaults.standard
            .string(forKey: legacyClickyPersistentFactsUserDefaultsKey) ?? ""
        let trimmedUserDefaultsFactsContents = userDefaultsFactsContents
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserDefaultsFactsContents.isEmpty else {
            // Nothing to migrate.
            return
        }

        let factsFilePath = "\(obsidianClaudeMemoryDirectoryPath)/\(obsidianFactsFileName)"
        if FileManager.default.fileExists(atPath: factsFilePath) {
            // Don't overwrite an existing Facts.md — Steph may have
            // already curated it. Leave UserDefaults intact too in case
            // he wants to reconcile manually.
            print("📚 ObsidianMemory: Facts.md already exists; skipping UserDefaults migration")
            return
        }

        // Make sure the parent directory exists. It almost certainly
        // does (Steph's vault has it), but being defensive.
        let parentDirectoryURL = URL(fileURLWithPath: factsFilePath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentDirectoryURL,
            withIntermediateDirectories: true
        )

        // Write a small header comment at the top so the migration is
        // auditable and Steph knows where this file came from.
        let migrationHeaderComment = """
            <!-- Migrated from Clicky+ v5 persistent-facts UserDefaults on 2026-04-26.
                 Each line below was a fact Clicky extracted from a [REMEMBER:]
                 marker during v5 testing, before we pivoted to Obsidian-backed
                 memory. Edit, reorganize, or delete entries freely — Clicky
                 reads this file fresh on every API call. -->
            """
        let factsFileContents = "\(migrationHeaderComment)\n\n\(trimmedUserDefaultsFactsContents)\n"

        do {
            try factsFileContents.write(toFile: factsFilePath, atomically: true, encoding: .utf8)
            UserDefaults.standard.removeObject(forKey: legacyClickyPersistentFactsUserDefaultsKey)
            print("📚 ObsidianMemory: migrated v5 UserDefaults clickyPersistentFacts → Facts.md (\(trimmedUserDefaultsFactsContents.count) chars)")
        } catch {
            print("⚠️ ObsidianMemory: migration to Facts.md failed: \(error)")
        }
    }

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var ttsClient: any TTSClient = {
        return TTSClientFactory.make(workerBaseURL: Self.workerBaseURL)
    }()

    /// Conversation history so Claude remembers prior exchanges. Persisted to
    /// disk so continuity survives app restarts.
    private var conversationHistory: [ConversationEntry] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    // v15p3fr (2026-05-17): Watch mode frame-capture timer.
    // Fires every 0.5s while Fn+Opt is held — captures the primary
    // display as JPEG and forwards to GeminiRealtimeConversationManager
    // .sendVideoFrame. Reset on release.
    private var videoWatchFrameTimer: Timer?
    /// v15p3fr (2026-05-17): set to true at Watch-mode .pressed and
    /// cleared at the END of the response delivery (callback runs).
    /// Used to suppress duplicate engages if the user presses again
    /// mid-response (Watch is single-turn).
    /// v15p3fw (2026-05-17): @Published so OverlayWindow can observe
    /// it and keep the red cursor tint through the post-release
    /// response phase (otherwise magenta wins for 1-2s).
    @Published private(set) var isVideoWatchResponseInFlight: Bool = false
    /// v15p3fs (2026-05-17): safety net — if Gemini never returns
    /// turnComplete after activity_end (WS hang, server error, malformed
    /// setup), we'd otherwise be stuck with isVideoWatchResponseInFlight
    /// true and the next press blocked. This task fires 15s after the
    /// hotkey release and force-clears state.
    private var videoWatchResponseTimeoutTask: Task<Void, Never>?
    /// v15p3fy (2026-05-17): tap-vs-hold detection state.
    /// Press timestamp lets .released compute elapsed-since-press and
    /// classify the gesture as tap (<350ms) or hold (≥350ms). Toggle-
    /// locked flag tracks whether a prior tap engaged the session;
    /// while it's true, a subsequent press is the start of a disengage
    /// gesture rather than a new engage.
    private var videoWatchPressTimestamp: Date?
    @Published private(set) var isVideoWatchToggleLocked: Bool = false
    private static let videoWatchTapThresholdSeconds: TimeInterval = 0.35

    private var shortcutTransitionCancellable: AnyCancellable?
    private var burstTransitionCancellable: AnyCancellable?
    private var typingTransitionCancellable: AnyCancellable?
    private var voiceToTextTransitionCancellable: AnyCancellable?
    private var captureToInboxTransitionCancellable: AnyCancellable?
    private var realtimeTransitionCancellable: AnyCancellable?
    // v15p3fq (2026-05-17): realtimeHandsFreeToggleCancellable removed.
    // The Fn+Shift+Opt single-tap hands-free Marin engage was already
    // disabled in v15p3bf (Steph confirmed unused). The chord is now
    // repurposed for AssemblyAI VTT hold-only (driven by the existing
    // burstTransitionPublisher, which also fires on Fn+Shift+Opt).
    // Double-tap Option remains the primary Marin hands-free engage —
    // unchanged by this swap.
    private var polishHotkeyTransitionCancellable: AnyCancellable?

    /// v15p2 (2026-05-02): hands-free Realtime toggle state, persisted
    /// across launches. UserDefaults source of truth so the flag
    /// outlives sessions and Mac restarts. Toggled by Fn+Cmd+Opt.
    @Published var isRealtimeHandsFreeEnabled: Bool = UserDefaults.standard
        .bool(forKey: "clicky.realtimeHandsFreeEnabled") {
        didSet {
            UserDefaults.standard.set(
                isRealtimeHandsFreeEnabled,
                forKey: "clicky.realtimeHandsFreeEnabled"
            )
        }
    }

    /// Realtime conversation manager (v15p2, OpenAI Realtime API).
    /// Lazily created on first hotkey press so its setup cost doesn't
    /// hit app boot.
    private var realtimeManager: RealtimeConversationManager?
    // v16 (2026-06-04): Apple Speech on-device wake word ("Marin").
    private var speechWakeWordManager: SpeechWakeWordManager?
    private var wakeWordGateTimer: Timer?
    // v16pj (2026-06-04): PARKED — Apple-Speech wake word works but isn't worth it
    // for desk use (hotkey toggle is already low-friction; detection has deaf gaps;
    // activation delay is Marin's cold-start). Flip to true / `defaults write
    // com.stephenpierson.clickyplus clicky.wakeword.enabled -bool true` to re-enable.
    @AppStorage("clicky.wakeword.enabled") private var wakeWordEnabled: Bool = false
    private var realtimeManagerStateCancellable: AnyCancellable?

    /// v15p3di (2026-05-16): parallel Gemini Live provider for Marin.
    /// User-selectable via the "Marin provider" panel toggle. Lazily
    /// created the first time a Realtime session opens AFTER the
    /// toggle has been set to .gemini. Lifecycle mirrors the OpenAI
    /// manager — same startSession/endSession surface, same state
    /// enum, same Published property names so binding code can be
    /// reused with minimal branching.
    private var geminiRealtimeManager: GeminiRealtimeConversationManager?
    private var geminiRealtimeManagerStateCancellable: AnyCancellable?
    private var geminiRealtimeInputAudioLevelCancellable: AnyCancellable?

    // v15p3gv (2026-05-18): listen-only-when-Marin-active monitor that
    // captures mouse side button presses (any button >= 3) AND caps
    // lock as "advance to the next step" cues during a guidance flow.
    // Lets Steph progress through Marin's step-by-step instructions
    // without having to say "done" or "next" every time. Owned for
    // the lifetime of CompanionManager; gated by setMarinActive().
    private var marinAdvanceInputMonitor: MouseSideButtonMonitor?
    private var marinAdvanceInputCancellable: AnyCancellable?

    /// Persisted picker value. "openai" or "gemini". Defaults to OpenAI
    /// so existing users see no behavior change on upgrade.
    @AppStorage("marin.provider") private(set) var marinProvider: String = "openai"
    var marinUsingGemini: Bool { marinProvider == "gemini" }

    /// v15p2 (2026-05-03): Marin's input audio level mirrored into
    /// CompanionManager so indicators can be voice-reactive while
    /// she's listening. Replaces the pink-flat-line bug.
    @Published private(set) var realtimeInputAudioLevel: CGFloat = 0
    private var realtimeInputAudioLevelCancellable: AnyCancellable?
    // v15p3fa (2026-05-17): mirror the output audio level into a
    // @Published property so the OverlayWindow can detect whether
    // Marin is currently audibly speaking (vs just generating).
    // Used to hide the "spinner stuck on" visual during her playback —
    // the dot pulses with her voice instead.
    @Published private(set) var realtimeOutputAudioLevel: CGFloat = 0
    private var realtimeOutputAudioLevelCancellable: AnyCancellable?
    private var geminiOutputAudioLevelCancellable: AnyCancellable?

    /// v15p3ff (2026-05-17): sticky "Marin started audibly speaking
    /// this turn" flag, bound from the Gemini manager. OverlayWindow
    /// uses this to hide the spinner during her speech without the
    /// oscillation problem of comparing instantaneous output level
    /// to a threshold (her audio fluctuates above/below every frame).
    /// True from first audio chunk per turn until turn end.
    @Published private(set) var realtimeMarinAudioStarted: Bool = false
    private var geminiMarinAudioStartedCancellable: AnyCancellable?

    /// v15p2 (2026-05-03): Marin's session state, exposed so the
    /// indicator can pick `.listening` mode (audio-reactive halo)
    /// vs `.idle` (solid line) vs `.processing` (heartbeat pulse).
    /// The legacy `voiceState` tracks buddyDictationManager and is
    /// always `.idle` during Marin sessions.
    @Published private(set) var realtimeSessionState: RealtimeSessionState = .idle

    /// v15p2 (2026-05-03): Marin's live transcripts mirrored for the
    /// panel's transcript view. Both stream in real time as the
    /// turn unfolds. Cleared at end of turn.
    @Published private(set) var realtimeUserTranscript: String = ""
    @Published private(set) var realtimeAssistantTranscript: String = ""
    private var realtimeUserTranscriptCancellable: AnyCancellable?
    private var realtimeAssistantTranscriptCancellable: AnyCancellable?

    /// v15p2 (2026-05-03): rolling log of completed Marin turns in
    /// the current session, mirrored from RealtimeConversationManager.
    /// Cleared on cold session start.
    @Published private(set) var realtimeCompletedTurns: [RealtimeTurn] = []
    private var realtimeCompletedTurnsCancellable: AnyCancellable?

    /// v15p2 (2026-05-03): timestamp of last Esc handled for Realtime
    /// double-tap detection (force-end on second press within 1.5s).
    private var lastEscapeKeyForRealtime: Date?

    /// v15p2 (2026-05-03): refcount of other-mode chords currently
    /// held while a Marin session is active. When this goes from 0→1
    /// we suspend Marin (mute mic, cancel response, stop TTS). When
    /// it goes from 1→0 we resume. Tracked separately per mode-class
    /// so a release of one mode doesn't accidentally clear the count
    /// while another is still held.
    private var otherModeChordsHeld: Set<String> = []

    /// v15p2 (2026-05-03): mirror of `!otherModeChordsHeld.isEmpty`,
    /// published so OverlayWindow can let the other-mode tint win
    /// over magenta while Marin is suspended. Without this, the
    /// cursor stays magenta during VTT/Typing/etc. and Steph loses
    /// the color cue that he's hitting the right hotkey.
    @Published private(set) var isRealtimeSuspendedByOtherMode: Bool = false
    /// Subscriptions for double-tap engage / single-tap disengage toggles
    /// (v11f + v11g): Ctrl/Cmd alone double-tap LOCKS VTT/typing on,
    /// single-tap or Esc UNLOCKS. Held continuously while CompanionManager lives.
    private var controlDoubleTapCancellable: AnyCancellable?
    private var commandDoubleTapCancellable: AnyCancellable?
    private var optionDoubleTapCancellable: AnyCancellable?
    /// v15p3gt (2026-05-18): double-tap Shift engages speed-read mode.
    private var shiftDoubleTapCancellable: AnyCancellable?
    /// Speed-read overlay manager. Lazily created on first use so the
    /// NSPanel isn't allocated for users who never invoke speed-read.
    private var speedReadOverlayManager: SpeedReadOverlayManager?
    private var controlSingleTapCancellable: AnyCancellable?
    private var commandSingleTapCancellable: AnyCancellable?
    private var optionSingleTapCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    /// v13e (2026-04-30): the current PTT session's streaming-TTS state, if
    /// any. Promoted from a local in `sendTranscriptToClaudeWithScreenshot`
    /// to an instance property so Esc can kill the entire pipeline at once
    /// (finish the task continuation + cancel the player-loop task) rather
    /// than only the currently-playing chunk. The player loop is an
    /// unstructured `Task { ... }` that doesn't inherit cancellation from
    /// `currentResponseTask`, so it has to be cancelled directly.
    /// Cleared in a `defer` when the response Task ends.
    private var currentStreamingState: StreamingMultiSentenceState?
    /// Whether VTT/typing/voice-mode are currently locked-on via double-tap.
    /// Mutually exclusive — only one can be true at a time.
    private var isVoiceToTextToggleLocked: Bool = false
    private var isTypingToggleLocked: Bool = false
    /// v12s: hands-free base voice mode engaged via double-tap Option.
    /// While true, click-to-capture is armed and the user can click freely
    /// (no modifiers held → clicks work normally). Single-tap Opt or Esc
    /// disengages and sends the captured frames + transcript to Claude.
    private var isVoiceModeToggleLocked: Bool = false
    private var nativeScreenshotSessionCancellable: AnyCancellable?
    /// v15p4p (2026-05-23): subscriber for Cmd+Shift+2 screenshot-and-paste.
    private var screenshotPasteCancellable: AnyCancellable?
    /// v15p4t (2026-05-23): tracks whether Marin has an active helper
    /// sub-agent running. Set true on `.marinHelperStateChanged` notification
    /// (active=true) and false on (active=false). Used by NotchPanelManager
    /// to flip the pill to "Researching" (blue) so Steph can visually
    /// distinguish "Marin is thinking" from "Marin spun off a sub-agent
    /// that's doing real multi-step work."
    @Published private(set) var isHelperSubAgentActive: Bool = false
    private var helperStateObserver: NSObjectProtocol?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var vttLiveTranscriptCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var pendingBurstShortcutStartTask: Task<Void, Never>?
    private var pendingTypingShortcutStartTask: Task<Void, Never>?
    private var pendingVoiceToTextShortcutStartTask: Task<Void, Never>?
    /// v15p3bu (2026-05-13): pending start task for the Deepgram A/B
    /// test mode (Fn+Opt). Parallel to pendingVoiceToTextShortcutStartTask
    /// so the two modes never interfere with each other's lifecycle.
    private var pendingDeepgramVTTShortcutStartTask: Task<Void, Never>?
    /// Screenshot captured at VTT toggle engage time (v12). Used as vision
    /// input to polish for tone-matching the destination app, and saved to
    /// the transcript log for memory-scan visual context. Cleared on submit.
    private var vttToggleEngagementScreenshot: CompanionScreenCapture?
    /// Safety-net task that fires 10s after VTT release. Force-clears state
    /// if the spinner is still stuck on .processing — see handleVoiceToTextTransition
    /// .released for why. Cancelled when a new VTT session starts.
    private var stuckSpinnerSafetyNetTask: Task<Void, Never>?
    /// Continuous voiceState watchdog (v11p). Scheduled whenever voiceState
    /// becomes .processing; cancelled whenever it leaves. Replaces the
    /// per-session safety net for robustness — catches hangs during startup,
    /// transcription, repunctuate, polish, or paste.
    private var voiceStateWatchdogTask: Task<Void, Never>?
    /// General-purpose cancellable set for subscriptions that don't have a
    /// dedicated property. Used by the voiceState watchdog.
    private var cancellableSet: Set<AnyCancellable> = []
    private var pendingCaptureToInboxShortcutStartTask: Task<Void, Never>?
    private var captureToInboxToastDismissTask: Task<Void, Never>?
    private var pendingPolishCommandTask: Task<Void, Never>?
    /// Polish hotkey tap-vs-hold tracking. The press timestamp lets us
    /// classify the gesture on release: short = tap = polish without
    /// modifier; long = hold = engaged dictation for spoken modifier.
    private var polishHotkeyPressedAt: Date?
    private var isPolishHotkeyHeld: Bool = false
    /// True once the hold threshold has fired and dictation is engaged
    /// for spoken modifier capture. Distinct from `isPolishHotkeyHeld`
    /// because the user can be holding without yet having crossed the
    /// threshold (during the first ~300ms of the hold).
    private var isPolishHotkeyDictatingForModifier: Bool = false
    private var polishHotkeyHoldEngageTask: Task<Void, Never>?
    /// v15p2 hotfix (2026-05-04): set true after the tap-vs-hold
    /// threshold elapses while the hotkey is still held. Used by
    /// the release handler to decide between tap (instant polish)
    /// and hold (use captured modifier) paths. Replaces the older
    /// "did dictation engage" check, which forced a 300ms wait
    /// before audio capture started and clipped the first word.
    private var polishHotkeyHoldThresholdPassed: Bool = false
    /// v15p2 hotfix (2026-05-04, QA #2): set true when the tap
    /// release-path cancels the dictation. The submitDraftText
    /// closure checks this and bails out — without it, the closure
    /// could still fire (cancellation isn't synchronous through the
    /// transcription pipeline) and apply the partial 50-150ms of
    /// audio as a polish modifier in addition to the instant-polish
    /// from the release path. Net effect on tap: polish ran twice.
    private var polishHotkeyDictationWasCancelled: Bool = false
    private var pendingPolishHotkeyDictationTask: Task<Void, Never>?

    /// Screenshot burst mode state (Fn+Ctrl+Opt).
    /// Additive — fully isolated from the normal push-to-talk pipeline.
    @Published private(set) var isBurstModeActive: Bool = false
    /// True from burst-press through Claude response delivery (i.e.
    /// covers BOTH the capture phase and the processing phase). The
    /// reason this exists distinct from `isBurstModeActive`: the capture
    /// flag is cleared right after the final-frame screenshot lands
    /// (~100ms after release), but the processing/spinner phase that
    /// follows still needs to know "the user just did burst" so the
    /// spinner renders in red instead of falling back to default blue.
    /// Set on burst press; cleared when the burst response cycle
    /// returns voiceState to idle (or on cancellation).
    @Published private(set) var isBurstResponseCycleInFlight: Bool = false
    /// Timestamp of the most recent burst-frame capture. Fires on every
    /// successful screenshot grab (1 Hz ticks + final-on-release) so the
    /// overlay waveform can flash a camera-style white pulse in sync.
    @Published var lastScreenshotCaptureAt: Date?
    private var burstCaptureTimer: Timer?
    private var burstCapturedFrames: [CompanionScreenCapture] = []
    /// The "final frame" capture kicked off at the moment of key release.
    /// The submit callback awaits this task so the very last frame (whatever
    /// the user was looking at when they let go) is guaranteed to be
    /// included — even if it falls between 1-second timer ticks.
    private var finalBurstCaptureTask: Task<Void, Never>?

    // MARK: - v12r: Voice-Mode Click-to-Capture state
    //
    // While base PTT (Claude voice mode) is engaged, every left-click the
    // user makes captures a pair of screenshots: one immediately (pre-state)
    // and one ~350ms later (post-state). The post-frame catches any UI
    // reaction (page load, modal open, dropdown expand). Pre/post pairs are
    // deduped at send time when the screen didn't actually change.
    //
    // Frames + click coords + pre/post tags are bundled with the final
    // all-screen baseline and the voice transcript when sent to Claude,
    // giving the model rich step-by-step context about what the user was
    // doing across the session.
    struct VoiceModeClickFrame {
        let imageData: Data
        let widthInPixels: Int
        let heightInPixels: Int
        let clickPoint: CGPoint
        let isPostClick: Bool
        let timestamp: Date
    }
    private var voiceModeClickFrames: [VoiceModeClickFrame] = []
    private var voiceModeClickGlobalMonitor: Any?
    private var voiceModeClickLocalMonitor: Any?
    /// Cap so a long voice-mode session that involves many rapid clicks
    /// doesn't balloon the request payload. 24 frames = up to 12 click
    /// pairs (without dedup), comfortably under Claude's image cap.
    private static let voiceModeClickFramesCap = 24
    /// Delay between the pre-click capture and the post-click capture.
    /// 350ms is long enough for most UI reactions (page navs, modal opens,
    /// dropdown expansions) but short enough to feel snappy.
    private static let voiceModePostClickDelayNanos: UInt64 = 350_000_000
    /// JPEG byte-length proximity threshold for dedup. If the post-click
    /// frame is within this fraction of the pre-click frame's size, AND
    /// the first 256 bytes match, we treat them as identical and drop
    /// the post-click frame. Cheap heuristic — JPEG of identical scenes
    /// produces near-identical byte counts.
    private static let voiceModeClickDedupSizeThreshold: Double = 0.005   // 0.5%
    private static let burstMaxFrames: Int = 10
    private static let burstCaptureIntervalSeconds: TimeInterval = 1.0

    /// Typing mode state (Fn + Cmd). While held, Clicky listens to voice
    /// and grabs a single screenshot of what's on screen. On release, the
    /// transcript + screenshot are sent to Claude, and Claude's reply is
    /// pasted into whatever field has focus (via clipboard + Cmd+V).
    /// Fully isolated from normal PTT and burst — own publisher, own
    /// handler, own system prompt.
    @Published private(set) var isTypingModeActive: Bool = false
    /// Screenshot taken at the moment typing mode was engaged. Cleared
    /// after the response is pasted (or if the interaction is aborted).
    private var typingModeScreenshot: CompanionScreenCapture?
    /// Accessibility context (focused element's app / role / label /
    /// recent text / frame) captured at the same moment as the
    /// screenshot. Passed into the LLM prompt so Claude can match
    /// the destination's tone + format precisely. Cleared after use.
    private var typingModeFocusedContext: FocusedElementContext?

    /// Voice-to-text mode state (Fn + Shift). While held, Clicky
    /// streams audio through AssemblyAI; on release, the final
    /// transcript is pasted into the focused field via the shared
    /// clipboard helper. Pure transcription — no Claude, no TTS,
    /// no conversation history. Fully isolated from normal PTT,
    /// burst, and typing modes.
    @Published private(set) var isVoiceToTextModeActive: Bool = false
    /// v15p3bu (2026-05-13): true while the Deepgram VTT chord is held.
    /// Same paste-only semantics as the AssemblyAI VTT path but the
    /// transcription provider is Deepgram Nova-3 instead.
    /// v15p3fq (2026-05-17): chord is Fn+Ctrl (since v15p3bw); cursor
    /// indicator color changed from red → purple as part of the Watch
    /// mode rollout that took the red slot for Fn+Opt.
    @Published private(set) var isVoiceToTextDeepgramModeActive: Bool = false
    /// v15p3fq (2026-05-17): true while Fn+Opt is held in the new
    /// Watch mode — screen-frame streaming sub-mode of Marin Gemini.
    /// User holds, narrates what they want described; ScreenCaptureKit
    /// frames pipe into Gemini Live's WS alongside audio at ~2 fps;
    /// on release, Gemini returns a paragraph-level description
    /// focused on whatever the user pointed at (or the most salient
    /// content if no narration). Drives the red cursor indicator so
    /// it's visually obvious this is the video mode, not a VTT mode.
    @Published private(set) var isVideoWatchModeActive: Bool = false
    /// True while Fn+Opt is held. Capture-to-inbox is pure transcription
    /// that appends directly to the user's Obsidian Idea Inbox — no paste,
    /// no Claude, no TTS, no focused-field interaction. Fully isolated
    /// from every other mode.
    @Published private(set) var isCaptureToInboxModeActive: Bool = false
    /// True while a Realtime conversation session is active (Fn+Opt held
    /// or warm session window). Drives the magenta cursor indicator.
    /// v15p2 (2026-05-02).
    /// v15p3he (2026-05-18): didSet propagates the flag to
    /// MouseSideButtonMonitor's gate. Previously gate-flipping only
    /// happened inside the bind*ManagerState closures, so the three
    /// eager `isRealtimeModeActive = true` engagement sites (PTT press,
    /// double-tap-Opt continuous, hands-free toggle) flipped the
    /// magenta cursor but never opened the advance-input gate — middle
    /// click + Left Cmd tap fired with `marinActive=false` every time.
    @Published private(set) var isRealtimeModeActive: Bool = false {
        didSet {
            if oldValue != isRealtimeModeActive {
                MouseSideButtonMonitor.setMarinActive(isRealtimeModeActive)
            }
        }
    }

    /// v15p3bx (2026-05-13): true whenever Clicky+ has any active
    /// mode/state that Esc should cancel. Consulted by the
    /// GlobalPushToTalkShortcutMonitor.shouldConsumeEscapeWhenPressed
    /// closure to decide whether Esc should be eaten at the event tap
    /// (preventing leak to foreground apps like Cowork) or passed
    /// through (so unrelated Esc workflows keep working).
    ///
    /// Conditions covered: any Realtime/Marin state, any VTT mode
    /// (AssemblyAI or Deepgram, hold or toggle), Typing mode, Capture-
    /// to-inbox, any locked toggle, Polish modifier capture, and the
    /// voiceState .responding/.processing windows that signal the
    /// Claude/repunctuate/paste pipeline is mid-flight. If none of
    /// these are true, Esc is none of Clicky's business.
    var clickyHasActiveAction: Bool {
        if isRealtimeModeActive { return true }
        if isVoiceToTextModeActive { return true }
        if isVoiceToTextDeepgramModeActive { return true }
        // v15p3fq (2026-05-17): Watch mode (Fn+Opt) holds Clicky's
        // attention — Esc should cancel it just like other active modes.
        if isVideoWatchModeActive { return true }
        if isTypingModeActive { return true }
        if isCaptureToInboxModeActive { return true }
        if isVoiceToTextToggleLocked { return true }
        if isTypingToggleLocked { return true }
        if isVoiceModeToggleLocked { return true }
        if isPolishHotkeyHeld { return true }
        if isPolishHotkeyModifierCaptureModeActive { return true }
        switch voiceState {
        case .responding, .processing, .listening:
            return true
        default:
            break
        }
        return false
    }

    /// Transcript of the most recent capture-to-inbox append. Drives the
    /// yellow confirmation toast in the overlay. Nil when no toast is
    /// showing; set to the last transcript at write time; cleared ~3s
    /// later by `captureToInboxToastDismissTask`.
    @Published private(set) var recentIdeaCaptureText: String?
    /// True for ~250ms after a polish command fires (either via a quick
    /// ⌃Fn tap or after a hold-and-speak modifier finishes). Drives a
    /// brief flash on the orb so the user has visual confirmation that
    /// polish was triggered.
    @Published private(set) var isPolishCommandFlashActive: Bool = false
    private var polishCommandFlashClearTask: Task<Void, Never>?
    /// True while the polish hotkey has been held past the tap-vs-hold
    /// threshold and dictation is actively capturing the spoken modifier.
    /// Drives the sustained cyan tint on the orb (vs the brief flash
    /// for the tap path), and the waveform overlay during hold.
    @Published private(set) var isPolishHotkeyModifierCaptureModeActive: Bool = false
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// v15p3de (2026-05-15): always returns true so onboarding never
    /// auto-triggers. Steph asked to "get rid of the onboarding" —
    /// rather than ripping out the entire flow (which we may want for
    /// future external users), the getter short-circuits to "completed"
    /// state. The video, music, and demo paths still exist and can be
    /// replayed via "Watch Onboarding Again" in the panel footer.
    /// The setter still writes to UserDefaults so any code that depends
    /// on the persisted value (e.g., welcome-music gates) continues to
    /// work, but no reader of the getter will see false anymore.
    ///
    /// Original docstring:
    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { true }  // v15p3de: always true — onboarding removed
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        loadConversationHistory()
        // One-time migration of v5-era persistent-facts UserDefaults
        // contents into Claude Memory/Facts.md so nothing is lost when
        // we switch to Obsidian-backed memory. Idempotent — only fires
        // if Facts.md doesn't already exist AND UserDefaults still has
        // data. After migration, UserDefaults key is cleared.
        Self.migrateLegacyClickyPersistentFactsToObsidianFactsFile()
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // v16 (2026-06-04): point prewarm at the SELECTED VTT engine so
        // Scribe/Parakeet get warmed (not just the base factory provider).
        buddyDictationManager.activeVTTProviderResolver = { [weak self] in self?.activeVTTProvider }
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // VTT-SPEED Tier 1+2 (v15m, 2026-05-01): warm the Worker TLS
        // session so the first /repunctuate (and /transcribe-token)
        // call after launch skips the ~150-300ms cold TLS handshake.
        // Same pattern ClaudeAPI uses; safe / silent / one-shot.
        Self.warmUpWorkerTLSConnectionIfNeeded()

        // VTT-SPEED v15o (2026-05-01): warm Haiku 4.5 itself by firing
        // a tiny /repunctuate call. Skips the model cold-start tax on
        // the first real VTT after launch (saves ~200-400ms). Fires on
        // a background task so it doesn't block app boot. Still wanted
        // with the local LLM (v16pv) — Haiku remains the fallback path.
        Self.warmUpHaikuModelIfNeeded()

        // v16pv (2026-06-06): start the on-device repunctuate LLM
        // (Rapid-MLX, qwen3.5-4b). Spawns the localhost server and
        // fetches the prompt cache from the Worker. Async; silent on
        // failure (Worker path keeps working as before).
        LocalLLMManager.shared.startIfEnabled(workerBaseURL: Self.workerBaseURL)

        // v16qc (2026-06-06): Marin memory repository — build/sync the
        // on-device vector index (VecturaKit + Apple NL embeddings) in
        // the background, and flash a silent "✓ Saved" notch badge when
        // Marin stores a memory (no chime — v15p4dk; no spoken ack —
        // Steph's call 2026-06-06).
        MarinMemoryStore.shared.launchSync(workerBaseURL: Self.workerBaseURL)
        memorySavedObserver = NotificationCenter.default.addObserver(
            forName: MarinMemoryStore.memorySavedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // v16qj (2026-06-14): badge carries the actual CONTENT text +
            // a `kind` (memory/reminder/clickup/done/forget) the notch
            // colors by — so Steph sees WHAT got saved and WHERE at a
            // glance. Legacy "label"/"updated" kept as a fallback.
            if let text = note.userInfo?["text"] as? String, !text.isEmpty {
                self.memorySaveBadge = text
                self.memorySaveBadgeKind = (note.userInfo?["kind"] as? String) ?? "memory"
            } else {
                let updated = (note.userInfo?["updated"] as? Bool) ?? false
                self.memorySaveBadge = (note.userInfo?["label"] as? String)
                    ?? (updated ? "✓ Updated" : "✓ Saved")
                self.memorySaveBadgeKind = "memory"
            }
            self.memorySaveBadgeClearTask?.cancel()
            self.memorySaveBadgeClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                guard !Task.isCancelled else { return }
                self?.memorySaveBadge = nil
                self?.memorySaveBadgeKind = nil
            }
        }

        // v15p3bk (2026-05-12): pre-open an AssemblyAI streaming
        // session so the first VTT/polish-modifier engage after
        // launch skips the ~1-1.5s websocket handshake (the biggest
        // single latency item from audit §8). Subsequent engages get
        // re-warmed in BuddyDictationManager.finishCurrentDictationSessionIfNeeded.
        // 1.5s delay so this doesn't compete with the TLS warm + Haiku
        // warm above for network bandwidth during app boot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.buddyDictationManager.prewarmTranscriptionProvider()
        }

        // v16 (2026-06-04): Apple Speech wake word — listen for "Marin" while
        // idle and engage Marin hands-free. Gated off during any capture mode
        // (clickyHasActiveAction) for false-trigger prevention + mic arbitration.
        if wakeWordEnabled {
            let wm = SpeechWakeWordManager()
            wm.onWake = { [weak self] in self?.handleOptionDoubleTapForRealtimeHandsFree() }
            wm.isGatedOut = { [weak self] in self?.clickyHasActiveAction ?? true }
            speechWakeWordManager = wm
            startWakeWordGateTimer()
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        burstTransitionCancellable?.cancel()
        typingTransitionCancellable?.cancel()
        voiceToTextTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        burstCaptureTimer?.invalidate()
        burstCaptureTimer = nil
        burstCapturedFrames.removeAll()
        isBurstModeActive = false
        isBurstResponseCycleInFlight = false
        // v12r: tear down voice-mode click-to-capture monitors and buffer.
        if let monitor = voiceModeClickGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            voiceModeClickGlobalMonitor = nil
        }
        if let monitor = voiceModeClickLocalMonitor {
            NSEvent.removeMonitor(monitor)
            voiceModeClickLocalMonitor = nil
        }
        voiceModeClickFrames.removeAll()
        pendingBurstShortcutStartTask?.cancel()
        pendingBurstShortcutStartTask = nil
        finalBurstCaptureTask?.cancel()
        finalBurstCaptureTask = nil
        isTypingModeActive = false
        pendingTypingShortcutStartTask?.cancel()
        pendingTypingShortcutStartTask = nil
        isVoiceToTextModeActive = false
        pendingVoiceToTextShortcutStartTask?.cancel()
        pendingVoiceToTextShortcutStartTask = nil
        captureToInboxTransitionCancellable?.cancel()
        polishHotkeyTransitionCancellable?.cancel()
        pendingCaptureToInboxShortcutStartTask?.cancel()
        pendingCaptureToInboxShortcutStartTask = nil
        pendingPolishCommandTask?.cancel()
        pendingPolishCommandTask = nil
        polishCommandFlashClearTask?.cancel()
        polishCommandFlashClearTask = nil
        isPolishCommandFlashActive = false
        polishHotkeyHoldEngageTask?.cancel()
        polishHotkeyHoldEngageTask = nil
        pendingPolishHotkeyDictationTask?.cancel()
        pendingPolishHotkeyDictationTask = nil
        polishHotkeyPressedAt = nil
        isPolishHotkeyHeld = false
        isPolishHotkeyDictatingForModifier = false
        isPolishHotkeyModifierCaptureModeActive = false
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            installMarinAdvanceInputMonitorIfNeeded()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            marinAdvanceInputMonitor?.stopMonitoring()
            marinAdvanceInputMonitor = nil
            marinAdvanceInputCancellable = nil
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    /// v16: drive the wake-word listener off Clicky's capture state — pause it
    /// (freeing the mic) whenever any capture mode is active, resume when idle.
    /// start()/stop() are idempotent, so polling every 0.5s is safe.
    private func startWakeWordGateTimer() {
        wakeWordGateTimer?.invalidate()
        wakeWordGateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let wm = self.speechWakeWordManager else { return }
                if self.clickyHasActiveAction {
                    wm.pauseForCapture()
                } else {
                    wm.resumeAfterCapture()
                }
            }
        }
    }

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
        // v15p3v (2026-05-09): mirror the live partial transcript so the
        // overlay can show it. Same observation pattern as audio power.
        // v15p3x (2026-05-10): dedupe + throttle. AssemblyAI emits 5-10
        // partials/sec, often with duplicate or near-identical text. The
        // raw firehose was forcing the OverlayWindow ZStack (which now
        // contains LiveVTTPreviewView) to invalidate constantly. That
        // invalidation pressure was implicated in two SwiftUI Button
        // crashes (CompanionPanelView indicator/model picker) — the
        // panel was getting re-hosted mid-click and the gesture fired
        // on a freed view. Dedupe + 10Hz cap kills the churn at the
        // source without losing any visible information.
        vttLiveTranscriptCancellable = buddyDictationManager.$liveTranscriptForDisplay
            .removeDuplicates()
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] transcript in
                guard let self else { return }
                if self.vttLiveTranscript != transcript {
                    self.vttLiveTranscript = transcript
                    // v15p3br (2026-05-13): mark T3 in the live-preview
                    // latency diag — measures press → first user-visible
                    // pixel update. NOTE: there's a .throttle(100ms)
                    // upstream of this sink, which adds up to 100ms to
                    // this measurement. That throttle exists to cap
                    // SwiftUI re-render churn at 10Hz; relaxing it is
                    // one of the levers we have if the latency data
                    // shows this segment dominating.
                    if !transcript.isEmpty {
                        VTTLatencyDiag.markFirstUiUpdate(text: transcript)
                    }
                }
            }
    }

    private func bindVoiceStateObservation() {
        // Continuous .processing watchdog (v11p, 2026-04-27): replaces the
        // earlier per-session safety net that could miss hangs during
        // .pressed startup or get cancelled by a new session before firing.
        // Whenever voiceState ENTERS .processing, schedule a 10s force-clear.
        // Whenever it leaves .processing, cancel the timer. This catches:
        //   - AssemblyAI WebSocket hang at startup (no .released ever fires)
        //   - Token-fetch race during fast engage→disengage
        //   - Repunctuate / polish / paste hang in pasteVoiceToTextTranscript
        //   - Any other path that strands voiceState at .processing
        // The continuous nature means a new .pressed can't accidentally
        // skip the safety net for a still-stuck prior session.
        // v13u (2026-04-30): voiceState watchdog DISABLED. It was designed
        // to catch genuinely hung .processing states, but in practice it
        // fires on legitimate long operations (long dictation + transcription
        // + Claude reasoning + TTS often exceed 10s) and kills the in-flight
        // URLSession task. Result: transcripts get cancelled mid-stream,
        // TTS gets cancelled mid-synthesis, spinner stuck because the
        // silent-return cancellation path short-circuits cleanup.
        //
        // We retain Esc as the manual panic-clear (handleEscapeKeyForToggleUnlock
        // does everything the watchdog used to do, on user demand). If a
        // genuine hang ever happens, Esc fixes it. The auto-watchdog was
        // causing more failures than it prevented.
        //
        // To re-enable: uncomment below. The schedule/cancel methods
        // themselves are preserved.
        // $voiceState
        //     .receive(on: DispatchQueue.main)
        //     .sink { [weak self] newState in
        //         guard let self else { return }
        //         if newState == .processing {
        //             self.scheduleVoiceStateWatchdog()
        //         } else {
        //             self.cancelVoiceStateWatchdog()
        //         }
        //     }
        //     .store(in: &cancellableSet)

        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        // v15p3bf (2026-05-12): Base PTT (Fn+Opt hold) subscription DISABLED.
        // v15p3bu (2026-05-13): re-enabled, initially wired to Deepgram.
        // v15p3bw (2026-05-13): wired to AssemblyAI VTT after the
        // Deepgram-primary swap to Fn+Ctrl.
        // v15p3fq (2026-05-17): Fn+Opt is now the new Watch mode —
        // screen-frame streaming sub-mode of Marin Gemini for the
        // "describe what I'm pointing at" workflow. AssemblyAI VTT
        // moved down to Fn+Shift+Opt (see burstTransitionCancellable
        // repurpose below). The publisher name (shortcutTransition…)
        // is historical; it still fires on Fn+Opt — only the handler
        // changes.
        // v16qo (2026-06-14): Steph's hotkey remap. The Fn+Opt chord
        // (shortcutTransitionPublisher) now drives TYPING mode (moved off
        // Cmd+Fn). Watch moves to Fn+Shift+Opt (burst chord) below; Base
        // PTT takes the freed Cmd+Fn chord (typing publisher) below.
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleTypingTransition(transition)
            }

        // v15p3hx (2026-05-19): Fn+Shift+Opt (burst chord) RETIRED.
        // AssemblyAI VTT is now selectable from the panel's Modes tab
        // alongside Deepgram and Parakeet — Fn+Ctrl is the single VTT
        // hotkey, the active provider follows the picker. The chord
        // itself is freed up for a future repurpose.
        // v16qo (2026-06-14): Fn+Shift+Opt (burst chord) now drives
        // WATCH mode (moved off Fn+Opt). The burst chord was retired/no-op
        // before this.
        burstTransitionCancellable = globalPushToTalkShortcutMonitor
            .burstTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleVideoWatchTransition(transition)
            }

        // v16qo (2026-06-14): Cmd+Fn (typing chord) now drives BASE PTT —
        // the Claude voice/vision conversation (handleShortcutTransition,
        // which is where Claude Vision Phase 1 lives). Typing moved to
        // Fn+Opt above. This is what finally binds Base PTT to a hotkey.
        typingTransitionCancellable = globalPushToTalkShortcutMonitor
            .typingTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        // v15p3bw (2026-05-13): voiceToTextTransitionPublisher (Fn+Ctrl)
        // now routes to the Deepgram handler. See bindShortcutTransitions
        // comment above for the full swap rationale.
        voiceToTextTransitionCancellable = globalPushToTalkShortcutMonitor
            .voiceToTextTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleVoiceToTextDeepgramTransition(transition)
            }

        captureToInboxTransitionCancellable = globalPushToTalkShortcutMonitor
            .captureToInboxTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleCaptureToInboxTransition(transition)
            }

        // v15p2 (2026-05-02): Realtime conversation hotkey (Ctrl + Opt).
        // (Earlier comment said Fn+Opt — incorrect. Per
        // BuddyPushToTalkShortcut.realtimeTransition the actual chord
        // is Ctrl+Opt with .function forbidden. Fn+Opt is the disabled
        // Base PTT chord, now reused by Deepgram VTT in v15p3bu.)
        realtimeTransitionCancellable = globalPushToTalkShortcutMonitor
            .realtimeTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleRealtimeTransition(transition)
            }

        // v15p3fq (2026-05-17): the Fn+Shift+Opt single-tap hands-free
        // Marin engage subscription was already commented out in
        // v15p3bf and confirmed unused by Steph. Now formally removed
        // since the chord is repurposed for AssemblyAI VTT above. The
        // monitor's realtimeHandsFreeToggleTransitionPublisher firing
        // logic is yanked at the same time (see
        // GlobalPushToTalkShortcutMonitor).

        polishHotkeyTransitionCancellable = globalPushToTalkShortcutMonitor
            .polishHotkeyTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handlePolishHotkeyTransition(transition)
            }

        // Double-tap (engage) and single-tap (disengage) toggles for
        // VTT (Ctrl) and typing (Cmd). Esc disengages whichever is active.
        // The shortcut monitor's chord filter (v11g) ensures workflows like
        // ⌘+C never fire single-tap by accident.
        controlDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .controlDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleVoiceToTextDoubleTapEngage()
            }
        // v16qo (2026-06-14): double-tap Cmd no longer engages the typing
        // toggle (typing moved off Cmd to Fn+Opt; Steph doesn't want a
        // typing toggle). Left as a no-op for now — it becomes the Base
        // PTT hands-free toggle when Phase 2 (continuous Claude convo) ships.
        commandDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .commandDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { _ in }
        // v15p2 (2026-05-02): hotkey swap — Option double-tap now
        // engages Realtime hands-free instead of Base voice-mode.
        // Base voice-mode moved to Fn+Shift+Opt (handled below).
        optionDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .optionDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleOptionDoubleTapForRealtimeHandsFree()
            }
        // v15p3gt (2026-05-18): double-tap Shift engages speed-read mode.
        shiftDoubleTapCancellable = globalPushToTalkShortcutMonitor
            .shiftDoubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleShiftDoubleTapForSpeedRead()
            }
        controlSingleTapCancellable = globalPushToTalkShortcutMonitor
            .controlSingleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleVoiceToTextSingleTapDisengage()
            }
        // v16qo: typing single-tap disengage removed from Cmd (typing moved
        // off Cmd; no typing toggle). No-op for now.
        commandSingleTapCancellable = globalPushToTalkShortcutMonitor
            .commandSingleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { _ in }
        // v15p2 (2026-05-02): single-tap Option mirrors the swap —
        // disengages Realtime hands-free instead of Base voice-mode.
        optionSingleTapCancellable = globalPushToTalkShortcutMonitor
            .optionSingleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleOptionSingleTapForRealtimeHandsFree()
            }
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeKeyForToggleUnlock()
            }

        // v15p3bx (2026-05-13): tell the monitor whether to consume Esc
        // at the event tap. When any Clicky+ mode/state is active, Esc
        // is "ours" to act on, so we eat it before it reaches the
        // foreground app (Cowork, etc.). When Clicky+ is idle, the
        // closure returns false and Esc passes through normally so
        // other apps' Esc workflows aren't disrupted.
        globalPushToTalkShortcutMonitor.shouldConsumeEscapeWhenPressed = { [weak self] in
            guard let self else { return false }
            return self.clickyHasActiveAction
        }

        // Native macOS screenshot session (Cmd+Shift+3/4/5) — delivered
        // synchronously (no .receive(on:)) so the overlay hides on the same
        // run-loop tick as the keyDown, before screencaptureui grabs the
        // window list for its window-mode picker (Cmd+Shift+4 → space).
        // The event tap already fires on the main thread.
        nativeScreenshotSessionCancellable = globalPushToTalkShortcutMonitor
            .nativeScreenshotSessionPublisher
            .sink { [weak self] isActive in
                guard let self else { return }
                if isActive {
                    self.overlayWindowManager.suspendForNativeScreenshot()
                } else {
                    self.overlayWindowManager.resumeAfterNativeScreenshot()
                }
            }

        // v15p4t (2026-05-23): listen for Marin helper sub-agent state
        // changes so the notch can flip to "Researching" while a helper
        // is running. Notification posted by MarinHelperSubAgent.
        helperStateObserver = NotificationCenter.default.addObserver(
            forName: .marinHelperStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let active = (note.userInfo?["active"] as? Bool) ?? false
            self.isHelperSubAgentActive = active
        }

        // v15p4u (2026-05-23): install the floating helper-task column
        // window. Lives top-right of the screen, owned by its own
        // manager. Reads from HelperTaskStore.
        FloatingHelperColumnManager.shared.install()

        // v15p4ah (2026-05-24): ensure the canonical Helper Outputs
        // directory exists at ~/Desktop/Claude Cowork/Helper Outputs/
        // so the helper's first write doesn't fail on missing dir.
        MarinHelperSubAgent.ensureHelperOutputsDirectory()

        // v15p4p (2026-05-23): Cmd+Shift+2 → screenshot-and-paste.
        // v15p4q (2026-05-23): switched from spawning `screencapture -ci`
        // to posting the native Cmd+Ctrl+Shift+4 keystroke (selection
        // screenshot → clipboard). Why: when screencapture is launched
        // as our child process, it's not in loginwindow's mach bootstrap
        // hierarchy, and the Space-toggle-to-window-selection-mode
        // doesn't fire (the man page hints at this with its
        // `launchctl bsexec` workaround). Posting the native shortcut
        // lets macOS launch the screencaptureui in the right context,
        // and Space works exactly like it does on real Cmd+Shift+4.
        //
        // Detection of completion: poll NSPasteboard.changeCount every
        // 150 ms. When it incremented vs. our snapshot at trigger time,
        // post Cmd+V. Time out after 30 s if the user never captures.
        screenshotPasteCancellable = globalPushToTalkShortcutMonitor
            .screenshotPasteShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let pasteboard = NSPasteboard.general
                let priorChangeCount = pasteboard.changeCount

                // 100 ms delay before posting the native shortcut — gives
                // Steph time to release Cmd+Shift+2 so the synthesized
                // Cmd+Ctrl+Shift+4 isn't merged with physical modifier
                // state still being held down. v15p4r: trimmed from 200 ms.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let src = CGEventSource(stateID: .hidSystemState)
                    // virtualKey 21 = '4' on ANSI layout.
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 21, keyDown: true)
                    down?.flags = [.maskCommand, .maskControl, .maskShift]
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 21, keyDown: false)
                    up?.flags = [.maskCommand, .maskControl, .maskShift]
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                }

                // Poll clipboard for the new image. On change, post Cmd+V
                // after a small focus-settle delay. Cap at 30 s.
                //
                // v15p4s (2026-05-23): also require the clipboard to
                // actually contain image data before firing Cmd+V. The
                // raw changeCount check was firing on any clipboard
                // write — which caused a duplicate paste on first
                // launch when something else wrote text to the
                // clipboard mid-poll. With this guard we wait for a
                // change that's an image, ignore everything else.
                let startTime = Date()
                var pollTimer: Timer?
                pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { t in
                    if pasteboard.changeCount != priorChangeCount {
                        let types = pasteboard.types ?? []
                        let hasImage = types.contains(.tiff)
                            || types.contains(.png)
                            || types.contains(NSPasteboard.PasteboardType("public.png"))
                            || types.contains(NSPasteboard.PasteboardType("public.tiff"))
                        guard hasImage else {
                            // Non-image clipboard change — keep polling.
                            // Don't update priorChangeCount; we want to
                            // notice the eventual image write too.
                            return
                        }
                        t.invalidate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            let src = CGEventSource(stateID: .hidSystemState)
                            // virtualKey 9 = 'v' on ANSI layout.
                            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                            down?.flags = .maskCommand
                            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                            up?.flags = .maskCommand
                            down?.post(tap: .cghidEventTap)
                            up?.post(tap: .cghidEventTap)
                        }
                    } else if Date().timeIntervalSince(startTime) > 30 {
                        t.invalidate()
                    }
                }
                _ = pollTimer  // silence unused warning; timer retains itself via RunLoop
            }
    }

    // MARK: - Suspend-Marin-during-other-modes (v15p2, 2026-05-03)
    //
    // Steph wanted to be able to use VTT / Typing / Polish / Capture
    // / Burst / Base PTT WITHOUT Marin fighting him — without this,
    // her mic captures his dictation as if it were for her, her
    // VAD triggers a response, her TTS plays through speakers and
    // is captured back as input. Mess.
    //
    // Strategy: refcount other-mode chords currently held. When the
    // count goes 0→1, suspend Marin (mute mic, cancel response,
    // stop TTS). When the count goes 1→0, resume. The WebSocket
    // stays open through the suspend.
    //
    // Each mode contributes a distinct key to the refcount set so
    // releases of one mode don't clear the count while another is
    // still held.

    /// Mark an other-mode chord as currently pressed. Suspends Marin
    /// on the 0→1 transition.
    /// v15p3gv (2026-05-18): also suspends the Gemini Marin provider —
    /// previously only the OpenAI provider was muted, so VTT dictation
    /// bled through into Gemini Marin's mic stream and she'd respond
    /// to whatever Steph said into Deepgram.
    private func markOtherModePressed(_ modeKey: String) {
        let wasEmpty = otherModeChordsHeld.isEmpty
        otherModeChordsHeld.insert(modeKey)
        let marinAlive = realtimeManager != nil
        let geminiAlive = geminiRealtimeManager != nil
        RealtimeConversationManager.appendDiag(
            "markOtherModePressed mode=\(modeKey) wasEmpty=\(wasEmpty) marinAlive=\(marinAlive) geminiAlive=\(geminiAlive) heldCount=\(otherModeChordsHeld.count)"
        )
        if wasEmpty {
            realtimeManager?.suspendForOtherMode()
            geminiRealtimeManager?.suspendForOtherMode()
            isRealtimeSuspendedByOtherMode = true
        }
    }

    /// Mark an other-mode chord as released. Resumes Marin on the
    /// 1→0 transition (when ALL other-mode chords have released).
    private func markOtherModeReleased(_ modeKey: String) {
        otherModeChordsHeld.remove(modeKey)
        let marinAlive = realtimeManager != nil
        let geminiAlive = geminiRealtimeManager != nil
        RealtimeConversationManager.appendDiag(
            "markOtherModeReleased mode=\(modeKey) nowEmpty=\(otherModeChordsHeld.isEmpty) marinAlive=\(marinAlive) geminiAlive=\(geminiAlive)"
        )
        if otherModeChordsHeld.isEmpty {
            realtimeManager?.resumeFromOtherMode()
            geminiRealtimeManager?.resumeFromOtherMode()
            isRealtimeSuspendedByOtherMode = false
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p2 (2026-05-03): suspend Marin if she's running.
            markOtherModePressed("basePTT")
            guard ensureDictationReady() else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            // v12r: arm click-to-capture for the voice-mode session.
            // While engaged, every left-click anywhere on screen captures
            // a pre/post screenshot pair tagged with the click coords.
            // These accumulate alongside the voice transcript and get
            // sent to Claude on release.
            startVoiceModeClickCapture()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)

                        // v12v: voice-mode replay command — intercept before
                        // shipping to Claude. "Say that again" / "repeat that"
                        // / "what did you say" replay the last response via
                        // TTS instead of treating the phrase as a new question.
                        if Self.isVoiceReplayCommand(finalTranscript) {
                            self.replayLastAssistantResponseViaTTS()
                            return
                        }

                        self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // v15p2 (2026-05-03): release Marin suspension for this mode.
            markOtherModeReleased("basePTT")
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()

            // v12r: tear down the click monitors. We DON'T clear the
            // frame buffer here — it has to survive into
            // sendTranscriptToClaudeWithScreenshot. The buffer gets
            // cleared at the start of the next session.
            stopVoiceModeClickCaptureMonitorOnly()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Burst Mode (Screenshot Burst)
    //
    // Fn + Ctrl + Opt triggers "burst mode": while held, Clicky captures a
    // screenshot every 1s (up to 10 frames) and records voice simultaneously.
    // On release, the frames + voice transcript are sent to Claude as
    // extended context (e.g. a scroll or short video replayed to the model).
    //
    // This is ADDITIVE and fully isolated from the normal push-to-talk
    // pipeline. The global shortcut monitor emits burst transitions on a
    // separate publisher, and the normal push-to-talk shortcut detector
    // explicitly ignores events that include .function, so the two modes
    // never fire together.

    /// v13t (2026-04-30): burst mode disabled. Steph killed it because the
    /// first-attempt-silent + watchdog-stuck issues weren't worth solving.
    /// To re-enable, flip this flag to true. Code below is preserved.
    private static let isBurstModeEnabled = false

    private func handleBurstTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        guard Self.isBurstModeEnabled else { return }

        switch transition {
        case .pressed:
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }

            // Bring the overlay forward if it's currently hidden
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            startBurstCapture()

            pendingBurstShortcutStartTask?.cancel()
            pendingBurstShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        // Await the final-frame capture before sending so
                        // the frame captured at the moment of release is
                        // always included. `value` on a Task<Void, Never>
                        // simply completes when the task finishes.
                        Task { @MainActor in
                            await self.finalBurstCaptureTask?.value
                            print("📸🗣️ Burst submit — transcript: \(finalTranscript) frames: \(self.burstCapturedFrames.count)")
                            let frames = self.burstCapturedFrames
                            self.burstCapturedFrames.removeAll()
                            self.sendBurstFramesToClaude(transcript: finalTranscript, frames: frames)
                        }
                    }
                )
            }

        case .released:
            ClickyAnalytics.trackPushToTalkReleased()

            // 1. Kill the periodic timer immediately so it won't fire again
            //    in the tail of this keypress. We intentionally keep
            //    isBurstModeActive = true for a moment so the final-frame
            //    capture below doesn't get rejected by the is-active guard.
            burstCaptureTimer?.invalidate()
            burstCaptureTimer = nil

            // 2. Kick off ONE final screenshot, representing whatever is
            //    on screen at the exact moment of release. Without this,
            //    anything the user did between the last 1s tick and the
            //    release (up to ~1s of activity) is invisible to Claude.
            finalBurstCaptureTask?.cancel()
            finalBurstCaptureTask = Task { @MainActor [weak self] in
                await self?.captureFinalBurstFrame()
                self?.isBurstModeActive = false
            }

            // 3. Stop dictation. This eventually invokes submitDraftText
            //    with the final transcript, which awaits finalBurstCaptureTask
            //    before calling sendBurstFramesToClaude so the last frame
            //    is guaranteed to be present.
            pendingBurstShortcutStartTask?.cancel()
            pendingBurstShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    private func startBurstCapture() {
        burstCaptureTimer?.invalidate()
        burstCapturedFrames.removeAll()
        isBurstModeActive = true
        // Keep the spinner red through the entire response cycle, not
        // just the capture phase. Cleared in sendBurstFramesToClaude's
        // Task once voiceState returns to idle (or earlier on cancel).
        isBurstResponseCycleInFlight = true

        captureBurstFrameIfUnderCap()

        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.burstCaptureIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureBurstFrameIfUnderCap()
            }
        }
        burstCaptureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBurstCapture() {
        burstCaptureTimer?.invalidate()
        burstCaptureTimer = nil
        isBurstModeActive = false
    }

    /// Captures one final screenshot at the moment of key release. This frame
    /// represents "what the user was actually doing when they let go" and is
    /// the most important frame of the entire burst — so it bypasses BOTH
    /// the isBurstModeActive guard (which is only for discarding late
    /// timer-driven captures) AND the 10-frame cap. Worst-case payload is
    /// 10 periodic ticks + 1 final = 11 frames. The 10-frame cap still
    /// protects against unbounded payload growth from the 1fps timer.
    private func captureFinalBurstFrame() async {
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
                ?? captures.first
            guard let primary else { return }
            burstCapturedFrames.append(primary)
            lastScreenshotCaptureAt = Date()
            print("📸 Burst FINAL frame captured (total: \(burstCapturedFrames.count))")
        } catch {
            print("⚠️ Burst final capture error: \(error)")
        }
    }

    private func captureBurstFrameIfUnderCap() {
        guard burstCapturedFrames.count < Self.burstMaxFrames else {
            // Safety cap reached — stop the timer so we don't keep firing
            burstCaptureTimer?.invalidate()
            burstCaptureTimer = nil
            print("📸 Burst cap reached (\(Self.burstMaxFrames) frames)")
            return
        }

        let frameIndex = burstCapturedFrames.count
        Task { @MainActor in
            do {
                let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                // Only keep the primary-focus screen per frame to avoid
                // ballooning the payload (10 frames × N screens × M bytes).
                let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
                    ?? captures.first
                guard let primary else { return }
                guard self.isBurstModeActive else { return }
                self.burstCapturedFrames.append(primary)
                self.lastScreenshotCaptureAt = Date()
                print("📸 Burst frame \(frameIndex + 1)/\(Self.burstMaxFrames) captured")
            } catch {
                print("⚠️ Burst capture error: \(error)")
            }
        }
    }

    private func sendBurstFramesToClaude(transcript: String, frames: [CompanionScreenCapture]) {
        guard !frames.isEmpty else {
            // Nothing captured (e.g. user released too fast) — fall back to
            // a normal single-shot interaction so the user isn't left hanging.
            sendTranscriptToClaudeWithScreenshot(transcript: transcript)
            return
        }

        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        currentResponseTask = Task {
            // v12q (2026-04-28): GUARANTEE the burst-cycle flag clears no
            // matter how we exit this Task. Three early-return paths
            // (cancellation, URL cancel during TTS, URL cancel during the
            // Claude call) previously bypassed the cleanup line at the
            // bottom and left the flag stuck true — which then turned
            // every subsequent VTT/typing spinner RED because the tint
            // resolver thought a burst was still in flight. Defer makes
            // it bulletproof.
            defer { isBurstResponseCycleInFlight = false }

            voiceState = .processing

            do {
                let labeledImages = frames.enumerated().map { idx, capture -> (data: Data, label: String) in
                    let dims = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: "burst frame \(idx + 1) of \(frames.count)" + dims)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }
                // v16qn: carry the last few turns' screenshots into context
                // so Claude SEES recent screens (Claude Vision Phase 1).
                let historyImages: [[Data]] = {
                    let n = conversationHistory.count
                    return conversationHistory.enumerated().map { idx, entry in
                        idx >= n - claudeVisualMemoryTurns ? entry.screenshots : []
                    }
                }()

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.burstModeSystemPrompt,
                    conversationHistory: historyForAPI,
                    historyImages: historyImages,
                    userPrompt: transcript,
                    personalFacts: Self.loadCurrentObsidianMemoryContents(),
                    onTextChunk: { _ in }
                )

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // v16qn: keep the most recent burst frame so Claude can
                // recall this view on later turns (Claude Vision Phase 1).
                let burstMemoryShot = frames.last?.imageData
                conversationHistory.append(ConversationEntry(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    screenshots: burstMemoryShot.map { [$0] } ?? []
                ))
                if conversationHistory.count > 30 {
                    conversationHistory.removeFirst(conversationHistory.count - 30)
                }
                saveConversationHistory()

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // v11y: persist burst interaction (transcript + Claude
                // response + ALL frame screenshots — multi-frame context
                // is the whole point of burst).
                let burstInteractionId = ClickyTranscriptLogger.newInteractionId()
                let burstTimestamp = Date()
                var burstScreenshotPaths: [String] = []
                for (frameIndex, frame) in frames.enumerated() {
                    if let path = ClickyTranscriptLogger.shared.saveScreenshotJPEG(
                        frame.imageData,
                        forInteractionId: burstInteractionId,
                        frameIndex: frameIndex,
                        timestamp: burstTimestamp
                    ) {
                        burstScreenshotPaths.append(path)
                    }
                }
                ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
                    id: burstInteractionId,
                    timestamp: burstTimestamp,
                    mode: .burst,
                    rawTranscript: transcript,
                    finalOutput: nil,
                    claudeResponse: spokenText,
                    polishModifier: nil,
                    appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                    screenshotPaths: burstScreenshotPaths,
                    polishStatus: nil
                ))

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await ttsClient.speakText(spokenText)
                        voiceState = .responding
                    } catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            // Interrupted by another interaction — stay silent
                            return
                        }
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error (burst): \(error)")
                        speakCreditsErrorFallback(error: error)
                    }
                }
            } catch is CancellationError {
                // User started another interaction — drop this response
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    // Interrupted by another interaction — stay silent
                    return
                }
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Burst response error: \(error)")
                speakCreditsErrorFallback(error: error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
            // Cleanup of isBurstResponseCycleInFlight now handled by the
            // top-of-Task defer (v12q), which is bulletproof against the
            // three early-return paths above (cancellation during Claude
            // call, URL-cancel during TTS, outer URL-cancel catch).
        }
    }

    private static let burstModeSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via the burst-mode push-to-talk (Fn + Shift + Opt) and you can see a SEQUENCE of screenshots captured about one second apart — treat them like a short recording of what they were doing. the first image is the earliest moment; the last image is the most recent. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullets, or markdown.
    - describe changes across frames when it helps — "i saw you scroll through…", "after you clicked X…" — but don't narrate every frame mechanically.
    - if the burst doesn't seem relevant to their question, just answer the question directly.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what it does conversationally.
    - don't end with dead-end yes/no questions. plant a seed — a next step or related idea worth coming back for. it's fine to end cleanly if the answer is complete.

    element pointing:
    if pointing at a specific UI element would help, append [POINT:x,y:label] using the pixel coordinates of the MOST RECENT frame (the last image). otherwise append [POINT:none]. the burst frames are labeled "burst frame N of M" — use frame M (the last one) as the coordinate reference.
    """

    // MARK: - v12r: Voice-Mode Click-to-Capture
    //
    // Wired into the base PTT engage/release. While voice mode is held,
    // every left-click triggers a two-shot capture (pre + post). On
    // release, frames are deduped and sent to Claude alongside the final
    // baseline screenshot and the transcript.
    //
    // The pre-click capture captures the screen as fast as we can after
    // the OS hands us the click event — typically microseconds, well
    // before most UIs render their reaction. The post-click capture is
    // scheduled 350ms later to catch the result of the click (page load,
    // dropdown, modal, etc.). This gives Claude both "what was clicked"
    // and "what happened next" without the user having to click twice.

    @MainActor
    private func startVoiceModeClickCapture() {
        // Defensive teardown — shouldn't happen but guards against double-start.
        stopVoiceModeClickCaptureMonitorOnly()

        // Clear any leftover frames from a prior session BEFORE the new
        // session begins capturing. Stale frames in the buffer would
        // get sent on the next interaction and confuse Claude.
        voiceModeClickFrames.removeAll()

        // Watch left, right, AND other mouse buttons.
        //
        // v12r hotfix (2026-04-28): base PTT is ⌃⌥ — and macOS converts
        // Ctrl+click into a secondary click at the OS level, dispatching
        // .rightMouseDown instead of .leftMouseDown. So while PTT is
        // held, every "click" the user makes fires as a right-click.
        // Monitor both so the modifier-conflict is invisible to the user.
        // .otherMouseDown rounds out the set for middle-click / side
        // buttons in case anyone uses a real multi-button mouse.
        let clickEventMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]

        // Global monitor — fires for clicks anywhere on screen, in any
        // app, when Clicky is NOT the frontmost window. This is the
        // primary path; Clicky almost never holds focus while the user
        // is doing work in another app.
        voiceModeClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: clickEventMask
        ) { [weak self] event in
            guard let self else { return }
            let clickPoint = NSEvent.mouseLocation
            Task { @MainActor in
                self.captureVoiceModeClickPair(at: clickPoint)
            }
            _ = event
        }

        // Local monitor — fires for clicks INSIDE Clicky's own windows.
        // Without this, clicks on Clicky's overlay/panel during voice
        // mode are invisible to the global monitor. We pass the event
        // through unchanged.
        voiceModeClickLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: clickEventMask
        ) { [weak self] event in
            guard let self else { return event }
            let clickPoint = NSEvent.mouseLocation
            Task { @MainActor in
                self.captureVoiceModeClickPair(at: clickPoint)
            }
            return event
        }

        print("📸 Click-to-capture: monitor armed for voice mode session")
    }

    /// Removes the click monitors WITHOUT clearing the frame buffer —
    /// the buffer needs to survive into sendTranscriptToClaudeWithScreenshot.
    /// The buffer is cleared at the START of the next session.
    @MainActor
    private func stopVoiceModeClickCaptureMonitorOnly() {
        if let monitor = voiceModeClickGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            voiceModeClickGlobalMonitor = nil
        }
        if let monitor = voiceModeClickLocalMonitor {
            NSEvent.removeMonitor(monitor)
            voiceModeClickLocalMonitor = nil
        }
    }

    /// Captures the pre-click frame immediately and schedules the post-
    /// click frame ~350ms later. Both go into voiceModeClickFrames with
    /// click coords and pre/post tags. Each successful capture fires
    /// lastScreenshotCaptureAt so the sonar ring (v12p) pings on the orb.
    @MainActor
    private func captureVoiceModeClickPair(at clickPoint: CGPoint) {
        // Cap check — once we hit the per-session frame cap, stop firing
        // captures. The user has clicked enough that the payload is
        // already saturated; further clicks just stop accruing frames.
        guard voiceModeClickFrames.count < Self.voiceModeClickFramesCap else {
            return
        }

        // PRE-click capture: dispatch immediately. Microseconds after
        // the OS event landed = effectively pre-render in 95%+ of cases.
        Task { [weak self] in
            await self?.captureVoiceModeClickFrame(
                at: clickPoint,
                isPostClick: false
            )
        }

        // POST-click capture: scheduled. If the user releases voice mode
        // before this fires, captureVoiceModeClickFrame's monitor-active
        // guard drops the frame so we don't over-capture into a stale
        // session.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.voiceModePostClickDelayNanos)
            await self?.captureVoiceModeClickFrame(
                at: clickPoint,
                isPostClick: true
            )
        }
    }

    /// Common capture path. Picks the screen the user clicked on (so
    /// multi-monitor click-to-capture works correctly) and falls back
    /// to primary if no screen-level match is found.
    private func captureVoiceModeClickFrame(at clickPoint: CGPoint, isPostClick: Bool) async {
        // For the post-click frame, drop it if voice mode has already
        // ended (the global monitor is gone). Without this, post-frames
        // could trickle in after the Claude request was sent and end up
        // wasted in the next session's buffer.
        let shouldCapture = await MainActor.run { [weak self] in
            guard let self else { return false }
            if isPostClick {
                return self.voiceModeClickGlobalMonitor != nil
                    && self.voiceModeClickFrames.count < Self.voiceModeClickFramesCap
            } else {
                return self.voiceModeClickFrames.count < Self.voiceModeClickFramesCap
            }
        }
        guard shouldCapture else { return }

        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            // Prefer the screen that contains the click point. Falls back
            // to primary, then to first available, so multi-screen clicks
            // produce the most relevant frame.
            let chosen = pickScreenCapture(captures, forClickAt: clickPoint)
            guard let chosen else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.voiceModeClickFrames.count < Self.voiceModeClickFramesCap else { return }
                let frame = VoiceModeClickFrame(
                    imageData: chosen.imageData,
                    widthInPixels: chosen.screenshotWidthInPixels,
                    heightInPixels: chosen.screenshotHeightInPixels,
                    clickPoint: clickPoint,
                    isPostClick: isPostClick,
                    timestamp: Date()
                )
                self.voiceModeClickFrames.append(frame)
                // Sonar-ring trigger — same flag burst uses, so each
                // click capture pings the orb.
                self.lastScreenshotCaptureAt = Date()
            }
        } catch {
            print("⚠️ Click-to-capture (\(isPostClick ? "post" : "pre")): \(error)")
        }
    }

    /// Pick the capture for the screen containing `clickPoint`, with
    /// fallbacks for safety.
    private func pickScreenCapture(
        _ captures: [CompanionScreenCapture],
        forClickAt clickPoint: CGPoint
    ) -> CompanionScreenCapture? {
        // The CompanionScreenCapture label embeds the screen origin in
        // its standard "screen at (x,y) WxH" format. We can match the
        // clickPoint to the screen by checking which NSScreen's frame
        // contains it.
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(clickPoint) }) {
            // Match by checking if any capture's label mentions the
            // containing screen's origin or "primary" if it's the main one.
            let isPrimary = containingScreen == NSScreen.screens.first
            if isPrimary, let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") }) {
                return primary
            }
            // Otherwise fall through to the first capture as a stand-in.
        }
        // Fallback chain: primary → first → nil
        return captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
            ?? captures.first
    }

    /// Dedup pass over the captured pairs. For each pre/post pair where
    /// the post-frame is essentially identical to the pre-frame (size
    /// proximity + matching JPEG header bytes), drop the post — the
    /// click didn't change the screen, so the second frame adds zero
    /// signal and just costs Claude tokens.
    private func dedupedVoiceModeClickFrames(_ frames: [VoiceModeClickFrame]) -> [VoiceModeClickFrame] {
        guard !frames.isEmpty else { return frames }

        // Pair the frames by click position + nearby timestamps. We
        // captured them in pairs but they may have been logged out of
        // order due to async dispatch. Walk the array and for each
        // pre-frame, find its matching post-frame (same click coords,
        // post-flag, within ~500ms).
        var keep: [VoiceModeClickFrame] = []
        var dropPostIndices = Set<Int>()

        for (i, frame) in frames.enumerated() where !frame.isPostClick {
            guard let postIndex = frames.firstIndex(where: { other in
                other.isPostClick
                    && other.clickPoint == frame.clickPoint
                    && abs(other.timestamp.timeIntervalSince(frame.timestamp)) < 1.0
            }) else { continue }

            let post = frames[postIndex]
            if framesAreVisuallyIdentical(frame, post) {
                dropPostIndices.insert(postIndex)
            }
            _ = i
        }

        for (i, frame) in frames.enumerated() {
            if dropPostIndices.contains(i) { continue }
            keep.append(frame)
        }

        let droppedCount = frames.count - keep.count
        if droppedCount > 0 {
            print("📸 Click-to-capture: deduped \(droppedCount) post-frame(s) that didn't change the screen")
        }
        return keep
    }

    private func framesAreVisuallyIdentical(
        _ a: VoiceModeClickFrame,
        _ b: VoiceModeClickFrame
    ) -> Bool {
        let aSize = Double(a.imageData.count)
        let bSize = Double(b.imageData.count)
        guard aSize > 0, bSize > 0 else { return false }
        let sizeDelta = abs(aSize - bSize) / max(aSize, bSize)
        guard sizeDelta < Self.voiceModeClickDedupSizeThreshold else { return false }
        // Compare first 256 bytes of JPEG. Identical compression
        // structure indicates same scene (or extremely similar). False
        // positives are mostly harmless — we just drop a redundant
        // frame; false negatives mean we keep a slightly-redundant
        // frame, also harmless.
        let prefixLen = min(256, a.imageData.count, b.imageData.count)
        let aPrefix = a.imageData.prefix(prefixLen)
        let bPrefix = b.imageData.prefix(prefixLen)
        return aPrefix == bPrefix
    }

    // MARK: - Typing Mode (Dictation → Paste)
    //
    // Fn + Cmd triggers "typing mode": while held, Clicky records voice
    // and grabs one screenshot of what's on screen. On release, the
    // transcript + screenshot are sent to Claude, and Claude's reply is
    // placed on the clipboard and pasted via a simulated Cmd+V into
    // whatever field has focus. The user's previous clipboard is
    // restored afterward so we don't clobber their copy state.
    //
    // This is ADDITIVE and fully isolated. The shortcut monitor emits
    // typing transitions on its own publisher, and the typing transition
    // function forbids .shift/.option/.control — so typing mode cannot
    // double-fire with burst (Fn+Shift+Opt) or normal PTT.

    private func handleTypingTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p3bg (2026-05-12): targeted diag to root-cause typing-mode
            // empty-transcript regression. VTT works in the same session
            // with the same audio engine, so the bug is typing-specific.
            // Tags every press/release/submit so we can correlate against
            // EMPTY_TRANSCRIPT_ON_FINALIZE entries and identify whether
            // the start task got cancelled before callbacks were stored,
            // whether submitDraftText was ever invoked, etc.
            BuddyDictationManager.appendAudioDiag("TYPING_PRESS")
            // v15p2 (2026-05-03): suspend Marin if she's running.
            markOtherModePressed("typing")
            guard ensureDictationReady() else {
                BuddyDictationManager.appendAudioDiag("TYPING_BAIL_ensureDictationReady=false")
                return
            }
            guard !showOnboardingVideo else {
                BuddyDictationManager.appendAudioDiag("TYPING_BAIL_onboardingVideo")
                return
            }

            // Bring the overlay forward if it's currently hidden
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            // v15p3dd (2026-05-15): typing mode start sound cue.
            ClickySoundEngine.shared.play(.vttStart)

            isTypingModeActive = true
            typingModeScreenshot = nil
            typingModeFocusedContext = nil

            // Grab the focused-element context SYNCHRONOUSLY right now,
            // before dictation starts. AX queries are cheap (tens of
            // microseconds) and capturing at press is critical: the
            // user's focus may wander during the dictation (they might
            // glance at notes, etc.), and we want to lock in what was
            // focused when the hotkey was hit. Any failure is silent;
            // we just get a nil context and fall back to pixels-only.
            typingModeFocusedContext = FocusedElementContextProvider.capture()

            // Grab one screenshot NOW so we capture what the user was
            // looking at when they engaged the hotkey. Async because
            // ScreenCaptureKit is not synchronous — but it kicks off
            // in parallel with dictation start below so there's no
            // perceptible delay.
            Task { @MainActor [weak self] in
                do {
                    let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
                        ?? captures.first
                    self?.typingModeScreenshot = primary
                } catch {
                    print("⚠️ Typing mode screenshot error: \(error)")
                }
            }

            pendingTypingShortcutStartTask?.cancel()
            pendingTypingShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        // v15p3bg diag: confirm typing's submit closure ran
                        // and capture what AssemblyAI actually returned.
                        let preview = finalTranscript
                            .replacingOccurrences(of: "\n", with: "\\n")
                            .prefix(60)
                        BuddyDictationManager.appendAudioDiag(
                            "TYPING_SUBMIT len=\(finalTranscript.count) preview=\(preview)"
                        )
                        self.lastTranscript = finalTranscript
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        let screenshot = self.typingModeScreenshot
                        let context = self.typingModeFocusedContext
                        self.typingModeScreenshot = nil
                        self.typingModeFocusedContext = nil

                        // v11k: "show last response" command — intercept
                        // before sending to Claude. Paste the most recent
                        // assistant response from base PTT (conversationHistory)
                        // straight into the focused field. Lets Steph review
                        // long verbal responses he didn't fully catch.
                        if Self.isShowLastResponseCommand(finalTranscript) {
                            self.pasteLastAssistantResponse()
                            return
                        }

                        self.sendTypingQueryToClaude(
                            transcript: finalTranscript,
                            screenshot: screenshot,
                            focusedContext: context
                        )
                    }
                )
            }

        case .released:
            // v15p3bg diag — capture whether start task was still pending
            // (i.e. release happened before startPushToTalk's await chain
            // completed, which would leave draftCallbacks unset).
            let startTaskStillPending = pendingTypingShortcutStartTask != nil
            BuddyDictationManager.appendAudioDiag(
                "TYPING_RELEASE startTaskStillPending=\(startTaskStillPending)"
            )
            // v15p2 (2026-05-03): release Marin suspension for typing.
            markOtherModeReleased("typing")
            ClickyAnalytics.trackPushToTalkReleased()
            isTypingModeActive = false
            pendingTypingShortcutStartTask?.cancel()
            pendingTypingShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Voice-to-Text Mode (Dictation → Paste, NO Claude)
    //
    // Fn + Shift triggers "voice-to-text mode": while held, Clicky
    // transcribes audio; on release, the transcript is pasted straight
    // into whatever field has focus via the shared clipboard helper.
    // No Claude call, no TTS, no conversation history — the fastest
    // path from voice to typed text.
    //
    // Fully isolated from the other three shortcut paths: its
    // transition function forbids option/command/control, so burst
    // (shift+opt+fn), typing (cmd+fn), and normal PTT (ctrl+opt,
    // which forbids .function) cannot double-fire with it.

    // v15p3s (2026-05-09): unified stuck-state recovery for all
    // dictation engage paths. Generalizes the v15p3c fix that was
    // only applied to handleVoiceToTextTransition .pressed. Same
    // failure mode could happen on any mode engage (typing toggle,
    // capture-to-inbox, polish, base PTT, realtime engagement) —
    // BuddyDictationManager flag stuck true, guard silently bails,
    // toggle "engages" but no actual session starts.
    //
    // Call this BEFORE the isDictationInProgress guard at any user-
    // initiated press/engage handler. Returns true if dictation is
    // ready (either was never running, or stuck state was recovered).
    // Returns false only if recovery failed (very rare — usually
    // means cancelCurrentDictation itself bailed).
    private func ensureDictationReady() -> Bool {
        if buddyDictationManager.isDictationInProgress {
            print("🔧 ensureDictationReady: dictation manager has stuck state — recovering before engage")
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        }
        return !buddyDictationManager.isDictationInProgress
    }

    private func handleVoiceToTextTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p3br (2026-05-13): mark T0 for the latency diag log.
            // Must be the very first thing in the handler so all
            // downstream timestamps measure against the actual press
            // event, not whatever bookkeeping ran first.
            // v15p3bv: tag with provider so AssemblyAI vs Deepgram
            // engages can be filtered apart in the diag file.
            VTTLatencyDiag.markPress(provider: "assemblyai")
            // v15p2 (2026-05-03): suspend Marin if she's running.
            markOtherModePressed("vtt")
            // v15p3c (2026-05-07): the inline if+cancel+guard pattern
            // here was the original recovery for stuck VTT toggle state.
            // v15p3s (2026-05-09): generalized into ensureDictationReady()
            // and applied to all 12 mode-engage call sites. Same effect,
            // single source of truth.
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }

            // Bring the overlay forward if hidden so the purple
            // waveform gives the user immediate feedback.
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Interrupt anything else that's mid-flight — this mode
            // is a pure write path and shouldn't overlap other
            // interactions.
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            // v15p3cu (2026-05-14): VTT start sound cue.
            ClickySoundEngine.shared.play(.vttStart)

            isVoiceToTextModeActive = true

            // Cancel any pending safety net from the previous session — a
            // new press supersedes the old one, and we don't want a stale
            // safety net firing mid-new-session.
            stuckSpinnerSafetyNetTask?.cancel()
            stuckSpinnerSafetyNetTask = nil

            // v11l: capture whether this is a TOGGLE session (double-tap
            // engaged → talk freely → single-tap or Esc to end). Toggle
            // sessions imply long-form dictation that benefits from polish.
            // Hold sessions stay raw. Captured at engage time because
            // isVoiceToTextToggleLocked may have changed by submit time.
            let isToggleSession = isVoiceToTextToggleLocked

            // v12: for toggle sessions, capture a screenshot at engage time
            // so polish has destination-app context (helps match tone:
            // Slack message vs email vs technical doc). Also flows to the
            // transcript log for memory-scan visual context. Hold sessions
            // skip — short raw dictation doesn't benefit.
            vttToggleEngagementScreenshot = nil
            if isToggleSession {
                Task { @MainActor [weak self] in
                    do {
                        let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
                            ?? captures.first
                        self?.vttToggleEngagementScreenshot = primary
                    } catch {
                        print("⚠️ VTT toggle screenshot error: \(error)")
                    }
                }
            }

            pendingVoiceToTextShortcutStartTask?.cancel()
            pendingVoiceToTextShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        let toggleScreenshot = self.vttToggleEngagementScreenshot
                        self.vttToggleEngagementScreenshot = nil
                        let gesturePolish = self.globalPushToTalkShortcutMonitor.vttReleaseToPolishLatched
                        self.pasteVoiceToTextTranscript(
                            finalTranscript,
                            polishAfterRepunctuate: isToggleSession || gesturePolish,
                            contextScreenshot: toggleScreenshot
                        )
                    }
                )
            }

        case .released:
            // v15p2 (2026-05-03): release Marin suspension for VTT.
            markOtherModeReleased("vtt")
            ClickyAnalytics.trackPushToTalkReleased()
            // v15k diagnostic: record release timestamp so we can measure
            // end-to-end VTT latency (release → text appears).
            Self.lastVTTReleaseTimestamp = Date()
            isVoiceToTextModeActive = false
            pendingVoiceToTextShortcutStartTask?.cancel()
            pendingVoiceToTextShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

            // (v11p: replaced by continuous voiceState watchdog in
            // bindVoiceStateObservation — fires automatically whenever
            // voiceState lingers on .processing for >10s, regardless of
            // which entry path got us there.)

        case .none:
            break
        }
    }

    // MARK: - Voice-to-Text Mode (Deepgram) — A/B test (v15p3bu, 2026-05-13)
    //
    // Fn+Opt triggers the same paste-only VTT flow as Fn+Ctrl, but
    // with Deepgram Nova-3 as the transcription provider instead of
    // AssemblyAI u3-rt-pro. Designed as a side-by-side feel test —
    // Steph holds Fn+Opt for Deepgram, Fn+Ctrl for AssemblyAI, with
    // a red cursor indicator on this mode (vs purple for AssemblyAI
    // VTT) so the active provider is visually obvious. The repunctuate
    // / polish / paste pipeline downstream is identical for both
    // modes; only the streaming transcription provider differs.
    //
    // Reuses the previously disabled Base PTT chord (Fn+Opt).
    // Mutually exclusive with everything else by the existing
    // shortcutTransition rules in BuddyPushToTalkShortcut.
    private func handleVoiceToTextDeepgramTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Mark T0 for the latency diag — same diag used by the
            // AssemblyAI VTT path, so head-to-head numbers land in
            // the same file and are directly comparable. v15p3bv:
            // tagged with provider for unambiguous filter.
            // v15p4bs (2026-05-29): use selectedVTTProvider so
            // Parakeet runs get tagged "parakeet" not "deepgram".
            VTTLatencyDiag.markPress(provider: selectedVTTProvider)
            markOtherModePressed("vtt-deepgram")
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }

            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            // v15p3cu (2026-05-14): VTT start sound cue.
            ClickySoundEngine.shared.play(.vttStart)

            isVoiceToTextDeepgramModeActive = true

            stuckSpinnerSafetyNetTask?.cancel()
            stuckSpinnerSafetyNetTask = nil

            // v15p3bw (2026-05-13): Deepgram now supports toggle mode
            // since the hotkey swap made it the primary VTT (Fn+Ctrl
            // + double-tap Ctrl). Mirror the AssemblyAI handler's
            // toggle behavior: capture engagement screenshot for polish
            // context, route polish after repunctuate for long-form
            // dictation, etc. isVoiceToTextToggleLocked is shared with
            // AssemblyAI VTT since only one VTT toggle is active at a
            // time (mutually exclusive hotkeys).
            let isToggleSession = isVoiceToTextToggleLocked

            vttToggleEngagementScreenshot = nil
            if isToggleSession {
                Task { @MainActor [weak self] in
                    do {
                        let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        let primary = captures.first(where: { $0.label.localizedCaseInsensitiveContains("primary") })
                            ?? captures.first
                        self?.vttToggleEngagementScreenshot = primary
                    } catch {
                        print("⚠️ Deepgram VTT toggle screenshot error: \(error)")
                    }
                }
            }

            pendingDeepgramVTTShortcutStartTask?.cancel()
            pendingDeepgramVTTShortcutStartTask = Task { [weak self] in
                guard let self else { return }
                await self.buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        let toggleScreenshot = self.vttToggleEngagementScreenshot
                        self.vttToggleEngagementScreenshot = nil
                        // v15p4dq: release-to-polish gesture — if the latch
                        // fired during this hold (one key released + kept
                        // talking), polish even though it's a hold session.
                        let gesturePolish = self.globalPushToTalkShortcutMonitor.vttReleaseToPolishLatched
                        self.pasteVoiceToTextTranscript(
                            finalTranscript,
                            polishAfterRepunctuate: isToggleSession || gesturePolish,
                            contextScreenshot: toggleScreenshot
                        )
                    },
                    overrideTranscriptionProvider: self.activeVTTProvider
                )
            }

        case .released:
            markOtherModeReleased("vtt-deepgram")
            ClickyAnalytics.trackPushToTalkReleased()
            Self.lastVTTReleaseTimestamp = Date()
            isVoiceToTextDeepgramModeActive = false
            pendingDeepgramVTTShortcutStartTask?.cancel()
            pendingDeepgramVTTShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Watch Mode (Fn+Opt) — video sub-mode of Marin Gemini
    //
    // v15p3fq (2026-05-17): NEW. The "I see something I can't describe"
    // mode. Hold Fn+Opt; ScreenCaptureKit frames are streamed into
    // Marin Gemini's Live WS at ~2 fps alongside audio; user narrates
    // what they want described ("watch the halo while I switch modes")
    // or just holds silently for a full-screen description; on release,
    // Gemini returns a paragraph-level description of what it saw.
    //
    // Designed specifically to unblock cases where Steph can SEE a
    // visual issue (halo modulation, animation timing, UI glitch) but
    // can't put the right words on it. The system instruction tells
    // Gemini to prioritize whatever the user calls out; otherwise it
    // narrates the most salient screen content.
    //
    // This commit (v15p3fq) is the SKELETON ONLY — hotkey, state flag,
    // and indicator color. The actual frame-streaming + system-instruction
    // wiring lands in v15p3fr once we've validated the chord + indicator
    // don't regress other modes.
    private func handleVideoWatchTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p3fy (2026-05-17): tap-vs-hold support. Record press
            // time so .released can classify the gesture. If we're
            // already toggle-locked, this press is the START of the
            // disengage tap — don't restart the session, just record
            // the timestamp and exit. The .released branch decides
            // whether to disengage.
            videoWatchPressTimestamp = Date()
            if isVideoWatchToggleLocked {
                print("👁️ Watch mode → tap detected mid-toggle (deciding disengage on release)")
                return
            }
            // Refuse to engage if anything else is active. Watch mode
            // opens a fresh Gemini Live WS with a different setup
            // payload — sharing with an active Marin session would
            // require tearing it down, which is rude if Marin is
            // mid-conversation.
            // v15p3fr (2026-05-17): also refuse if a prior watch
            // response is still in flight — Watch is single-turn,
            // double-press would race the callback.
            guard !clickyHasActiveAction else {
                print("⚠️ Watch mode press ignored — another mode is active")
                return
            }
            guard !isVideoWatchResponseInFlight else {
                print("⚠️ Watch mode press ignored — waiting on prior response")
                return
            }
            print("👁️ Watch mode → PRESSED (Fn+Opt)")
            isVideoWatchModeActive = true
            isVideoWatchResponseInFlight = true

            // v15p3fv (2026-05-17): press cue. Steph needs an audible
            // confirmation that the hold registered — without this,
            // the red dot + halo aren't sufficient feedback (he was
            // narrating into thin air thinking nothing was working).
            // visionCapture is the contextually right tone: "I'm
            // looking at the screen."
            ClickySoundEngine.shared.play(.visionCapture)

            // Bring the overlay forward so the red indicator is visible
            // even when the cursor was hidden.
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Lazy-instantiate the Gemini manager. Matches the pattern
            // used by every other Marin Gemini entry point in this file.
            // v15p3fv (2026-05-17): also call bindGeminiRealtimeManagerState
            // explicitly. If this is the first Gemini-related action of
            // the session (no Marin engage yet), the state binding
            // hasn't been wired up — without it, isRealtimeModeActive
            // never reflects the watch session's connecting/listening
            // state and the audio level publisher isn't subscribed.
            let needsBinding = (geminiRealtimeManager == nil)
            if geminiRealtimeManager == nil {
                geminiRealtimeManager = GeminiRealtimeConversationManager()
            }
            if needsBinding {
                bindGeminiRealtimeManagerState()
            }

            // Open the watch session. The response handler fires once
            // when Gemini finishes generating the description text.
            // Capture self weakly so a long response doesn't keep us
            // alive past a sensible window.
            geminiRealtimeManager?.startWatchSession { [weak self] description in
                Task { @MainActor in
                    self?.handleVideoWatchResponseText(description)
                }
            }

            // Start the 2 fps frame capture loop. Timer fires on the
            // main run loop, kicks off an async capture task each
            // tick. Capture+encode takes longer than the 0.5s tick
            // in some cases — we drop frames when that happens (no
            // queueing) so we don't pile up stale frames behind a
            // slow capture.
            // v15p3fx (2026-05-17): bumped from 2 fps → 4 fps. The
            // halo / spinning-cursor test case showed 2 fps was too
            // slow to catch fast motion — a cursor circling at ~1Hz
            // landed in nearly the same screen position at each
            // 500ms tick, so the model reported "stationary". 250ms
            // intervals catch sub-second motion. Cost is ~2x bandwidth
            // (4 × 300KB/s vs 2 × 300KB/s) — acceptable for the
            // typical 2-3s hold.
            videoWatchFrameTimer?.invalidate()
            videoWatchFrameTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.captureAndSendVideoWatchFrame()
            }
            // Fire one frame immediately so Gemini has visual context
            // before the user starts talking (otherwise the first
            // ~500ms of audio arrives with no frame to attach to).
            captureAndSendVideoWatchFrame()

        case .released:
            // v15p3fy (2026-05-17): tap-vs-hold gesture classification.
            // The same hotkey now supports two engagement patterns:
            //   • Tap (release in <350ms): toggle-engage / toggle-disengage
            //   • Hold (release in ≥350ms): conventional press-and-hold
            // Lets Steph hold for a quick observation OR tap-on, do
            // other things (VTT, Marin, polish) that need their own
            // hotkeys, then tap-off to get the response.
            let elapsed: TimeInterval
            if let pressedAt = videoWatchPressTimestamp {
                elapsed = Date().timeIntervalSince(pressedAt)
            } else {
                elapsed = .infinity
            }
            videoWatchPressTimestamp = nil
            let wasTap = elapsed < Self.videoWatchTapThresholdSeconds

            // Case 1: already toggle-locked → this release ends the toggle.
            // Any release (tap or hold) while locked disengages.
            if isVideoWatchToggleLocked {
                print("👁️ Watch mode → TOGGLE DISENGAGE (was tap-locked, elapsed=\(String(format: "%.2f", elapsed))s)")
                isVideoWatchToggleLocked = false
                endActiveWatchSession()
                return
            }

            // Case 2: not locked, gesture was a tap → engage the toggle.
            // Session is already running (started in .pressed). Just
            // flip the lock and leave it streaming. Don't end yet.
            if wasTap && isVideoWatchModeActive {
                print("👁️ Watch mode → TOGGLE ENGAGED via tap (elapsed=\(String(format: "%.2f", elapsed))s) — tap Fn+Opt again to disengage")
                isVideoWatchToggleLocked = true
                // Audible confirmation that tap-engage worked so Steph
                // knows the indicator is going to stay on. Different
                // cue from press so the two are distinguishable.
                ClickySoundEngine.shared.play(.vttSuccess)
                return
            }

            // Case 3: not locked, gesture was a hold → end normally.
            print("👁️ Watch mode → RELEASED (hold, elapsed=\(String(format: "%.2f", elapsed))s)")
            endActiveWatchSession()

        case .none:
            break
        }
    }

    /// v15p3fy (2026-05-17): shared teardown path for both hold-release
    /// and toggle-disengage. Stops the frame timer, sends activity_end
    /// to Gemini, and arms the 15s response-timeout safety net.
    private func endActiveWatchSession() {
        isVideoWatchModeActive = false

        videoWatchFrameTimer?.invalidate()
        videoWatchFrameTimer = nil

        // Signal end-of-activity so Gemini segments the turn and
        // starts generating. The response callback fires when
        // turnComplete arrives and clears isVideoWatchResponseInFlight
        // via handleVideoWatchResponseText.
        geminiRealtimeManager?.endWatchSession()

        // v15p3fs (2026-05-17): safety net. If the WS hangs or the
        // server never sends turnComplete (we saw this happen with
        // code 1000 — server closes cleanly but no response arrives),
        // the callback never fires and isVideoWatchResponseInFlight
        // stays true — blocking every future Watch press. Force-clear
        // after 15s. The callback (if it eventually arrives) is
        // idempotent: it just sets the flag false a second time.
        // v15p3fy (2026-05-17): also call forceEndWatchSession (instead
        // of endSession) so the Marin disengage tone doesn't play
        // when the timeout fires — that cue should stay suppressed
        // for the entire watch teardown, not just the first endSession.
        videoWatchResponseTimeoutTask?.cancel()
        videoWatchResponseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.isVideoWatchResponseInFlight {
                    print("⚠️ Watch mode response timeout — force-clearing state")
                    self.isVideoWatchResponseInFlight = false
                    self.geminiRealtimeManager?.forceEndWatchSession()
                    // Audible signal that the response failed so Steph
                    // doesn't sit there expecting a paste that never
                    // comes. The clipboard is whatever it was before
                    // the Watch attempt — we don't overwrite with an
                    // error string because that'd surprise him.
                    ClickySoundEngine.shared.play(.vttError)
                }
            }
        }
    }

    /// v15p3fr (2026-05-17): captures the primary display as JPEG and
    /// forwards to the Gemini Watch session. Defensive guards: if the
    /// hotkey was released between the timer firing and this method
    /// running, drop the frame; if capture fails, log and continue.
    /// Runs every 250ms while Fn+Opt is held / toggled on.
    ///
    /// v15p4bh (2026-05-26): switched from captureAllScreensAsJPEG to
    /// captureActiveScreenAsJPEG(maxDimension: 1280). Before: every
    /// tick captured every connected display (MacBook + Sceptre) at
    /// 1920px, JPEG-encoded both, discarded the non-primary. After:
    /// single capture of the cursor screen at 1280px. Effective FPS
    /// goes from ~1 to ~4 (the timer ceiling) on dual-display setups
    /// and per-frame token cost drops ~4× since the JPEG is roughly
    /// 6× smaller. This is Phase 1 of the "true video Watch Mode"
    /// upgrade — Phase 2 is the SCStream-based continuous capture
    /// path that lets us push past 4 FPS.
    private func captureAndSendVideoWatchFrame() {
        guard isVideoWatchModeActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frame = try await CompanionScreenCaptureUtility.captureActiveScreenAsJPEG(maxDimension: 1280)
                // Belt-and-suspenders: re-check the mode flag after
                // the async capture in case release fired during the
                // capture window. Stale frames after release would
                // confuse Gemini's frame-vs-audio alignment.
                guard self.isVideoWatchModeActive else { return }
                self.geminiRealtimeManager?.sendVideoFrame(frame.imageData)
            } catch {
                print("⚠️ Watch mode frame capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// v15p3fr (2026-05-17): runs when the Gemini Watch turn completes
    /// and the response text is ready. Copies the description to the
    /// clipboard so Steph can paste it straight into chat without
    /// reformatting, prints a preview to the console so he can
    /// confirm the response landed, and clears the in-flight flag so
    /// the next press is unblocked.
    @MainActor
    private func handleVideoWatchResponseText(_ description: String) {
        // v15p3fs (2026-05-17): cancel the response timeout — we got
        // a real response in time.
        videoWatchResponseTimeoutTask?.cancel()
        videoWatchResponseTimeoutTask = nil

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            print("⚠️ Watch mode response was empty")
            // v15p3fv (2026-05-17): error cue so Steph hears that
            // something went wrong even when there's nothing on the
            // clipboard to paste.
            ClickySoundEngine.shared.play(.vttError)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            let preview = trimmed
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(140)
            print("👁️ Watch mode response (copied to clipboard, \(trimmed.count) chars): \(preview)")
            // v15p3fv (2026-05-17): success cue so Steph knows the
            // description landed on his clipboard and is ready to
            // paste. Without this, watch mode felt like "release and
            // hope" — no signal at all that the response had arrived.
            ClickySoundEngine.shared.play(.vttSuccess)
        }
        isVideoWatchResponseInFlight = false
    }

    // MARK: - Double-tap toggles (v11f, 2026-04-27)
    //
    // Steph wanted hotkeys for VTT and typing-mode that he doesn't have to
    // hold down for long sessions. Double-tap a single modifier alone (Ctrl
    // for VTT, Cmd for typing) to lock the mode on. Double-tap again, OR
    // press Esc, to unlock. Hold variants (⌃Fn, ⌘Fn) keep working untouched.
    //
    // Implementation: each toggle synthesizes the existing .pressed/.released
    // transitions on the hold path. The dictation flow doesn't know whether
    // the user is holding or has toggled — same behavior either way. Toggle
    // engagement is mutually exclusive: starting one toggle releases the other.

    /// Double-tap Ctrl alone → engage VTT lock. If already locked, no-op
    /// (single-tap is the disengage path now). If typing is locked, swap.
    private func handleVoiceToTextDoubleTapEngage() {
        guard !isVoiceToTextToggleLocked else { return }
        print("🔒 VTT toggle: engaging (double-tap Ctrl) — provider=Deepgram")
        if isTypingToggleLocked {
            disengageTypingToggle()
        }
        isVoiceToTextToggleLocked = true
        // v15p3bw (2026-05-13): post-swap, double-tap Ctrl engages the
        // Deepgram VTT toggle (Deepgram is now primary on Fn+Ctrl).
        handleVoiceToTextDeepgramTransition(.pressed)
    }

    /// Double-tap Cmd alone → engage typing-mode lock.
    private func handleTypingDoubleTapEngage() {
        guard !isTypingToggleLocked else { return }
        print("🔒 Typing toggle: engaging (double-tap Cmd)")
        if isVoiceToTextToggleLocked {
            disengageVoiceToTextToggle()
        }
        isTypingToggleLocked = true
        handleTypingTransition(.pressed)
    }

    /// Single-tap Ctrl alone → disengage VTT lock if active. Confirmed
    /// "single tap" means: <180ms press, no chord during the press, no
    /// second tap within 300ms. If VTT isn't locked, this is a no-op
    /// (we don't want random Ctrl taps to do anything).
    private func handleVoiceToTextSingleTapDisengage() {
        guard isVoiceToTextToggleLocked else { return }
        print("🔒 VTT toggle: disengaging (single-tap Ctrl)")
        disengageVoiceToTextToggle()
    }

    /// Single-tap Cmd alone → disengage typing lock if active.
    private func handleTypingSingleTapDisengage() {
        guard isTypingToggleLocked else { return }
        print("🔒 Typing toggle: disengaging (single-tap Cmd)")
        disengageTypingToggle()
    }

    /// Handles Esc keypress. Universal "stop Clicky and reset" key:
    ///   - Always stops any TTS playback (base voice, burst, replay, etc.)
    ///   - Always cancels any in-flight response Task (Claude call or TTS)
    ///   - Always disengages any locked toggle (VTT, typing, voice mode)
    ///   - Always returns the orb to .idle if it was busy
    ///
    /// Esc is the user's escape hatch — if anything feels stuck, broken,
    /// or just unwanted ("shut up Clicky"), pressing Esc fixes it. The
    /// handler is intentionally aggressive: no guards, just cancel
    /// everything and reset. Idempotent — pressing Esc when nothing is
    /// active is safe (cancel on nil/finished is a no-op, stopPlayback
    /// when no audio is playing is a no-op).
    private func handleEscapeKeyForToggleUnlock() {
        print("🛑 Esc: cancelling response/TTS, releasing toggles, resetting voiceState")

        // Always cancel any in-flight response Task and stop TTS. These
        // are no-ops when nothing is playing, so calling them
        // unconditionally is cheap and removes any guard-mismatch risk.
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        // v13i: panic-clear any phantom stuck modifier-key state at the OS
        // level. Cheap (just posts a few key-up events) and safe even if
        // nothing's actually stuck. Designed to recover from edge cases
        // where a synthesized chord got cancelled mid-sequence.
        Task { @MainActor in
            MacKeyboardSafety.releaseAllModifiers()
        }

        // v13e: hard-kill the streaming-TTS pipeline if it's running.
        // Without this, the player loop is an unstructured Task that keeps
        // draining queued sentences after the parent response Task is
        // cancelled — Esc would only kill the currently-playing chunk and
        // the next sentence would start automatically. Finishing the
        // continuation closes the AsyncStream so the player loop's
        // for-await ends naturally, and cancelling the task itself is
        // belt-and-suspenders for the case where it's mid-await on a
        // synthesis or playback call.
        if let streaming = currentStreamingState {
            streaming.taskContinuation?.finish()
            streaming.playerLoopTask?.cancel()
            currentStreamingState = nil
        }

        // Disengage any locked-on toggle so the user isn't stuck in a
        // hands-free session they wanted to escape from.
        if isVoiceToTextToggleLocked {
            disengageVoiceToTextToggle()
        }
        if isTypingToggleLocked {
            disengageTypingToggle()
        }
        if isVoiceModeToggleLocked {
            disengageVoiceModeToggle()
        }
        // v15p3fy (2026-05-17): cancel an active Watch-mode toggle. Esc
        // is the only way out of a stuck toggle session (next tap of
        // Fn+Opt would generate a response, which the user may not
        // want — Esc is the explicit "cancel, no response" gesture).
        // We force-end the Gemini session via forceEndWatchSession so
        // the disengage cue stays suppressed and the WS tears down
        // cleanly without waiting on a turnComplete that may never
        // come.
        if isVideoWatchToggleLocked || isVideoWatchModeActive {
            print("🛑 Esc: cancelling Watch mode")
            isVideoWatchToggleLocked = false
            isVideoWatchModeActive = false
            isVideoWatchResponseInFlight = false
            videoWatchFrameTimer?.invalidate()
            videoWatchFrameTimer = nil
            videoWatchResponseTimeoutTask?.cancel()
            videoWatchResponseTimeoutTask = nil
            videoWatchPressTimestamp = nil
            geminiRealtimeManager?.forceEndWatchSession()
        }

        // v15p2 (2026-05-02): Realtime emergency stop, smart-split.
        //   • If Marin is currently speaking → interrupt only.
        //     Cancel her response + drain playback. Session stays
        //     alive so the user can speak again immediately. This is
        //     the "wait, stop talking" gesture.
        //   • If session is alive but quiet → end session (full kill).
        //     This is the "we're done here" gesture.
        // v15p2 hotfix (2026-05-03): if Esc is pressed twice within
        // 1.5s, ALWAYS end the session regardless of speaking state.
        // Without this, isModelSpeaking can stay stale (set true on
        // response start, only cleared after grace timer) so two Esc
        // hits in quick succession both saw isModelSpeaking=true and
        // only cancelled. Now the second press force-kills.
        // v15p3ba (2026-05-11): combine BOTH signals so Esc never closes
        // Marin while she's audibly talking. The two signals capture
        // different windows:
        //   - state == .responding: model is in mid-turn (between user
        //     stopping speaking and response.done event)
        //   - isModelCurrentlySpeaking(): isModelSpeaking flag OR
        //     outputBuffersInFlight > 0 — covers TTS audio that's still
        //     draining AFTER response.done fires (state has already gone
        //     back to .listening but Steph still hears her speaking)
        // Either being true means "she's making sound" → cancel only.
        // Both false → she's truly idle/listening → end session.
        let now = Date()
        let isDoubleTap = lastEscapeKeyForRealtime.map {
            now.timeIntervalSince($0) < 3.0
        } ?? false
        lastEscapeKeyForRealtime = now
        if let realtimeManager, realtimeManager.state.isActive {
            if isDoubleTap {
                realtimeManager.endSession()
            } else if realtimeManager.state == .responding
                || realtimeManager.isModelCurrentlySpeaking() {
                realtimeManager.cancelCurrentResponse()
                // Don't end session — user wants to keep talking.
            } else {
                realtimeManager.endSession()
            }
        }
        // v15p3eh + v15p3eu: smart-split Escape for Gemini Marin.
        //
        // v15p3eu refines hands-free behavior. Previous v15p3eh sent
        // ALL Escape presses in hands-free straight to disengage,
        // which ended the session entirely (state=.idle, indicator
        // turned off, you had to re-engage). Steph wanted Escape to
        // just stop her current speech and stay engaged so he could
        // immediately keep talking. Refined behavior:
        //
        //   - Hands-free + she's speaking: cancel response, stay engaged
        //   - Hands-free + she's idle:    disengage (you're done)
        //   - Hands-free + double-tap:    disengage (explicit "done")
        //   - PTT + she's speaking:       cancel response, session stays
        //   - PTT + idle:                 end session
        //   - PTT + double-tap:           end session (explicit)
        //
        // Disengage path uses single-tap-Opt handler so the persisted
        // isRealtimeHandsFreeEnabled flag and sound cues fire correctly.
        if let gemini = geminiRealtimeManager, gemini.state.isActive {
            let isSpeaking = gemini.state == .responding || gemini.isModelCurrentlySpeaking()
            if isRealtimeHandsFreeEnabled {
                if isDoubleTap {
                    handleOptionSingleTapForRealtimeHandsFree()
                } else if isSpeaking {
                    // Stop her current speech, stay in hands-free.
                    gemini.cancelCurrentResponse()
                } else {
                    // Quiet press in hands-free = "we're done."
                    handleOptionSingleTapForRealtimeHandsFree()
                }
            } else if isDoubleTap {
                gemini.endSession()
            } else if isSpeaking {
                gemini.cancelCurrentResponse()
            } else {
                gemini.endSession()
            }
        }

        // v15p3l (2026-05-08): force-cancel any in-flight dictation BEFORE
        // touching voiceState. Esc has been theatrical for a class of
        // stuck-spinner bugs because setting voiceState=.idle directly
        // would get immediately overwritten by the Combine binding at
        // line 1271 — that binding watches isFinalizingTranscript /
        // isPreparingToRecord / isRecordingFromKeyboardShortcut and re-
        // computes voiceState from them within milliseconds. So if any
        // dictation flag was stuck true, Esc → idle → binding fires →
        // back to .processing, instantly. cancelCurrentDictation clears
        // ALL the flags via resetSessionState, so the binding then
        // computes idle correctly and stays there.
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)

        // Belt-and-suspenders: also clear any pending Task that might
        // re-set a dictation flag after cancelCurrentDictation runs.
        pendingVoiceToTextShortcutStartTask?.cancel()
        pendingVoiceToTextShortcutStartTask = nil
        pendingTypingShortcutStartTask?.cancel()
        pendingTypingShortcutStartTask = nil

        // NOW force voiceState to idle if it's in any active state.
        // The dictation flags above are already cleared so the binding
        // won't fight us this time.
        if voiceState != .idle {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    private func disengageVoiceToTextToggle() {
        guard isVoiceToTextToggleLocked else { return }
        isVoiceToTextToggleLocked = false
        // v15p3bw (2026-05-13): post-swap, the toggle drives the Deepgram
        // handler (since Fn+Ctrl is now Deepgram primary). Synthesize
        // .released so the dictation manager finalizes cleanly.
        handleVoiceToTextDeepgramTransition(.released)
    }

    // MARK: - v12s: Hands-free base voice mode (double-tap Option)
    //
    // Double-tap Option engages a click-to-capture-friendly voice session.
    // Unlike hold-to-talk (Ctrl+Opt), no modifiers are held during the
    // session — clicks work normally so the user can navigate, click
    // through workflows, and have each click captured as a pre/post
    // screenshot pair. Single-tap Option or Esc disengages and ships
    // the captured frames + transcript to Claude.

    private func handleVoiceModeDoubleTapEngage() {
        guard !isVoiceModeToggleLocked else { return }
        // Don't engage if dictation is mid-flight from a different mode.
        guard ensureDictationReady() else { return }
        guard !showOnboardingVideo else { return }
        print("🔒 Voice mode toggle: engaging (double-tap Opt) — click-to-capture armed")

        // Engagement is mutually exclusive with VTT/typing toggles. If
        // either is active, disengage them first so we don't end up with
        // overlapping sessions.
        if isVoiceToTextToggleLocked {
            disengageVoiceToTextToggle()
        }
        if isTypingToggleLocked {
            disengageTypingToggle()
        }

        isVoiceModeToggleLocked = true
        // Synthesize .pressed on the base PTT path — same engage logic
        // as holding Ctrl+Opt: starts dictation AND arms click-to-capture.
        handleShortcutTransition(.pressed)
    }

    private func handleVoiceModeSingleTapDisengage() {
        guard isVoiceModeToggleLocked else { return }
        print("🔒 Voice mode toggle: disengaging (single-tap Opt)")
        disengageVoiceModeToggle()
    }

    private func disengageVoiceModeToggle() {
        guard isVoiceModeToggleLocked else { return }
        isVoiceModeToggleLocked = false
        // Synthesize .released — same path as releasing a Ctrl+Opt hold:
        // ends dictation, disarms click-to-capture, ships frames+transcript
        // to Claude.
        handleShortcutTransition(.released)
    }

    // MARK: - v15p2 (2026-05-02) — hotkey-swap handlers
    //
    // After the swap, the Option-tap publishers route to Realtime
    // hands-free, and Fn+Shift+Opt routes to Base voice-mode. Three
    // new handlers below; they delegate to the existing
    // engage/disengage primitives.

    /// Double-tap Option → engage Realtime hands-free (was Base voice-
    /// mode pre-swap). Same effect as Fn+Cmd+Opt before this swap, just
    /// with easier ergonomics.
    ///
    /// v15p3ed (2026-05-16): dispatches to the active provider (Marin
    /// OpenAI Realtime vs Gemini Live) based on the marinUsingGemini
    /// flag. Same hotkey, same hands-free UX, runtime-swappable via
    /// the panel toggle.
    private func handleOptionDoubleTapForRealtimeHandsFree() {
        guard ensureDictationReady() else { return }
        guard !showOnboardingVideo else { return }
        // v15p2 hotfix (2026-05-03): only no-op if BOTH the persisted
        // flag is on AND a session is actually running. Previous logic
        // only checked the flag, which got out of sync when sessions
        // ended for other reasons (Esc, error, race) — leaving Steph
        // unable to re-engage without first toggling something else.
        // v15p3ed: check the active provider's state, not just Marin's.
        let actuallyActive: Bool = {
            if marinUsingGemini {
                return geminiRealtimeManager?.state.isActive ?? false
            } else {
                return realtimeManager?.state.isActive ?? false
            }
        }()
        if isRealtimeHandsFreeEnabled && actuallyActive {
            return
        }
        // Otherwise force-engage — even if the persisted flag was
        // already true, the session clearly isn't running, so we need
        // to start one.
        isRealtimeHandsFreeEnabled = true
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        isRealtimeModeActive = true
        // v15p3ez (2026-05-17): play the engage cue for hands-free
        // toggle too. PTT got this via v15p3eq's hotkey-press hook,
        // but the double-tap-Opt continuous path was missing it
        // entirely — Steph reported "no sound when I trigger
        // continuous mode."
        ClickySoundEngine.shared.play(.marinEngage)
        // v15p3ez: initial halo flare so the indicator pulses
        // visibly on engage, then settles — matches the behavior
        // other modes get naturally from their startup audio
        // burst. Marin's audio path is too quiet at engage to
        // produce the flare on its own, so we trigger it explicitly.
        triggerInitialHaloFlare()
        if marinUsingGemini {
            if geminiRealtimeManager == nil {
                geminiRealtimeManager = GeminiRealtimeConversationManager()
                bindGeminiRealtimeManagerState()
            }
            geminiRealtimeManager?.engageContinuousListening()
            print("🎙️ Gemini hands-free → ENGAGED (double-tap Opt)")
        } else {
            if realtimeManager == nil {
                realtimeManager = RealtimeConversationManager()
                bindRealtimeManagerState()
            }
            realtimeManager?.engageContinuousListening()
            print("🎙️ Marin hands-free → ENGAGED (double-tap Opt)")
        }
    }

    /// v15p3ez (2026-05-17): trigger a brief halo flare visible on
    /// Marin engage. Other modes get this naturally from mic startup
    /// transients; Marin's path is too quiet at engage. Set the
    /// realtimeInputAudioLevel briefly; the existing smoothing in
    /// the binding (max with prev * 0.72) decays it over ~10 frames.
    ///
    /// v15p3fd (2026-05-17): 0.15 still too loud per Steph. Down to 0.1.
    private func triggerInitialHaloFlare() {
        realtimeInputAudioLevel = 0.1
    }

    // MARK: - Speed-read (v15p3gt, 2026-05-18)
    //
    // Double-tap Shift triggers RSVP playback of the user's selected
    // text (with clipboard fallback). Flow:
    //   1. Snapshot the user's existing clipboard items.
    //   2. Synth Cmd+C to capture selected text (no-op if nothing selected).
    //   3. Poll the pasteboard change count for ~200ms.
    //   4. If we captured a selection, use it. Otherwise fall back to
    //      whatever was already on the clipboard (which the user may
    //      have just copied from a different app).
    //   5. Restore the original clipboard items so the user's clipboard
    //      isn't clobbered.
    //   6. If "AI compress" setting is on, route the text through
    //      Haiku to strip filler, then load the compressed result into
    //      the overlay. Otherwise load the raw text immediately.

    private func handleShiftDoubleTapForSpeedRead() {
        // Don't engage while another mode owns Clicky's attention.
        if clickyHasActiveAction {
            print("👀 Speed-read: ignored — another mode is active")
            return
        }
        print("👀 Speed-read → engaged (double-tap Shift)")
        ClickyAnalytics.trackPushToTalkStarted()

        let wpm = max(100, min(900, UserDefaults.standard.object(forKey: "clicky.speedRead.wpm") as? Int ?? 400))
        let compressEnabled = UserDefaults.standard.bool(forKey: "clicky.speedRead.aiCompress")

        Task { @MainActor in
            let capturedText = await Self.captureSelectionOrClipboardText()
            guard let text = capturedText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("⚠️ Speed-read: no text captured (no selection, empty clipboard)")
                ClickySoundEngine.shared.play(.vttError)
                return
            }

            // Lazy-create the overlay manager.
            if self.speedReadOverlayManager == nil {
                self.speedReadOverlayManager = SpeedReadOverlayManager()
            }
            guard let overlay = self.speedReadOverlayManager else { return }

            overlay.showOverlay(text: text, startingWPM: wpm, compressing: compressEnabled)

            if compressEnabled {
                // Fire the Haiku compression in the background; once it
                // returns, swap in the compressed text. If it fails,
                // fall back to the original.
                Task {
                    do {
                        let compressed = try await Self.compressForSpeedRead(text: text)
                        await MainActor.run {
                            overlay.loadCompressedText(compressed, startingWPM: wpm)
                        }
                    } catch {
                        print("⚠️ Speed-read: compression failed — \(error.localizedDescription)")
                        await MainActor.run {
                            overlay.compressionFailed(fallbackText: text, startingWPM: wpm)
                        }
                    }
                }
            }
        }
    }

    /// Capture user's selected text via Cmd+C synth. If nothing was
    /// selected, fall back to whatever was already on the clipboard.
    /// Always restores the user's original clipboard before returning.
    // v16ps (2026-06-05): static so Marin's sort_data tool can reuse it
    // (uses only Self.* statics — no instance state).
    @MainActor
    static func captureSelectionOrClipboardText() async -> String? {
        let savedItems = Self.snapshotGeneralPasteboardItems()
        let originalText = NSPasteboard.general.string(forType: .string)
        let changeCountBeforeCopy = NSPasteboard.general.changeCount

        Self.synthesizeCommandC()

        // Poll up to 200ms for a pasteboard change indicating a real
        // selection was copied.
        let pollDeadline = Date().addingTimeInterval(0.2)
        var capturedSelection: String?
        while Date() < pollDeadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if NSPasteboard.general.changeCount != changeCountBeforeCopy {
                let candidate = NSPasteboard.general.string(forType: .string) ?? ""
                if !candidate.isEmpty {
                    capturedSelection = candidate
                }
                break
            }
        }

        // Restore the user's original clipboard regardless of outcome.
        Self.restoreGeneralPasteboardItems(savedItems)

        if let selection = capturedSelection,
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selection
        }
        // Fallback: use the pre-existing clipboard text.
        if let original = originalText,
           !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return original
        }
        return nil
    }

    /// Route text through Haiku via the Cloudflare Worker's
    /// /voice-command endpoint. We piggyback on the polish flow: pass
    /// the source text as `fieldText` and a "compress for speed read"
    /// modifier. Haiku returns a denser version that feeds the RSVP
    /// timer.
    private static func compressForSpeedRead(text: String) async throws -> String {
        guard let url = URL(string: "\(workerBaseURL)/voice-command") else {
            throw NSError(domain: "SpeedReadCompress", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad worker URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "command": "polish",
            "fieldText": text,
            "modifier": "Compress this for fast reading. Strip filler, redundancy, hedging, and meta-commentary. Preserve every concrete fact, number, name, and step. Output the dense version only — no preamble, no quotes, no explanation. Aim for 40-60% of the original length.",
            "polishStyle": "compress"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(domain: "SpeedReadCompress", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Worker returned \(http.statusCode): \(bodyText.prefix(200))"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SpeedReadCompress", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse worker response"])
        }
        // The polish endpoint returns the cleaned text under several
        // possible keys depending on worker version. Check all common
        // shapes.
        let candidates: [String] = [
            (json["polished"] as? String) ?? "",
            (json["result"] as? String) ?? "",
            (json["text"] as? String) ?? "",
            (json["output"] as? String) ?? ""
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw NSError(domain: "SpeedReadCompress", code: -3,
                      userInfo: [NSLocalizedDescriptionKey: "No usable text field in worker response"])
    }

    /// Single-tap Option → disengage Realtime hands-free.
    ///
    /// v15p3ed (2026-05-16): provider-agnostic — dispatches to whichever
    /// manager is currently running. We disengage BOTH if both somehow
    /// got engaged (defensive), since the hands-free flag is shared.
    private func handleOptionSingleTapForRealtimeHandsFree() {
        guard isRealtimeHandsFreeEnabled else { return }
        isRealtimeHandsFreeEnabled = false
        if let manager = realtimeManager, manager.state.isActive {
            manager.disengageContinuousListening()
            manager.endSession()
        }
        if let gemini = geminiRealtimeManager, gemini.state.isActive {
            gemini.disengageContinuousListening()
        }
        print("🎙️ Realtime hands-free → DISENGAGED (single-tap Opt)")
        scheduleTransientHideIfNeeded()
    }

    /// Fn+Shift+Opt single-tap → toggle Base voice-mode (was Realtime
    /// hands-free pre-swap).
    private func handleFnShiftOptForBaseVoiceMode(
        _ transition: BuddyPushToTalkShortcut.ShortcutTransition
    ) {
        guard transition == .pressed else { return }
        guard ensureDictationReady() else { return }
        guard !showOnboardingVideo else { return }
        if isVoiceModeToggleLocked {
            print("🔒 Base voice-mode toggle: disengaging (Fn+Shift+Opt)")
            disengageVoiceModeToggle()
        } else {
            print("🔒 Base voice-mode toggle: engaging (Fn+Shift+Opt)")
            handleVoiceModeDoubleTapEngage()
        }
    }

    // MARK: - VoiceState Watchdog (v11p)

    /// Schedule the 10s force-clear timer. Called by the $voiceState sink
    /// every time voiceState enters .processing. If it doesn't change to
    /// a non-processing state in 10s, force-clear everything.
    private func scheduleVoiceStateWatchdog() {
        voiceStateWatchdogTask?.cancel()
        let scheduledAt = Date()
        print("🛡️ Watchdog armed at \(dateFormatterDebug.string(from: scheduledAt)) (10s)")
        voiceStateWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self else { return }
            guard !Task.isCancelled else {
                print("🛡️ Watchdog cancelled before fire")
                return
            }
            // Only act if still .processing — the sink may have already
            // fired cancelVoiceStateWatchdog on a state change since.
            guard self.voiceState == .processing else {
                print("🛡️ Watchdog passed (state=\(self.voiceState))")
                return
            }
            print("⚠️ VoiceState watchdog: stuck on .processing >10s (isPreparing=\(self.buddyDictationManager.isPreparingToRecord) isFinalizing=\(self.buddyDictationManager.isFinalizingTranscript) isRecording=\(self.buddyDictationManager.isRecordingFromKeyboardShortcut)). Force-clearing.")
            self.currentResponseTask?.cancel()
            self.currentResponseTask = nil
            self.pendingVoiceToTextShortcutStartTask?.cancel()
            self.pendingVoiceToTextShortcutStartTask = nil
            self.pendingTypingShortcutStartTask?.cancel()
            self.pendingTypingShortcutStartTask = nil
            self.buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Cancel the in-flight watchdog. Called when voiceState leaves
    /// .processing for any reason (idle, listening, responding).
    private func cancelVoiceStateWatchdog() {
        if voiceStateWatchdogTask != nil {
            print("🛡️ Watchdog cleared (state left .processing)")
        }
        voiceStateWatchdogTask?.cancel()
        voiceStateWatchdogTask = nil
    }

    /// Date formatter for watchdog diagnostic logging.
    private let dateFormatterDebug: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func disengageTypingToggle() {
        guard isTypingToggleLocked else { return }
        isTypingToggleLocked = false
        handleTypingTransition(.released)
    }

    /// Handles the Fn+Opt capture-to-inbox shortcut. Mirrors
    /// `handleVoiceToTextTransition` end-to-end — same dictation path,
    /// same raw transcription, same smart-space rule — but instead of
    /// pasting into the focused field, the finalized transcript is
    /// appended to the user's Obsidian Idea Inbox.
    private func handleCaptureToInboxTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p2 (2026-05-03): suspend Marin if she's running.
            markOtherModePressed("captureToInbox")
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }

            // Bring the overlay forward so the yellow waveform gives
            // immediate feedback.
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Capture-to-inbox is a pure write path — don't let any
            // in-flight Claude/TTS interaction ride over the top of it.
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            // v15p3dd (2026-05-15): capture-to-inbox start sound cue.
            ClickySoundEngine.shared.play(.vttStart)

            isCaptureToInboxModeActive = true

            pendingCaptureToInboxShortcutStartTask?.cancel()
            pendingCaptureToInboxShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self.appendToIdeaInbox(finalTranscript)
                    }
                )
            }

        case .released:
            // v15p2 (2026-05-03): release Marin suspension for capture-to-inbox.
            markOtherModeReleased("captureToInbox")
            ClickyAnalytics.trackPushToTalkReleased()
            isCaptureToInboxModeActive = false
            pendingCaptureToInboxShortcutStartTask?.cancel()
            pendingCaptureToInboxShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Polish Hotkey + Voice Command Bus
    //
    // Polish operates on text already in the focused field (not on new
    // spoken input). Two entry points share the same backend so they
    // can never drift in behavior:
    //
    //   1. ⌃⌥⌘ tap — pure keyboard, no voice.
    //   2. ⇧Fn voice-to-text + transcript starts with "polish" — voice
    //      command bus (see pasteVoiceToTextTranscript for the routing).
    //
    // Both call executePolishCommandOnFocusedField, which reads the
    // field text + selection via AX, posts to /voice-command on the
    // Worker, and pastes the cleaned result back via typeTextViaClipboard.

    /// Handles the ⌃⌥⌘ polish hotkey. Supports both quick-tap and
    /// hold-and-speak forms:
    ///
    ///   - Tap (released within `polishHotkeyHoldThresholdSeconds`)
    ///     → fire polish with no modifier. Instant — no audio capture.
    ///   - Hold (held longer than the threshold) → engage dictation for
    ///     a spoken modifier ("more formal" / "shorter" / "make it
    ///     punchier"), then on release fire polish with that as modifier.
    ///
    /// The 300ms threshold is short enough that intentional taps clear
    /// it easily and intentional holds blow past it without thinking,
    /// so the user never has to reason about "did I hold long enough."
    private static let polishHotkeyHoldThresholdSeconds: TimeInterval = 0.3

    // MARK: - Realtime conversation handler (v15p2, 2026-05-02)
    //
    // Press Fn+Opt → start (or resume warm) OpenAI Realtime session.
    // Release Fn+Opt → commit pending audio, request response, schedule
    // 2-minute auto-close.

    private func handleRealtimeTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }

            // Cancel any in-flight Claude/TTS so Realtime doesn't fight
            // for the audio device.
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()

            // Bring overlay forward so the magenta indicator confirms
            // engagement immediately.
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Flip flag so cursor goes magenta.
            isRealtimeModeActive = true

            // v15p3eq (2026-05-17): fire the engage cue HERE on press,
            // not buried inside the manager's state = .listening branch.
            // Previously the cue was gated on setupComplete + vision
            // capture + activity_start (~500ms total). Steph reported
            // the cue played AFTER the perceptible delay, defeating
            // its purpose as instant audible feedback. Now it fires
            // the moment the hotkey lands.
            ClickySoundEngine.shared.play(.marinEngage)
            // v15p3ez (2026-05-17): trigger initial halo flare so the
            // indicator pulses visibly on engage like other modes do.
            triggerInitialHaloFlare()

            // v15p3et (2026-05-17): PTT barge-in. If Marin is
            // currently mid-response when Steph re-presses the
            // hotkey, treat the press as a barge-in: silence her
            // playback immediately so she doesn't talk over his
            // new utterance. The resume path in startSession will
            // then open a fresh user turn cleanly. Steph confirmed
            // PTT barge-in via re-press is the desired behavior
            // (continuous mode uses Escape for the same purpose).
            if marinUsingGemini {
                if let gemini = geminiRealtimeManager,
                   gemini.state == .responding || gemini.isModelCurrentlySpeaking() {
                    gemini.cancelCurrentResponse()
                }
            } else {
                if let marin = realtimeManager,
                   marin.state == .responding || marin.isModelCurrentlySpeaking() {
                    marin.cancelCurrentResponse()
                }
            }

            // v15p3di (2026-05-16): route through the dispatcher so the
            // active Marin provider (OpenAI or Gemini) is picked at
            // session start. Same hotkey, runtime switch via panel.
            startActiveRealtimeManager()

        case .released:
            // v15p3dn (2026-05-16): both providers now have the same
            // semantic — release stops capturing audio, waits for the
            // response to come back, then auto-closes the session.
            // Gemini's version was added in v15p3dn so this can route
            // symmetrically; the previous direct endSession was killing
            // the WebSocket before Sulafat had time to respond.
            if marinUsingGemini {
                geminiRealtimeManager?.handleHotkeyRelease()
            } else {
                realtimeManager?.handleHotkeyRelease()
            }

        case .none:
            break
        }
    }

    /// v15p3gv (2026-05-18): lazily create the advance-input monitor
    /// and start it. Idempotent — safe to call from refreshAllPermissions.
    private func installMarinAdvanceInputMonitorIfNeeded() {
        if marinAdvanceInputMonitor != nil { return }
        let monitor = MouseSideButtonMonitor()
        marinAdvanceInputMonitor = monitor
        marinAdvanceInputCancellable = monitor.advanceTriggeredPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trigger in
                self?.handleMarinStepAdvance(trigger: trigger)
            }
        monitor.startMonitoring()
        RealtimeConversationManager.appendDiag(
            "[advance-input] monitor installed (side mouse buttons + caps lock)"
        )
    }

    /// Send a silent "next step" turn to whichever Marin provider is
    /// currently active. Captures a fresh screenshot under the hood so
    /// the model can see what just changed on screen (Steph completed
    /// a click) before generating the next instruction.
    private func handleMarinStepAdvance(trigger: MouseSideButtonMonitor.AdvanceTrigger) {
        let triggerLabel: String = {
            switch trigger {
            case .middleMouseButton:
                return "middle-mouse-button"
            case .leftCmdTap:
                return "left-cmd-tap"
            }
        }()
        // Cue text matches what Steph naturally says — short, neutral.
        // The actual response is shaped by the GUIDANCE MODE rules in
        // the system prompt (one step per reply, brief, etc.).
        let cueText = "done with that step, what's next?"

        if let gemini = geminiRealtimeManager, gemini.state.isActive {
            RealtimeConversationManager.appendDiag(
                "[advance-input] \(triggerLabel) → gemini.sendSilentAdvanceTurn"
            )
            gemini.sendSilentAdvanceTurn(cueText: cueText)
            return
        }
        // Marin OpenAI Realtime provider doesn't have an equivalent
        // silent-advance API yet — log and no-op so the trigger is
        // discoverable but doesn't crash. Add the OpenAI side when
        // Steph reports needing it (he's currently on Gemini Marin).
        if let marin = realtimeManager, marin.state.isActive {
            RealtimeConversationManager.appendDiag(
                "[advance-input] \(triggerLabel) → marin-openai active but silent-advance not yet wired for OpenAI provider; no-op"
            )
            return
        }
        RealtimeConversationManager.appendDiag(
            "[advance-input] \(triggerLabel) fired but no Marin session active — should have been gated, race?"
        )
    }

    private func bindRealtimeManagerState() {
        guard let manager = realtimeManager else { return }
        realtimeManagerStateCancellable = manager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let priorActive = self.isRealtimeModeActive
                self.isRealtimeModeActive = state.isActive
                self.realtimeSessionState = state
                // v15p3bb (2026-05-11): trace flips of isRealtimeModeActive
                // so we can debug "magenta turned blue" reports — that bug
                // can only happen if isRealtimeModeActive went false (or
                // suspended-by-other-mode is interfering, fixed below).
                if priorActive != state.isActive {
                    RealtimeConversationManager.appendDiag(
                        "isRealtimeModeActive flip: \(priorActive) → \(state.isActive) (state=\(state))"
                    )
                    // v15p3gv (2026-05-18): same advance-gate flip the
                    // Gemini path does — see bindGeminiRealtimeManagerState.
                    MouseSideButtonMonitor.setMarinActive(state.isActive)
                }
                if !state.isActive {
                    self.scheduleTransientHideIfNeeded()
                }
            }
        // v15p2 (2026-05-03): bind Marin's mic input level into the
        // shared currentAudioPowerLevel so the indicator pulses with
        // voice while she's listening (was flat-line before — the
        // legacy buddyDictationManager level is 0 when Marin owns
        // the mic).
        //
        // v15p3 (2026-05-06): the original bridge passed raw RMS through
        // unboosted, but legacy `updateAudioPowerLevel` in
        // BuddyDictationManager applies `rms * 10.2` (clamped) PLUS a
        // decay-smoothing pass (max with prev * 0.72). Without those, the
        // EdgeLineIndicator halo never expanded meaningfully — typical
        // Realtime RMS is 0.01-0.05 even during speech, and `pow(level,
        // 0.55)` then yields a halo extension of <15px on a 3px core.
        // User read this as "solid pink bar — pulsing gradient isn't
        // working." Mirror legacy's boost + smoothing here so both audio
        // sources hand the indicator comparable amplitudes.
        realtimeInputAudioLevelCancellable = manager.$inputAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                guard let self else { return }
                let boosted = CGFloat(min(max(rms * 10.2, 0), 1))
                let smoothed = max(boosted, self.realtimeInputAudioLevel * 0.72)
                self.realtimeInputAudioLevel = smoothed
            }
        // v15p2 (2026-05-03): mirror live transcripts so the panel
        // can show them in real time.
        realtimeUserTranscriptCancellable = manager.$liveUserTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.realtimeUserTranscript = transcript
            }
        realtimeAssistantTranscriptCancellable = manager.$liveAssistantTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.realtimeAssistantTranscript = transcript
            }
        realtimeCompletedTurnsCancellable = manager.$completedTurns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] turns in
                self?.realtimeCompletedTurns = turns
            }
        // v15p3fa (2026-05-17): mirror Marin output level so overlay
        // can tell when she's audibly speaking (vs just generating).
        realtimeOutputAudioLevelCancellable = manager.$outputAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                self?.realtimeOutputAudioLevel = CGFloat(min(max(rms, 0), 1))
            }
    }

    /// v15p3di (2026-05-16): mirror Gemini manager state onto the same
    /// CompanionManager properties the OpenAI binding writes to, so the
    /// indicator UI, hotkey logic, and other observers stay
    /// provider-agnostic. Only state + inputAudioLevel are bound — v1
    /// Gemini path doesn't emit transcripts or completedTurns. Empty
    /// transcripts are acceptable; the overlay just won't show them.
    private func bindGeminiRealtimeManagerState() {
        guard let manager = geminiRealtimeManager else { return }
        geminiRealtimeManagerStateCancellable = manager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let priorActive = self.isRealtimeModeActive
                self.isRealtimeModeActive = state.isActive
                self.realtimeSessionState = state
                if priorActive != state.isActive {
                    RealtimeConversationManager.appendDiag(
                        "[gemini] isRealtimeModeActive flip: \(priorActive) → \(state.isActive) (state=\(state))"
                    )
                    // v15p3gv (2026-05-18): flip the side-button/caps-lock
                    // advance gate. While Marin is active, those inputs
                    // get consumed and advance the guidance flow. While
                    // she's inactive, they pass through normally (caps
                    // lock toggles, browser back/forward works).
                    MouseSideButtonMonitor.setMarinActive(state.isActive)
                }
                if !state.isActive {
                    self.scheduleTransientHideIfNeeded()
                }
            }
        geminiRealtimeInputAudioLevelCancellable = manager.$inputAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self else { return }
                // v15p3fm (2026-05-17): PURE PASS-THROUGH. Manager
                // already applied Buddy's full math chain (raw RMS
                // × 10.2 boost, smoothed with prev * 0.72, dispatched
                // to main). Mirrors how Buddy publishes its already-
                // processed currentAudioPowerLevel directly. Removing
                // the double-smooth + double-boost that was happening
                // here was Audit Fix #1 + #2 — gave us a different
                // temporal shape than Buddy's halo.
                self.realtimeInputAudioLevel = CGFloat(level)
            }
        // v15p3fa (2026-05-17): also mirror output level — overlay
        // uses this to detect "Marin is audibly speaking right now"
        // and hide the static spinner in favor of audio-reactive dot.
        //
        // v15p3fg (2026-05-17): also drive realtimeInputAudioLevel
        // from output while Marin is audibly speaking — so the halo
        // modulates with her voice instead of going dead during her
        // speech. Uses a moderate 3x boost (vs 7x for user speech)
        // because her TTS audio is generally louder than raw mic
        // and we want subtle modulation, not maxed-out flares.
        geminiOutputAudioLevelCancellable = manager.$outputAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                guard let self else { return }
                self.realtimeOutputAudioLevel = CGFloat(min(max(rms, 0), 1))
                if self.realtimeMarinAudioStarted {
                    // v15p3fn (2026-05-17): drop output boost from 4.0
                    // → 1.5. At 4.0, RMS of 0.25 (typical TTS) was
                    //  pinning halo at 1.0 ceiling — looked "way too
                    // large AND frozen" because max() smoothing can't
                    // decay while boosted stays saturated. At 1.5x,
                    // RMS 0.1-0.25 → boosted 0.15-0.375 → halo lives
                    // in modulatable range and tracks her voice
                    // chunk-to-chunk variation visibly.
                    let boosted = CGFloat(min(max(rms * 1.5, 0), 1))
                    let smoothed = max(boosted, self.realtimeInputAudioLevel * 0.72)
                    self.realtimeInputAudioLevel = smoothed
                }
            }
        // v15p3ff (2026-05-17): bind the sticky audio-started flag.
        geminiMarinAudioStartedCancellable = manager.$marinAudioStartedThisTurn
            .receive(on: DispatchQueue.main)
            .sink { [weak self] started in
                self?.realtimeMarinAudioStarted = started
            }
    }

    /// v15p3di (2026-05-16): dispatch helpers. All call sites that
    /// previously poked at `realtimeManager` directly should route
    /// through these so the active-provider toggle works at runtime
    /// without restart.
    private func startActiveRealtimeManager() {
        if marinUsingGemini {
            if geminiRealtimeManager == nil {
                geminiRealtimeManager = GeminiRealtimeConversationManager()
                bindGeminiRealtimeManagerState()
            }
            geminiRealtimeManager?.startSession()
        } else {
            if realtimeManager == nil {
                realtimeManager = RealtimeConversationManager()
                bindRealtimeManagerState()
            }
            realtimeManager?.startSession()
        }
    }

    private func endActiveRealtimeManager() {
        if marinUsingGemini {
            geminiRealtimeManager?.endSession()
        } else {
            realtimeManager?.endSession()
        }
    }

    /// v15p2 (2026-05-02): handle Fn+Cmd+Opt toggle press.
    ///
    /// Behavior:
    ///   • Toggles the persisted isRealtimeHandsFreeEnabled flag.
    ///   • If a Realtime session is currently active, push the new
    ///     state to the running manager (engages or disengages
    ///     server-VAD continuous listening live).
    ///   • If no session is active and the toggle is being turned ON,
    ///     start a session immediately so hands-free engages right
    ///     away rather than waiting for the next Fn+Opt press.
    ///   • If session active in hands-free mode and toggle goes OFF,
    ///     end the session (it was probably a tutoring session — user
    ///     toggling off means "we're done").
    private func handleRealtimeHandsFreeToggleTransition(
        _ transition: BuddyPushToTalkShortcut.ShortcutTransition
    ) {
        guard transition == .pressed else { return }
        guard ensureDictationReady() else { return }
        guard !showOnboardingVideo else { return }

        // Flip the persisted flag.
        isRealtimeHandsFreeEnabled.toggle()
        let nowEnabled = isRealtimeHandsFreeEnabled
        print("🎙️ Realtime hands-free toggle → \(nowEnabled ? "ON" : "OFF")")

        // Bring the overlay forward briefly so the indicator state
        // change is visible.
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Apply to live state if there's an active session OR start one.
        if nowEnabled {
            // Cancel anything competing for the audio device.
            currentResponseTask?.cancel()
            ttsClient.stopPlayback()

            // Set magenta indicator immediately.
            isRealtimeModeActive = true
            // v15p3ez (2026-05-17): engage cue + initial halo flare
            // on this toggle path too. Was missing here as well as
            // the double-tap path.
            ClickySoundEngine.shared.play(.marinEngage)
            triggerInitialHaloFlare()
            // v15p3ed (2026-05-16): dispatch to active provider so
            // Gemini gets hands-free parity with Marin.
            if marinUsingGemini {
                if geminiRealtimeManager == nil {
                    geminiRealtimeManager = GeminiRealtimeConversationManager()
                    bindGeminiRealtimeManagerState()
                }
                geminiRealtimeManager?.engageContinuousListening()
            } else {
                if realtimeManager == nil {
                    realtimeManager = RealtimeConversationManager()
                    bindRealtimeManagerState()
                }
                realtimeManager?.engageContinuousListening()
            }
        } else {
            // Toggle going OFF — disengage whichever provider is live.
            if let manager = realtimeManager, manager.state.isActive {
                manager.disengageContinuousListening()
                manager.endSession()
            }
            if let gemini = geminiRealtimeManager, gemini.state.isActive {
                gemini.disengageContinuousListening()
            }
        }

        scheduleTransientHideIfNeeded()
    }

    private func handlePolishHotkeyTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // v15p2 (2026-05-03): suspend Marin if she's running.
            markOtherModePressed("polish")
            // Don't fire if any other capture is in progress — polish is a
            // pure write path and shouldn't overlap with active dictation.
            guard ensureDictationReady() else { return }
            guard !showOnboardingVideo else { return }
            // Don't double-fire if a polish call is already in flight.
            guard pendingPolishCommandTask == nil else { return }

            // v15p3cu (2026-05-14): polish start sound cue.
            ClickySoundEngine.shared.play(.polishStart)

            polishHotkeyPressedAt = Date()
            isPolishHotkeyHeld = true
            polishHotkeyHoldThresholdPassed = false
            // v15p2 hotfix (2026-05-04, QA #2): clear cancel flag so
            // a stale value from a prior tap doesn't suppress the
            // submit callback for this press.
            polishHotkeyDictationWasCancelled = false

            // v15p2 hotfix (2026-05-04): start dictation IMMEDIATELY on
            // press so the first word of the spoken modifier ("format"
            // in "format response") doesn't get clipped during the 300ms
            // tap-vs-hold threshold. If the user releases before the
            // threshold (a tap), we cancel the dictation cleanly and
            // run instant polish — net behavior identical to before
            // for taps, but holds now capture the full utterance.
            engagePolishHotkeyDictationForSpokenModifier()

            // Threshold timer just flips a flag we read on release.
            // The dictation is already running regardless.
            polishHotkeyHoldEngageTask?.cancel()
            polishHotkeyHoldEngageTask = Task { [weak self] in
                let thresholdNanoseconds = UInt64(Self.polishHotkeyHoldThresholdSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: thresholdNanoseconds)
                guard !Task.isCancelled, let self else { return }
                guard self.isPolishHotkeyHeld else { return }
                self.polishHotkeyHoldThresholdPassed = true
            }

        case .released:
            // v15p2 (2026-05-03): release Marin suspension for polish.
            markOtherModeReleased("polish")
            let polishHotkeyHeldDuration = polishHotkeyPressedAt
                .map { Date().timeIntervalSince($0) } ?? 0

            polishHotkeyPressedAt = nil
            isPolishHotkeyHeld = false
            polishHotkeyHoldEngageTask?.cancel()
            polishHotkeyHoldEngageTask = nil

            let wasHold = polishHotkeyHoldThresholdPassed
            polishHotkeyHoldThresholdPassed = false

            if isPolishHotkeyDictatingForModifier {
                if wasHold {
                    // Hold: stop dictation normally. submitDraftText
                    // callback fires with the captured modifier and
                    // executes polish.
                    isPolishHotkeyDictatingForModifier = false
                    isPolishHotkeyModifierCaptureModeActive = false
                    pendingPolishHotkeyDictationTask?.cancel()
                    pendingPolishHotkeyDictationTask = nil
                    buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                    ClickyAnalytics.trackPushToTalkReleased()
                    return
                }
                // Tap: cancel the dictation and run instant polish.
                // Set the cancel flag BEFORE calling cancel — the
                // submit closure will see it and bail out, preventing
                // a duplicate polish call on partial audio.
                polishHotkeyDictationWasCancelled = true
                isPolishHotkeyDictatingForModifier = false
                isPolishHotkeyModifierCaptureModeActive = false
                pendingPolishHotkeyDictationTask?.cancel()
                pendingPolishHotkeyDictationTask = nil
                buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
                ClickyAnalytics.trackPushToTalkStarted()
                executePolishCommandOnFocusedField(modifier: nil)
                return
            }

            // Fall-through: dictation never engaged (probably another
            // mode was already active when press fired). Old tap-only
            // behavior — fire instant polish if the press was short.
            if polishHotkeyHeldDuration < Self.polishHotkeyHoldThresholdSeconds {
                ClickyAnalytics.trackPushToTalkStarted()
                executePolishCommandOnFocusedField(modifier: nil)
            }

        case .none:
            break
        }
    }

    /// Called when the polish hotkey has been held past the tap-vs-hold
    /// threshold. Starts dictation so we can capture the spoken modifier;
    /// the submit callback fires polish once the user releases. Mirrors
    /// the structure of handleVoiceToTextTransition's pressed branch but
    /// scoped to polish modifier capture.
    private func engagePolishHotkeyDictationForSpokenModifier() {
        guard ensureDictationReady() else { return }
        guard !showOnboardingVideo else { return }

        isPolishHotkeyDictatingForModifier = true
        isPolishHotkeyModifierCaptureModeActive = true

        // Bring the overlay forward so the user sees the cyan tint +
        // waveform feedback during modifier capture.
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        clearDetectedElementLocation()

        ClickyAnalytics.trackPushToTalkStarted()

        pendingPolishHotkeyDictationTask?.cancel()
        pendingPolishHotkeyDictationTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { [weak self] finalSpokenModifierTranscript in
                    guard let self else { return }
                    // v15p2 hotfix (2026-05-04, QA #2): the closure
                    // captures `self` and can fire AFTER the user
                    // released as a tap (which calls
                    // cancelCurrentDictation). Without this guard,
                    // the partial transcribed audio (~50-150ms) would
                    // be applied as a polish modifier in addition to
                    // the explicit instant-polish from the release
                    // path — net result: polish ran twice on a tap.
                    // Set by the tap-release path; cleared on press.
                    if self.polishHotkeyDictationWasCancelled {
                        return
                    }
                    self.lastTranscript = finalSpokenModifierTranscript
                    ClickyAnalytics.trackUserMessageSent(transcript: finalSpokenModifierTranscript)

                    let trimmedSpokenModifier = finalSpokenModifierTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedModifier = trimmedSpokenModifier.isEmpty ? nil : trimmedSpokenModifier

                    self.executePolishCommandOnFocusedField(modifier: resolvedModifier)
                }
            )
        }
    }

    /// Shared backend for both polish entry points (⌃⌥⌘ hotkey AND the
    /// voice "polish" command in voice-to-text mode). Reads the focused
    /// field's existing text (full field, OR selected text if any),
    /// posts to the Worker's /voice-command route, and pastes the
    /// cleaned result back via the same typeTextViaClipboard helper
    /// that typing mode uses. Cmd+V replaces selection by default, so
    /// selection-aware polish needs no special paste handling.
    ///
    /// The flash on the orb (driven by `isPolishCommandFlashActive`)
    /// gives the user a brief visual confirmation the command landed,
    /// since unlike hold-modes there's no waveform to look at.
    private func executePolishCommandOnFocusedField(modifier: String?) {
        // Brief flash so the user has visual confirmation polish fired.
        // Independent of whether the request actually succeeds — the
        // flash means "we heard you," not "polish landed."
        triggerPolishCommandFlash()

        // Capture AX context immediately, BEFORE the async network call,
        // so we're reading the focused-field state at the moment polish
        // was triggered. The user's focus could move during the round
        // trip otherwise.
        let fieldContent = FocusedElementContextProvider.captureFieldContentForPolish()
        let resolvedWorkerBaseURL = Self.workerBaseURL

        // v15p2 (2026-05-04): "format response" voice modifier. Match
        // ONLY at the start of the spoken modifier so phrases like
        // "make this say format response" don't false-trigger. Anything
        // after "format response" (e.g. "format response, make it
        // shorter") becomes the trailing modifier hint.
        let (isFormatResponseIntent, residualModifier) =
            Self.detectFormatResponseIntent(spokenModifier: modifier)

        // Phase-start timestamp for the latency diagnostic log.
        let polishStartedAt = Date()

        pendingPolishCommandTask?.cancel()
        pendingPolishCommandTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.pendingPolishCommandTask = nil
                }
            }

            // Resolve the text to polish: AX-first (preserves selection
            // awareness in apps that expose it), with a clipboard
            // select-all-and-copy fallback for AX-blind apps (Electron-based
            // Slack, Cowork, Discord, etc.). The fallback gives up
            // selection awareness — Cmd+A always selects the whole field
            // — but it makes polish work universally instead of only in
            // the subset of apps that expose AX.
            let resolved = await Self.resolveTextForPolish(fieldContent: fieldContent)
            guard let (textToPolish, isOperatingOnSelection) = resolved else {
                return
            }

            // v15p2 (2026-05-04): capture screenshot for the format-
            // response intent. Lifted from CompanionScreenCaptureUtility
            // (same path Marin uses for vision). Runs before the Worker
            // call so we can include it in the request.
            let captureStartedAt = Date()
            var screenshotJPEG: Data? = nil
            if isFormatResponseIntent {
                do {
                    let capture = try await CompanionScreenCaptureUtility.captureActiveScreenAsJPEG()
                    screenshotJPEG = capture.imageData
                } catch {
                    print("⚠️ Format-response screenshot failed (\(error)) — falling through to text-only polish")
                }
            }
            let captureCompletedAt = Date()

            do {
                let networkStartedAt = Date()
                let detailed = try await Self.sendPolishCommandToWorkerDetailed(
                    workerBaseURL: resolvedWorkerBaseURL,
                    fieldText: textToPolish,
                    modifier: residualModifier,
                    appName: fieldContent?.appName,
                    role: fieldContent?.role,
                    windowTitle: fieldContent?.windowTitle,
                    personalFacts: Self.loadCurrentObsidianMemoryContents(),
                    contextImageJPEG: screenshotJPEG,
                    intent: isFormatResponseIntent ? "format-response" : nil
                )
                let rawPolishedText = detailed.output
                let networkCompletedAt = Date()

                guard !Task.isCancelled else { return }

                // v15p3bh (2026-05-12): preamble-strip guard. The
                // polishSystemPrompt says "Return ONLY the revised text.
                // No preamble..." but Sonnet occasionally violates with
                // "Here's the polished text:" / "I'll polish this:" /
                // similar lead-ins. Strip these client-side so the
                // paste only contains the actual polished output.
                // Pattern: optional intro phrase + colon + optional
                // newlines at the very start of the response.
                let polishedText = Self.stripPolishPreamble(rawPolishedText)

                let trimmedPolishedText = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)

                // v15p3bh diag: log every polish output so we can see
                // when the model returns identical-to-input (no-op),
                // when it leaks reasoning, and what the preamble strip
                // changed. Critical for debugging the "polish did nothing"
                // reports — at-a-glance diff between input and output.
                Self.appendPolishOutputDiag(
                    modifier: modifier,
                    intent: isFormatResponseIntent ? "format-response" : "default",
                    input: textToPolish,
                    rawOutput: rawPolishedText,
                    cleanedOutput: trimmedPolishedText
                )

                guard !trimmedPolishedText.isEmpty else {
                    print("⚠️ Polish: Worker returned empty output; leaving field unchanged")
                    return
                }

                ClickyAnalytics.trackAIResponseReceived(response: trimmedPolishedText)

                // v12n (2026-04-28): em-dash strip belt-and-suspenders.
                // v15p3bh (2026-05-12): replacement changed from " " to
                // ", " because the previous version was eating sentence
                // boundaries. Example before fix:
                //   model output: "Testing polish mode — things look good."
                //   after strip:  "Testing polish mode things look good."
                //                  ^^^ run-on, missing punctuation
                // After fix:      "Testing polish mode, things look good."
                // A comma is a much better default than a space — it
                // preserves the pause/clause-break semantics of the
                // em-dash, never produces a run-on, and downstream
                // double-space collapsing still cleans up "pulls— Total"
                // → "pulls, Total" (vs old " pulls Total" via single space).
                let dashStripped = polishedText.replacingOccurrences(
                    of: #"[ \t]*[—–][ \t]*"#,
                    with: ", ",
                    options: .regularExpression
                )
                let collapsedSpaces = Self.collapseHorizontalDoubleSpaces(dashStripped)

                await Self.replaceFocusedFieldText(
                    polishedText: collapsedSpaces,
                    isOperatingOnSelection: isOperatingOnSelection
                )

                // v11y: persist polish interaction (no screenshot — polish
                // is a text-only operation on the focused field).
                ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
                    id: ClickyTranscriptLogger.newInteractionId(),
                    timestamp: Date(),
                    mode: .polish,
                    rawTranscript: textToPolish,
                    finalOutput: trimmedPolishedText,
                    claudeResponse: nil,
                    polishModifier: modifier,
                    appName: fieldContent?.appName,
                    screenshotPaths: [],
                    polishStatus: "ok"
                ))
                // v15p2 (2026-05-04): timing diagnostic log — establishes
                // baseline for default vs format-response so any future
                // regression is detectable.
                let pasteCompletedAt = Date()
                let captureMs = Int(captureCompletedAt.timeIntervalSince(captureStartedAt) * 1000)
                let networkMs = Int(networkCompletedAt.timeIntervalSince(networkStartedAt) * 1000)
                let pasteMs = Int(pasteCompletedAt.timeIntervalSince(networkCompletedAt) * 1000)
                let totalMs = Int(pasteCompletedAt.timeIntervalSince(polishStartedAt) * 1000)
                let screenshotKB: Int = {
                    guard let bytes = screenshotJPEG?.count else { return 0 }
                    // Worker receives base64, ~4/3 of raw bytes.
                    return (bytes * 4 / 3) / 1024
                }()
                Self.appendPolishTimingLog(
                    intent: isFormatResponseIntent ? "format-response" : "default",
                    captureMs: isFormatResponseIntent ? captureMs : 0,
                    encodeMs: 0, // base64 encode time bundled in network for now
                    networkMs: networkMs,
                    claudeMs: detailed.claudeMs,
                    pasteMs: pasteMs,
                    totalMs: totalMs,
                    fieldChars: textToPolish.count,
                    screenshotKB: screenshotKB
                )
            } catch is CancellationError {
                // User triggered another action mid-flight — drop silently.
            } catch {
                print("⚠️ Polish failed: \(error)")
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            }
        }
    }

    /// Resolve the text that polish should operate on. Three-stage resolution:
    ///
    ///   1. **Primary (AX-first)**: read selected text or full field text
    ///      via the macOS Accessibility API. Zero synthetic delay; instant.
    ///      Works in apps that expose AX (native AppKit apps, browser
    ///      fields via the browser's AX bridge).
    ///   2. **Fallback A (clipboard, selection-aware)**: when AX returns
    ///      nothing, FIRST try Cmd+C alone — if the user has a selection,
    ///      this captures it without disturbing the selection state, so
    ///      selection-aware polish still works in AX-blind apps.
    ///   3. **Fallback B (clipboard, whole field)**: if Fallback A gets
    ///      nothing (no selection), Cmd+A then Cmd+C to grab the entire
    ///      field, polish that.
    ///
    /// Both fallback paths use clipboard *polling* with early exit
    /// instead of fixed-time sleeps, so fast apps return in 30-50ms
    /// instead of always waiting 150ms. Slow apps still get up to a
    /// safety window before giving up.
    ///
    /// Returns nil only when no path produced any text — meaning the
    /// focused field is genuinely empty or non-textual.
    @MainActor
    private static func resolveTextForPolish(
        fieldContent: FocusedElementContextProvider.FocusedFieldContent?
    ) async -> (textToPolish: String, isOperatingOnSelection: Bool)? {
        // PRIMARY: AX-readable text. Zero overhead.
        if let selectedText = fieldContent?.selectedText, !selectedText.isEmpty {
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (selectedText, true)
            }
        }
        if let fullFieldText = fieldContent?.fullFieldText, !fullFieldText.isEmpty {
            let trimmed = fullFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (fullFieldText, false)
            }
        }

        // FALLBACK: AX returned nothing. Use clipboard.
        let appNameForDiagnostic = fieldContent?.appName ?? "nil"
        print("✨ Polish: AX returned no text for app=\(appNameForDiagnostic); using clipboard fallback")

        let savedClipboardItems = snapshotGeneralPasteboardItems()
        // Reset the change count so we can detect when the synthesized
        // Cmd+C actually populates the pasteboard (vs reading stale data
        // from the user's prior copy that happens to still be present).
        let pasteboardChangeCountBeforeCopy = NSPasteboard.general.changeCount

        // FALLBACK A — selection-aware: Cmd+C first. If the user has
        // text selected, this captures it without mutating the selection.
        // If they have nothing selected, the copy is a no-op and the
        // pasteboard change count won't increment.
        synthesizeCommandC()

        let selectionPollDeadline = Date().addingTimeInterval(0.2) // 200ms safety
        var capturedSelectionText: String?
        while Date() < selectionPollDeadline {
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms granularity
            if NSPasteboard.general.changeCount != pasteboardChangeCountBeforeCopy {
                let candidate = NSPasteboard.general.string(forType: .string) ?? ""
                if !candidate.isEmpty {
                    capturedSelectionText = candidate
                }
                break
            }
        }

        if let selectionText = capturedSelectionText,
           !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // We got a selection. Polish only that; the user's selection
            // is still in place (Cmd+C didn't move the cursor or change
            // selection state), so the eventual paste-back will replace
            // exactly the selected range.
            restoreGeneralPasteboardItems(savedClipboardItems)
            print("✨ Polish: clipboard fallback A (selection) got \(selectionText.count) chars")
            return (selectionText, true)
        }

        // FALLBACK B — whole field: no selection detected. Cmd+A then
        // Cmd+C. This destroys any pre-existing selection, but we
        // already verified there was none above (Fallback A's Cmd+C
        // produced nothing). The select-all becomes the new selection;
        // paste-back will replace the whole field.
        let pasteboardChangeCountBeforeSelectAll = NSPasteboard.general.changeCount
        synthesizeCommandA()
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms for select-all to register
        synthesizeCommandC()

        let wholeFieldPollDeadline = Date().addingTimeInterval(0.25) // 250ms safety
        var capturedFullFieldText = ""
        while Date() < wholeFieldPollDeadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if NSPasteboard.general.changeCount != pasteboardChangeCountBeforeSelectAll {
                capturedFullFieldText = NSPasteboard.general.string(forType: .string) ?? ""
                if !capturedFullFieldText.isEmpty { break }
            }
        }

        // Restore the user's original clipboard regardless of outcome.
        restoreGeneralPasteboardItems(savedClipboardItems)

        let trimmedFullFieldText = capturedFullFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFullFieldText.isEmpty else {
            print("✨ Polish: clipboard fallback B got nothing — focused field is empty or non-text; skipping")
            return nil
        }

        print("✨ Polish: clipboard fallback B (whole field) got \(capturedFullFieldText.count) chars")
        // Whole field: Cmd+A already selected everything, so the paste
        // back will replace it. We treat this as isOperatingOnSelection=true
        // so replaceFocusedFieldText doesn't double-select-all.
        return (capturedFullFieldText, true)
    }

    /// Snapshot the current contents of the general pasteboard so it
    /// can be restored after a clipboard-fallback read. Each pasteboard
    /// item is captured as (type, data) pairs to preserve rich formats
    /// (images, RTF, etc.) the user may have copied.
    @MainActor
    private static func snapshotGeneralPasteboardItems() -> [[NSPasteboard.PasteboardType: Data]] {
        let pasteboard = NSPasteboard.general
        return pasteboard.pasteboardItems?.map { item in
            var typeToDataMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeToDataMap[type] = data
                }
            }
            return typeToDataMap
        } ?? []
    }

    /// Write the snapshotted pasteboard contents back to the general
    /// pasteboard. Reverses `snapshotGeneralPasteboardItems`.
    @MainActor
    private static func restoreGeneralPasteboardItems(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { typeToDataMap -> NSPasteboardItem in
            let restoredItem = NSPasteboardItem()
            for (type, data) in typeToDataMap {
                restoredItem.setData(data, forType: type)
            }
            return restoredItem
        }
        pasteboard.writeObjects(restoredItems)
    }

    /// Synthesize a Cmd+C to copy the currently-selected text in the
    /// focused field. Mirror of synthesizeCommandV/synthesizeCommandA;
    /// uses CGEvent so it works regardless of keyboard layout.
    @MainActor
    private static func synthesizeCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key code 8 = 'c' on US layouts. Same semantic-rewrite
        // story as Cmd+V — reliable across keyboard layouts.
        let keyCCode: CGKeyCode = 8

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Pastes `polishedText` into the focused field. If `isOperatingOnSelection`
    /// is true, Cmd+V replaces the selection by default — no select-all needed.
    /// Otherwise we select-all first so Cmd+V replaces the entire field
    /// instead of appending.
    @MainActor
    private static func replaceFocusedFieldText(
        polishedText: String,
        isOperatingOnSelection: Bool
    ) async {
        if !isOperatingOnSelection {
            // Select-all so the upcoming paste replaces the whole field.
            // Cmd+A is universal across text fields on macOS.
            synthesizeCommandA()
            // Brief pause so the destination app processes the
            // selection change before the paste arrives.
            try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
        }
        await typeTextViaClipboard(polishedText)
    }

    /// Synthesize a Cmd+A key down + key up to select-all in the focused
    /// text field. Mirror of synthesizeCommandV; same rationale (CGEvent
    /// works against whatever has keyboard focus, regardless of layout).
    @MainActor
    private static func synthesizeCommandA() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key code 0 = 'a' on US layouts. Same semantic-rewrite
        // story as Cmd+V — reliable across keyboard layouts.
        let keyACode: CGKeyCode = 0

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyACode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyACode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Trigger the brief polish-command flash on the orb. Public-feeling
    /// bool flips on for ~250ms then off, so the overlay can observe and
    /// animate however it likes (currently a quick opacity flicker).
    private func triggerPolishCommandFlash() {
        polishCommandFlashClearTask?.cancel()
        isPolishCommandFlashActive = true
        polishCommandFlashClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            await MainActor.run {
                guard let self else { return }
                self.isPolishCommandFlashActive = false
            }
        }
    }

    /// POST to the Worker's /voice-command route with the polish payload.
    /// Returns the Worker's `output` field (the polished text). Throws
    /// on transport errors and on non-2xx responses.
    ///
    /// `personalFacts` is the optional free-form "things Clicky should
    /// remember" textarea contents. Worker injects them into the polish
    /// system prompt alongside the static memory block so polish has
    /// the same identity + context awareness as PTT and typing mode.
    /// v15p2 (2026-05-04): result type so callers can inspect server-
    /// reported Claude latency for timing diagnostics. The String-only
    /// shim below preserves the existing call sites.
    struct PolishCommandResult {
        let output: String
        let claudeMs: Int
    }

    private static func sendPolishCommandToWorker(
        workerBaseURL: String,
        fieldText: String,
        modifier: String?,
        appName: String?,
        role: String?,
        windowTitle: String?,
        personalFacts: String?,
        modelOverride: String? = nil,
        polishStyle: String? = nil,
        contextImageJPEG: Data? = nil
    ) async throws -> String {
        let detailed = try await sendPolishCommandToWorkerDetailed(
            workerBaseURL: workerBaseURL,
            fieldText: fieldText,
            modifier: modifier,
            appName: appName,
            role: role,
            windowTitle: windowTitle,
            personalFacts: personalFacts,
            modelOverride: modelOverride,
            polishStyle: polishStyle,
            contextImageJPEG: contextImageJPEG,
            intent: nil
        )
        return detailed.output
    }

    private static func sendPolishCommandToWorkerDetailed(
        workerBaseURL: String,
        fieldText: String,
        modifier: String?,
        appName: String?,
        role: String?,
        windowTitle: String?,
        personalFacts: String?,
        modelOverride: String? = nil,
        polishStyle: String? = nil,
        contextImageJPEG: Data? = nil,
        intent: String? = nil
    ) async throws -> PolishCommandResult {
        guard let voiceCommandRouteURL = URL(string: "\(workerBaseURL)/voice-command") else {
            throw NSError(
                domain: "ClickyVoiceCommandError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Worker base URL: \(workerBaseURL)"]
            )
        }
        var request = URLRequest(url: voiceCommandRouteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // v15p4cp (2026-06-01): 9.5s timeout — polish uses Sonnet 4.6 (~1.5-3s
        // typical). Bumped from 8s after a 583-char/107-word toggle polish hit
        // 8009ms and timed out by 9ms. MUST stay below the VTT watchdog's 10s
        // force-clear (scheduleVoiceStateWatchdog) so a slow polish fails
        // gracefully (falls back to the unpolished punctuated text) before the
        // watchdog force-cancels mid-call and loses the transcript entirely.
        // 9.5s is the safe ceiling under that 10s cap.
        request.timeoutInterval = 9.5

        var requestBody: [String: Any] = [
            "command": "polish",
            "fieldText": fieldText,
        ]
        if let modifier = modifier?.trimmingCharacters(in: .whitespacesAndNewlines), !modifier.isEmpty {
            requestBody["modifier"] = modifier
        }
        if let appName, !appName.isEmpty {
            requestBody["app"] = appName
        }
        if let role, !role.isEmpty {
            requestBody["role"] = role
        }
        if let windowTitle, !windowTitle.isEmpty {
            requestBody["windowTitle"] = windowTitle
        }
        if let personalFacts = personalFacts?.trimmingCharacters(in: .whitespacesAndNewlines),
           !personalFacts.isEmpty {
            requestBody["personalFacts"] = personalFacts
        }
        if let modelOverride, !modelOverride.isEmpty {
            requestBody["model"] = modelOverride
        }
        if let polishStyle, !polishStyle.isEmpty {
            requestBody["polishStyle"] = polishStyle
        }
        if let contextImageJPEG {
            // Base64-encode JPEG bytes for the worker's imageBase64 field.
            // ~50-200KB per image after compression, ~70-280KB after base64.
            requestBody["imageBase64"] = contextImageJPEG.base64EncodedString()
        }
        if let intent, !intent.isEmpty {
            requestBody["intent"] = intent
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ClickyVoiceCommandError",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker returned status \(httpResponse.statusCode): \(bodyText)"]
            )
        }

        guard let parsedResponse = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let outputText = parsedResponse["output"] as? String else {
            throw NSError(
                domain: "ClickyVoiceCommandError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Worker response missing 'output' string"]
            )
        }

        let claudeMs = (parsedResponse["claudeMs"] as? Int)
            ?? (parsedResponse["claudeMs"] as? Double).map { Int($0) }
            ?? 0
        return PolishCommandResult(output: outputText, claudeMs: claudeMs)
    }

    // MARK: - Format-response intent detection (v15p2, 2026-05-04)

    /// Match "format response" (and common transcription variants)
    /// at the START of the spoken polish modifier. Returns
    /// (matched, residual) — the residual is the text after the
    /// matched phrase, stripped of leading separators, which
    /// becomes the modifier hint passed to the Worker. So
    /// "format response, make it shorter" → (true, "make it shorter").
    ///
    /// Mid-utterance occurrences ("make this say format response")
    /// don't match — start-of-utterance only, same pattern as the
    /// other voice command verbs.
    ///
    /// v15p2 hotfix (2026-05-04): broadened to handle "format the/
    /// my/this response" and trailing punctuation (transcription
    /// often slips an article or comma in).
    static func detectFormatResponseIntent(spokenModifier: String?) -> (Bool, String?) {
        guard let raw = spokenModifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return (false, spokenModifier)
        }
        // Normalize: lowercase, strip leading/trailing punctuation.
        let punctuationToTrim = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        let cleaned = raw.trimmingCharacters(in: punctuationToTrim)
        let lower = cleaned.lowercased()
        // Match patterns at start (longest first so "format the response"
        // doesn't get matched as "format" leaving " the response" residual).
        let candidatePhrases: [String] = [
            "format the response",
            "format my response",
            "format this response",
            "format that response",
            "format response",
            "format reply",
            "format the reply",
            "format my reply",
            "format the message",
            "match the format",
            "match the formatting",
            "match formatting",
            "match format",
        ]
        var matchedPhrase: String? = nil
        for phrase in candidatePhrases {
            if lower.hasPrefix(phrase) {
                matchedPhrase = phrase
                break
            }
        }
        // v15p2 hotfix2 (2026-05-04): the polish modifier dictation
        // path has a cold-start audio race that often drops the first
        // word ("format" gets clipped, just "response" makes it
        // through). If the cleaned utterance is short and is exactly
        // or ends with "response"/"reply"/"format", treat it as a
        // truncated format-response trigger. The short-length guard
        // (<=20 chars) keeps false positives from real responses
        // containing those words. Also handle the leading-only case
        // like "the response", "my response", "this response".
        if matchedPhrase == nil && lower.count <= 20 {
            let truncatedTriggers: [String] = [
                "response",
                "reply",
                "the response",
                "my response",
                "this response",
                "that response",
                "format",
                "format the",
                "format my",
                "format this",
            ]
            for tr in truncatedTriggers {
                if lower == tr || lower.hasSuffix(" \(tr)") || lower == "\(tr)." {
                    matchedPhrase = tr
                    break
                }
            }
        }
        guard let phrase = matchedPhrase else {
            // Diag: log what the user actually said so we can see why
            // detection missed (and add patterns if they're real).
            print("⚠️ Polish: 'format response' not detected in spoken modifier: \"\(cleaned)\"")
            appendFormatResponseDetectionLog(
                matched: false,
                phrase: nil,
                rawModifier: spokenModifier,
                cleaned: cleaned
            )
            return (false, spokenModifier)
        }
        // Strip the matched phrase + any leading separators from the
        // remaining text. The original `raw` may have had punctuation
        // — work from `cleaned` to keep things simple.
        let afterPhrase = String(cleaned.dropFirst(phrase.count))
        var residual = afterPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingSeparators: [String] = [",", ".", ":", ";", "—", "-", "and ", "then ", "also "]
        var changed = true
        while changed {
            changed = false
            for sep in leadingSeparators {
                if residual.lowercased().hasPrefix(sep.lowercased()) {
                    residual = String(residual.dropFirst(sep.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        print("✅ Polish: format-response intent detected — phrase=\"\(phrase)\" residual=\"\(residual)\"")
        appendFormatResponseDetectionLog(
            matched: true,
            phrase: phrase,
            rawModifier: spokenModifier,
            cleaned: cleaned
        )
        return (true, residual.isEmpty ? nil : residual)
    }

    /// v15p2 (2026-05-04): write detection attempts to a file so we
    /// can debug missed matches without having to read Console.app.
    /// v15p3 (2026-05-06): relabeled MATCHED/MISSED → FORMAT_RESPONSE/
    /// OTHER_MODIFIER. The log fires on EVERY polish-with-modifier
    /// invocation, not just format-response attempts — so most lines
    /// reading "MISSED" are perfectly correct non-format-response
    /// polish modifiers (spelling fixes, content rewrites, etc.). The
    /// old label invited audit-agents to read a 92% "miss rate" as a
    /// regression when it was just the relative frequency of
    /// format-response vs other modifiers.
    private static let formatResponseDetectionLogPath = "/tmp/clicky_format_response_detection.log"
    private static func appendFormatResponseDetectionLog(
        matched: Bool,
        phrase: String?,
        rawModifier: String?,
        cleaned: String
    ) {
        let formatter = ISO8601DateFormatter()
        let label = matched ? "FORMAT_RESPONSE" : "OTHER_MODIFIER"
        let line = "\(formatter.string(from: Date()))\t\(label)\tphrase=\"\(phrase ?? "")\"\traw=\"\(rawModifier ?? "")\"\tcleaned=\"\(cleaned)\"\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: formatResponseDetectionLogPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: formatResponseDetectionLogPath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Polish timing diagnostic log (v15p2, 2026-05-04)

    private static let polishTimingLogPath = "/tmp/clicky_polish_timing.log"
    private static let polishTimingLogQueue = DispatchQueue(
        label: "com.stephenpierson.clickyplus.polish-timing-log"
    )

    /// Append a single line to the polish timing diagnostic log so we
    /// can A/B default vs format-response latency distributions over
    /// real usage. CSV-ish — one line per Polish invocation.
    /// Format: `timestamp,intent,captureMs,encodeMs,networkMs,claudeMs,pasteMs,totalMs,fieldChars,screenshotKB`
    private static func appendPolishTimingLog(
        intent: String,
        captureMs: Int,
        encodeMs: Int,
        networkMs: Int,
        claudeMs: Int,
        pasteMs: Int,
        totalMs: Int,
        fieldChars: Int,
        screenshotKB: Int
    ) {
        polishTimingLogQueue.async {
            let formatter = ISO8601DateFormatter()
            let line = [
                formatter.string(from: Date()),
                intent,
                String(captureMs),
                String(encodeMs),
                String(networkMs),
                String(claudeMs),
                String(pasteMs),
                String(totalMs),
                String(fieldChars),
                String(screenshotKB),
            ].joined(separator: ",") + "\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = polishTimingLogPath
            let url = URL(fileURLWithPath: path)
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                let header = "timestamp,intent,captureMs,encodeMs,networkMs,claudeMs,pasteMs,totalMs,fieldChars,screenshotKB\n".data(using: .utf8) ?? Data()
                try? (header + data).write(to: url)
            }
        }
    }

    // MARK: - Polish output diag log (v15p3bh, 2026-05-12)
    //
    // Separate from polish_timing because it captures CONTENT, not
    // latency. Goal: see at-a-glance when polish returned identical-
    // to-input text (no-op), when the model leaked a preamble or
    // reasoning, and what the client-side strip did about it.

    private static let polishOutputDiagLogPath = "/tmp/clicky_polish_output.log"
    private static let polishOutputDiagLogQueue = DispatchQueue(
        label: "com.stephenpierson.clickyplus.polish-output-diag"
    )

    private static func appendPolishOutputDiag(
        modifier: String?,
        intent: String,
        input: String,
        rawOutput: String,
        cleanedOutput: String
    ) {
        polishOutputDiagLogQueue.async {
            let formatter = ISO8601DateFormatter()
            let preambleStripped = rawOutput.count != cleanedOutput.count
                || rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    != cleanedOutput
            let noOp = input.trimmingCharacters(in: .whitespacesAndNewlines)
                == cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let escape: (String) -> String = { s in
                s.replacingOccurrences(of: "\n", with: "\\n")
                 .replacingOccurrences(of: "\r", with: "")
            }
            let preview = escape(String(cleanedOutput.prefix(160)))
            let inputPreview = escape(String(input.prefix(160)))
            let mod = modifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = [
                formatter.string(from: Date()),
                "intent=\(intent)",
                "modifier=\"\(escape(mod))\"",
                "inLen=\(input.count)",
                "outLen=\(cleanedOutput.count)",
                "noOp=\(noOp)",
                "preambleStripped=\(preambleStripped)",
                "in=\"\(inputPreview)\"",
                "out=\"\(preview)\"",
            ].joined(separator: " | ") + "\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: polishOutputDiagLogPath)
            if FileManager.default.fileExists(atPath: polishOutputDiagLogPath) {
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

    /// v15p3bh (2026-05-12): strip common reasoning/preamble prefixes
    /// from polish output. The polishSystemPrompt forbids preambles
    /// ("Return ONLY the revised text. No preamble..."), but model
    /// output isn't perfectly compliant — occasionally we get
    /// "Here's the polished text:\n\n<actual output>" or similar.
    ///
    /// Strategy: look for a small list of well-known preamble phrasings
    /// at the very start of the response, optionally followed by a
    /// colon and one or more newlines, and strip them. Conservative —
    /// only strips when the match is unambiguous (must be at start,
    /// must include a colon or newline boundary).
    ///
    /// If no pattern matches, returns the input unchanged.
    static func stripPolishPreamble(_ raw: String) -> String {
        let leading = raw.drop(while: { $0.isNewline || $0 == " " || $0 == "\t" })
        let lower = leading.lowercased()
        let patterns: [String] = [
            "here's the polished text:",
            "here's the polished version:",
            "here is the polished text:",
            "here is the polished version:",
            "here's the revised text:",
            "here's the revised version:",
            "here is the revised text:",
            "here is the revised version:",
            "here's the polished response:",
            "here is the polished response:",
            "here's the polish:",
            "here is the polish:",
            "polished text:",
            "polished version:",
            "revised text:",
            "revised:",
            "i'll polish this:",
            "i'll polish this for you:",
            "i'll revise this:",
            "let me polish this:",
            "let me revise this:",
            "sure, here's the polished text:",
            "sure! here's the polished text:",
            "sure, here it is:",
            "okay, here it is:",
        ]
        for pattern in patterns {
            if lower.hasPrefix(pattern) {
                // Strip the matched prefix plus any leading newlines/whitespace
                // that followed it.
                let stripped = leading.dropFirst(pattern.count)
                let cleaned = stripped.drop(while: { $0.isNewline || $0 == " " || $0 == "\t" })
                return String(cleaned)
            }
        }
        return raw
    }

    /// Appends the raw transcript to the user's Obsidian Idea Inbox.
    /// Format: `- YYYY-MM-DD — [?] <transcript>\n`. Empty transcripts
    /// are dropped so a mis-triggered hotkey can't fill the inbox with
    /// blank lines. On success, surfaces a yellow confirmation toast
    /// (`recentIdeaCaptureText`) for ~3 seconds so the user can see
    /// what landed without opening Obsidian.
    private func appendToIdeaInbox(_ transcript: String) {
        let stripped = Self.stripVoiceToTextArtifacts(transcript)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let inboxURL = homeDirectory
            .appendingPathComponent("Desktop/Claude Cowork/Obsidian/Steph Vault/Inbox/Idea Inbox.md")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let datestamp = dateFormatter.string(from: Date())
        let line = "- \(datestamp) — [?] \(trimmed)\n"

        do {
            if !FileManager.default.fileExists(atPath: inboxURL.path) {
                // Create the file if it somehow doesn't exist yet.
                try "".write(to: inboxURL, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: inboxURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            print("📥 Capture-to-inbox appended: \(trimmed)")
        } catch {
            print("⚠️ Capture-to-inbox append failed: \(error)")
            // Fall through — we still show the toast so the user at
            // least sees what they said (and can manually paste it).
        }

        // v11y: persist capture-to-inbox interaction
        ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
            id: ClickyTranscriptLogger.newInteractionId(),
            timestamp: Date(),
            mode: .captureInbox,
            rawTranscript: transcript,
            finalOutput: trimmed,
            claudeResponse: nil,
            polishModifier: nil,
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            screenshotPaths: [],
            polishStatus: nil
        ))

        // Surface the confirmation toast. Any prior toast is replaced.
        recentIdeaCaptureText = trimmed
        captureToInboxToastDismissTask?.cancel()
        captureToInboxToastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.recentIdeaCaptureText = nil
            }
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// Pastes the raw transcript into the focused field. No Claude, no
    /// TTS — just clipboard + Cmd+V. Empty transcripts are dropped
    /// silently so a mis-triggered hotkey can't clobber the focused
    /// field with an empty paste.
    ///
    /// Smart-space rule: before pasting, decide whether to prepend a
    /// single space so back-to-back pastes don't stack. Two signals
    /// feed the decision:
    ///   1. AX `recentText` (tail of focused field). Most accurate,
    ///      but nil/empty in many apps (Slack, Discord, Electron,
    ///      most web text inputs) so we can't rely on it alone.
    ///   2. Local memory of our last voice-to-text paste (char +
    ///      timestamp). Covers the AX-blind case for rapid
    ///      successive pastes, which is the common pattern.
    /// If AX says the field ends in whitespace, we trust it and
    /// skip — even if memory says we just pasted. This handles
    /// manual edits between pastes correctly.
    /// v16qm (2026-06-14): strip hallucinated affirmative backchannels
    /// ("mm-hmm", "mhm", "uh-huh") that STT engines — Scribe especially —
    /// insert on breaths/background noise. Steph never dictates these
    /// intentionally, so ANY occurrence is an artifact. Removes them as
    /// standalone tokens and cleans up the comma/space they leave behind.
    /// Conservative on purpose: only the AFFIRMATIVE backchannels — never
    /// "uh-uh"/"mm-mm", which mean "no" and carry meaning.
    static func stripBackchannelFillers(from text: String) -> String {
        var out = text
        // Remove the token plus any trailing comma/whitespace it arrives wrapped in.
        out = out.replacingOccurrences(
            of: "(?i)\\b(mm[-\\s]?hmm|mhm+|mmhmm|uh[-\\s]?huh)\\b[\\s,]*",
            with: "", options: .regularExpression)
        // Tidy the wreckage: leading commas/space, doubled spaces,
        // space-before-punctuation, and doubled punctuation.
        out = out.replacingOccurrences(of: "(?i)^[\\s,]+", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,.!?])\\1+", with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pasteVoiceToTextTranscript(
        _ transcript: String,
        polishAfterRepunctuate: Bool = false,
        contextScreenshot: CompanionScreenCapture? = nil
    ) {
        let rawTrimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // v16qm: drop hallucinated "mm-hmm"/"mhm"/"uh-huh" before any
        // downstream processing (hold, toggle, repunctuate all see the
        // cleaned text). Runs on every VTT provider, not just Scribe.
        let trimmed = Self.stripBackchannelFillers(from: rawTrimmed)
        guard !trimmed.isEmpty else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        // Capture AX context BEFORE the async paste so we're reading
        // the state at the moment of release. Cheap call.
        let focusedContext = FocusedElementContextProvider.capture()
        let workerBaseURL = Self.workerBaseURL

        currentResponseTask?.cancel()
        currentResponseTask = Task { [weak self] in
            // .processing during the Worker round-trip + paste so the
            // overlay doesn't snap to idle before the paste lands.
            self?.voiceState = .processing

            // v11q + v11w: Pre-substitute spoken-punctuation phrases BEFORE
            // sending to Haiku — but ONLY for hold sessions. Toggle/polish
            // sessions skip pre-substitution entirely; Haiku rewrite-mode
            // decides all punctuation/structure from grammar (including
            // dropping spurious "comma"/"period"/"new paragraph" words
            // that the user said but doesn't want literally rendered).
            //
            // Rationale: hold mode = exact control (user wants their cues
            // honored). Toggle mode = best-effort polish (Haiku knows best).
            // Steph's framing 2026-04-27: "in polish mode, I'm expecting
            // it to polish whatever I say — I don't need to make those
            // structural edits myself."
            let preSubstitutedText: String
            if polishAfterRepunctuate {
                preSubstitutedText = trimmed
                print("🔧 Pre-substitution: skipped (toggle/polish mode — Haiku handles all structure)")
            } else {
                preSubstitutedText = Self.applySpokenPunctuationSubstitutions(to: trimmed)
                let paragraphBreakCount = preSubstitutedText.components(separatedBy: "\n\n").count - 1
                print("🔧 Pre-substitution (hold mode): \(trimmed.count) chars → \(preSubstitutedText.count) chars, \(paragraphBreakCount) paragraph break(s)")
            }

            // v11h + v12e: For HOLD mode, run /repunctuate (Haiku) to
            // add context-based punctuation. For TOGGLE mode, SKIP this
            // step — polish handles all punctuation/structure/lists
            // directly from raw text. Repunctuate was pre-flattening
            // list structure ("first... second... third...") into
            // flowing prose, which made polish blind to the list cues.
            // v15m phase timing: capture the boundary between setup
            // (AssemblyAI final + pre-substitution) and the repunctuate
            // round-trip so the diagnostic log can show exactly where
            // VTT time is spent.
            let phaseSetupCompleteAt = Date()

            // v15n: track pipeline outcome for the transcript log so
            // silent failures (repunctuate timeout, polish error) get
            // surfaced. Hold-mode + short-bypass paths set this to a
            // descriptive "skipped:..." value; failures set "failed:...".
            // Toggle mode overrides with the polish outcome below.
            var pipelineStatus: String? = nil

            let punctuatedText: String
            let repunctuateSkipped: Bool
            if polishAfterRepunctuate {
                punctuatedText = preSubstitutedText
                repunctuateSkipped = true
                print("✏️ Repunctuate: skipped (toggle/polish mode — polish handles punctuation + lists end-to-end)")
            } else if Self.shouldSkipRepunctuateForShortUtterance(preSubstitutedText) {
                // VTT-SPEED Tier 2 (v15m, 2026-05-01): for very short
                // utterances ("yes", "okay", "got it"), AssemblyAI's
                // native punctuation is already correct and the
                // ~300-500ms Haiku round-trip just adds latency. Skip.
                punctuatedText = preSubstitutedText
                repunctuateSkipped = true
                pipelineStatus = "skipped:short-utterance"
                let wordCount = preSubstitutedText.split(whereSeparator: { $0.isWhitespace }).count
                print("✏️ Repunctuate: skipped (short utterance: \(wordCount) word(s), \(preSubstitutedText.count) chars — AssemblyAI punctuation sufficient)")
            } else {
                // v16pv (2026-06-06): local-first repunctuate. Try the
                // on-device Rapid-MLX model (qwen3.5-4b); on ANY local
                // failure fall through to the Worker/Haiku path, which
                // keeps its own raw-text fallback. Benchmarked at parity
                // on real dictations, ~0.4s faster, $0, private.
                var localText: String? = nil
                if LocalLLMManager.shared.isAvailable {
                    localText = try? await LocalLLMManager.shared.repunctuate(
                        rawText: preSubstitutedText,
                        appName: focusedContext?.appName
                    )
                    if localText == nil {
                        print("⚠️ Repunctuate (local) failed — falling back to Worker")
                    }
                }
                if let localText {
                    punctuatedText = localText
                    repunctuateSkipped = false
                    print("✏️ Repunctuate (local): \(preSubstitutedText.count) chars → \(punctuatedText.count) chars")
                } else {
                    do {
                        punctuatedText = try await Self.repunctuateTextViaWorker(
                            workerBaseURL: workerBaseURL,
                            rawText: preSubstitutedText,
                            appName: focusedContext?.appName
                        )
                        repunctuateSkipped = false
                        print("✏️ Repunctuate: \(preSubstitutedText.count) chars → \(punctuatedText.count) chars")
                    } catch {
                        print("⚠️ Repunctuate failed (\(error)) — falling back to pre-substituted text")
                        punctuatedText = preSubstitutedText
                        repunctuateSkipped = false
                        pipelineStatus = "failed:repunctuate:\((error as NSError).localizedDescription.prefix(80))"
                    }
                }
            }
            let phaseRepunctuateCompleteAt = Date()

            guard !Task.isCancelled else { return }

            // v11l + v11n: Toggle sessions imply long-form dictation that
            // gets messier — route through Worker /voice-command polish
            // AFTER /repunctuate. Hold sessions skip this and stay raw.
            let textToFormat: String
            if polishAfterRepunctuate {
                do {
                    // v12i: restore screenshot to polish — Steph's preference
                    // is tone-matching > strict list-formatting fidelity.
                    // Polish prompt simplified to be less aggressive, so the
                    // image's tone-bias should now help (not hurt).
                    let polished = try await Self.sendPolishCommandToWorker(
                        workerBaseURL: workerBaseURL,
                        fieldText: punctuatedText,
                        modifier: nil,
                        appName: focusedContext?.appName,
                        role: focusedContext?.role,
                        windowTitle: focusedContext?.windowTitle,
                        personalFacts: Self.loadCurrentObsidianMemoryContents(),
                        modelOverride: "claude-haiku-4-5-20251001",
                        polishStyle: "rewrite",
                        contextImageJPEG: contextScreenshot?.imageData
                    )
                    print("✨ VTT polish (Haiku, smart, vision=\(contextScreenshot != nil)): \(punctuatedText.count) → \(polished.count) chars")
                    textToFormat = polished
                    pipelineStatus = "ok"
                } catch {
                    print("⚠️ VTT polish failed (\(error)) — using punctuated raw text")
                    textToFormat = punctuatedText
                    pipelineStatus = "failed:polish:\((error as NSError).localizedDescription.prefix(80))"
                }
            } else {
                textToFormat = punctuatedText
            }
            let phasePolishCompleteAt = Date()

            guard !Task.isCancelled else { return }

            // Strip transcription artifacts AND apply spoken-punctuation
            // substitutions ON TOP of the formatted output. Spoken
            // overrides ("comma", "new paragraph") still win over both
            // Haiku's grammar and polish's stylistic choices.
            let cleaned = Self.stripVoiceToTextArtifacts(textToFormat)
            guard !cleaned.isEmpty else {
                self?.voiceState = .idle
                self?.scheduleTransientHideIfNeeded()
                return
            }

            let finalPayload = Self.applySmartSpacePrefix(
                to: cleaned,
                axRecentText: focusedContext?.recentText,
                lastPasteEndedWith: Self.lastVoiceToTextPasteEndedWith,
                lastPasteAt: Self.lastVoiceToTextPasteAt,
                now: Date()
            )

            // Remember what we just pasted so the next voice-to-text call
            // can make a good decision even in AX-blind apps.
            Self.lastVoiceToTextPasteEndedWith = cleaned.last
            Self.lastVoiceToTextPasteAt = Date()

            // v15m+ diagnostic: phase-breakdown timing.
            // Format: indicator=<style> mode=<hold|toggle> chars=N words=N
            //         setupMs=X repunctuateMs=Y polishMs=Z finalizeMs=W totalMs=T
            //         repunctuateSkipped=true|false
            //
            // - setupMs:       release → AssemblyAI final + pre-substitution
            // - repunctuateMs: Haiku /repunctuate round-trip (0 if skipped)
            // - polishMs:      Haiku /voice-command polish (0 if hold mode)
            // - finalizeMs:    artifact strip + smart-space prefix (should be ~0)
            // - totalMs:       release → ready-to-paste (excludes the
            //                  fixed 30ms+150ms clipboard latch sleeps)
            //
            // Phase boundaries are taken at three Date() captures upstream
            // (phaseSetupCompleteAt, phaseRepunctuateCompleteAt,
            // phasePolishCompleteAt). This breakdown lets us A/B specific
            // changes (e.g. v15m Tier 1+2) without guessing which phase
            // moved.
            if let releaseAt = Self.lastVTTReleaseTimestamp {
                let now = Date()
                let setupMs = Int(phaseSetupCompleteAt.timeIntervalSince(releaseAt) * 1000)
                let repunctuateMs = Int(phaseRepunctuateCompleteAt.timeIntervalSince(phaseSetupCompleteAt) * 1000)
                let polishMs = Int(phasePolishCompleteAt.timeIntervalSince(phaseRepunctuateCompleteAt) * 1000)
                let finalizeMs = Int(now.timeIntervalSince(phasePolishCompleteAt) * 1000)
                let totalMs = Int(now.timeIntervalSince(releaseAt) * 1000)
                let style = UserDefaults.standard.string(forKey: "clicky.cursorIndicatorStyle") ?? "triangle"
                let mode = polishAfterRepunctuate ? "toggle" : "hold"
                let words = finalPayload.split(whereSeparator: { $0.isWhitespace }).count
                // v15p4bt (2026-05-29): tag each line with the active
                // VTT provider so head-to-head A/B can be sliced via
                // `grep "provider=parakeet" /tmp/clicky_vtt_timing.log`
                // instead of guessing by timestamp window.
                Self.appendVTTTimingDiag(
                    "provider=\(selectedVTTProvider) indicator=\(style) mode=\(mode) chars=\(finalPayload.count) words=\(words) " +
                    "setupMs=\(setupMs) repunctuateMs=\(repunctuateMs) polishMs=\(polishMs) finalizeMs=\(finalizeMs) totalMs=\(totalMs) " +
                    "repunctuateSkipped=\(repunctuateSkipped)"
                )
                Self.lastVTTReleaseTimestamp = nil
            }

            // v15p4cl (2026-05-30): name correction (alias + phonetic)
            // now runs for EVERY provider, not just Parakeet — apply it
            // to the final text before paste. Idempotent, so Parakeet
            // (which already ran it in its own post-process) is unaffected.
            let correctedPayload = ParakeetStreamingTranscriptionSession.correctNames(finalPayload)
            // v15p4ck: capture final text per-provider for engine A/B.
            Self.appendVTTOutputDiag(provider: selectedVTTProvider, text: correctedPayload)
            await Self.typeTextViaClipboard(correctedPayload)

            // v15p3cu (2026-05-14): VTT success sound cue — fires only
            // after the clipboard paste actually completes, so Steph
            // hears the chime when the text has truly landed.
            await MainActor.run {
                if polishAfterRepunctuate {
                    ClickySoundEngine.shared.play(.polishDone)
                } else {
                    ClickySoundEngine.shared.play(.vttSuccess)
                }
            }

            ClickyAnalytics.trackAIResponseReceived(response: finalPayload)

            // v11y + v12: persist to transcript log. Toggle sessions
            // include the engagement screenshot for memory-scan context;
            // hold sessions stay screenshot-free.
            let vttInteractionId = ClickyTranscriptLogger.newInteractionId()
            let vttTimestamp = Date()
            var vttScreenshotPaths: [String] = []
            if let contextScreenshot {
                if let path = ClickyTranscriptLogger.shared.saveScreenshotJPEG(
                    contextScreenshot.imageData,
                    forInteractionId: vttInteractionId,
                    frameIndex: 0,
                    timestamp: vttTimestamp
                ) {
                    vttScreenshotPaths.append(path)
                }
            }
            ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
                id: vttInteractionId,
                timestamp: vttTimestamp,
                mode: polishAfterRepunctuate ? .vttToggle : .vttHold,
                rawTranscript: trimmed,
                finalOutput: cleaned,
                claudeResponse: nil,
                polishModifier: nil,
                appName: focusedContext?.appName,
                screenshotPaths: vttScreenshotPaths,
                polishStatus: pipelineStatus
            ))

            if !Task.isCancelled {
                self?.voiceState = .idle
                self?.scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Returns true if `text` is short enough that we can skip the
    /// /repunctuate Haiku round-trip without quality loss. AssemblyAI's
    /// native punctuation is already very good on simple utterances —
    /// the value of /repunctuate is in multi-clause sentences and
    /// disfluencies, neither of which fit in <3 words or <15 chars.
    ///
    /// Saves 300-500ms on the very common "quick reply" case
    /// ("yes", "okay", "got it", "sounds good", "thanks", etc.).
    /// VTT-SPEED Tier 2 (v15m, 2026-05-01).
    private static func shouldSkipRepunctuateForShortUtterance(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 15 {
            return true
        }
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount < 3 {
            return true
        }
        return false
    }

    /// POST raw transcript text to the Worker's /repunctuate route.
    /// Returns the Haiku-punctuated text. Throws on transport / non-2xx.
    /// Caller is expected to fall back to raw text on failure.
    ///
    /// v15p3cs (2026-05-14): `appName` is now forwarded so the Worker
    /// can choose between formal and casual prompt variants — colloquial
    /// reductions ("wanna", "gonna", "kinda") get expanded to their full
    /// forms by default, but preserved when the destination app is a
    /// casual-messaging context (Messages, WhatsApp, etc.).
    private static func repunctuateTextViaWorker(
        workerBaseURL: String,
        rawText: String,
        appName: String?
    ) async throws -> String {
        guard let routeURL = URL(string: "\(workerBaseURL)/repunctuate") else {
            throw NSError(
                domain: "ClickyRepunctuateError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Worker base URL: \(workerBaseURL)"]
            )
        }
        var request = URLRequest(url: routeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // 6s timeout: Haiku 4.5 typically finishes in 0.5-1.5s. If it's
        // slower than 6s something's wrong; better to fall back to raw
        // than make Steph wait 30s for a paste.
        request.timeoutInterval = 6
        var body: [String: Any] = ["text": rawText]
        if let appName, !appName.isEmpty {
            body["appName"] = appName
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "ClickyRepunctuateError",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Worker returned status \(httpResponse.statusCode): \(bodyText)"]
            )
        }

        guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let output = parsed["output"] as? String else {
            throw NSError(
                domain: "ClickyRepunctuateError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Worker response missing 'output' string"]
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Worker TLS warmup (v15m T1+T2, 2026-05-01)
    //
    // Pre-establish a TLS session to clicky-proxy.sapierso.workers.dev so
    // the first VTT after launch doesn't pay for a cold TLS handshake
    // (~150-300ms saved depending on network). Mirrors the pattern in
    // ClaudeAPI.warmUpTLSConnectionIfNeeded.
    //
    // The TLS session ticket is host-scoped so warming the root host
    // covers /repunctuate, /transcribe-token, and any other Worker route
    // we add later. Failures are silently ignored — this is purely
    // an optimization.

    private static let workerTLSWarmupLock = NSLock()
    private static var hasStartedWorkerTLSWarmup = false

    /// Fires a no-op HEAD request against the Worker host to warm the
    /// TLS session ticket cache. Idempotent — only runs once per app
    /// launch. Safe to call from any thread.
    static func warmUpWorkerTLSConnectionIfNeeded() {
        workerTLSWarmupLock.lock()
        let shouldStart = !hasStartedWorkerTLSWarmup
        if shouldStart {
            hasStartedWorkerTLSWarmup = true
        }
        workerTLSWarmupLock.unlock()

        guard shouldStart else { return }

        guard var components = URLComponents(string: workerBaseURL) else {
            return
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil

        guard let warmupURL = components.url else {
            return
        }

        var request = URLRequest(url: warmupURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal.
        }.resume()
    }

    // MARK: - Haiku model warmup (v15o, 2026-05-01)
    //
    // The TLS warmup above gets the network connection hot, but the
    // Haiku 4.5 MODEL itself can also pay a "cold start" tax of
    // 200-400ms on the first call after a long idle period. We can
    // pre-warm the model by firing a tiny /repunctuate call that's
    // small enough to be ~free (a few tokens of input/output) but
    // exercises the full path: TLS → Worker → Anthropic API → Haiku.
    //
    // After this completes, the user's first real VTT (whether hold or
    // toggle) hits a hot Haiku and skips that cold-start delay.
    //
    // Idempotent — only fires once per app launch. Safe to call from
    // any thread. Completely silent on failure (it's just an
    // optimization).

    private static let haikuWarmupLock = NSLock()
    private static var hasStartedHaikuWarmup = false

    /// Fires a tiny `/repunctuate` request to warm Haiku 4.5 on the
    /// Anthropic side so the user's first real VTT doesn't pay for
    /// model cold-start. ~10 input + ~5 output tokens — fractional
    /// cents per launch.
    static func warmUpHaikuModelIfNeeded() {
        haikuWarmupLock.lock()
        let shouldStart = !hasStartedHaikuWarmup
        if shouldStart {
            hasStartedHaikuWarmup = true
        }
        haikuWarmupLock.unlock()

        guard shouldStart else { return }

        guard let routeURL = URL(string: "\(workerBaseURL)/repunctuate") else {
            return
        }

        Task.detached(priority: .background) {
            var request = URLRequest(url: routeURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            // 10s timeout — generous because this is the cold-start case.
            request.timeoutInterval = 10
            let body: [String: Any] = ["text": "warmup"]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            // Result is intentionally discarded — purpose is to exercise
            // the path, not consume the output. Errors are silently swallowed.
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Rolling memory for voice-to-text smart-spacing. Static because
    /// CompanionManager is single-instance app-wide and these survive
    /// across paste calls. Session-scoped (never persisted) — a fresh
    /// app launch starts with a clean slate.
    private static var lastVoiceToTextPasteEndedWith: Character?
    private static var lastVoiceToTextPasteAt: Date?

    // MARK: - "Show last response" typing-mode command (v11k)

    /// Phrases that trigger pasting the last assistant response into
    /// the focused field. Match is case-insensitive after normalization.
    /// Generous synonyms — natural ways Steph might phrase the request.
    ///
    /// v12v hotfix #3 (2026-04-29): added "dictate last" variants. The
    /// old v11l "dictate" prefix was removed but "dictate last" as a
    /// natural way to say "show me the last response" stuck around.
    /// Matcher also got lenient (em-dash strip, whitespace normalization).
    private static let showLastResponsePhrases: Set<String> = [
        // Show forms
        "show last response",
        "show me last response",
        "show me the last response",
        "show the last response",
        "show last reply",
        "show me last reply",
        "show me the last reply",
        "show what you just said",
        "show me what you just said",
        // Paste forms
        "paste last response",
        "paste the last response",
        "paste last reply",
        "paste the last reply",
        // Dictate forms (re-added 2026-04-29 — natural typing-mode phrasing)
        "dictate last",
        "dictate that",
        "dictate the last",
        "dictate last response",
        "dictate the last response",
        "dictate last reply",
        "dictate the last reply",
        "dictate what you just said",
        "dictate last command",
        "dictate the last command",
        "dictate last voice prompt",
        "dictate the last voice prompt",
        // Other
        "what did you just say",
        "repeat last response",
        "repeat the last response",
    ]

    /// Returns true if `transcript` (typing-mode) is a "show last response"
    /// command. Lenient matching: strips em-dashes/dashes, collapses
    /// whitespace, lowercases, strips leading/trailing punctuation, then
    /// does an exact match. Internal commas removed too. Exact-match
    /// requirement (not substring) ensures longer transcripts like "show
    /// last response and explain it" still go to Claude as new questions.
    static func isShowLastResponseCommand(_ transcript: String) -> Bool {
        let original = transcript
        var normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Strip em-dashes / en-dashes (AssemblyAI artifact on pauses).
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]*[—–][ \t]*"#,
            with: " ",
            options: .regularExpression
        )
        // Collapse whitespace runs.
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        // Strip leading / trailing punctuation.
        let trailingPunct: Set<Character> = [".", "!", "?", ",", ":", ";"]
        while let last = normalized.last, trailingPunct.contains(last) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        while let first = normalized.first, trailingPunct.contains(first) {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        // Strip internal commas, then re-collapse spacing.
        normalized = normalized.replacingOccurrences(of: ",", with: "")
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.trimmingCharacters(in: .whitespaces)

        let matched = showLastResponsePhrases.contains(normalized)
        print("📋 Show-last-response check: '\(original)' → '\(normalized)' → matched=\(matched)")
        return matched
    }

    /// v12v: Phrases that trigger TTS REPLAY of the last assistant response
    /// when spoken in base voice mode. Distinct from showLastResponsePhrases
    /// because voice users phrase the request differently — they want
    /// Clicky to *say* it again, not paste it.
    ///
    /// v12v hotfix #2 (2026-04-29): broader set + lenient matcher so
    /// natural variations all hit. AssemblyAI sometimes injects em-dashes,
    /// commas, or capitalization that broke the v1 exact-match. Now we
    /// normalize aggressively before checking.
    private static let voiceReplayPhrases: Set<String> = [
        // Core "say it again"
        "say that again",
        "say it again",
        "say what you said",
        "say that one more time",
        "say it one more time",
        // Polite forms
        "can you say that again",
        "could you say that again",
        "can you say it again",
        "could you say it again",
        "please say that again",
        "say that again please",
        "say it again please",
        // "Repeat" forms
        "repeat",
        "repeat that",
        "repeat it",
        "repeat please",
        "please repeat",
        "please repeat that",
        "repeat that please",
        "repeat it please",
        "can you repeat",
        "can you repeat that",
        "can you repeat it",
        "could you repeat that",
        "could you repeat it",
        "repeat last response",
        "repeat the last response",
        // "What did you say" forms
        "what did you say",
        "what did you just say",
        "what was that",
        // "Missed it" forms
        "i missed that",
        "i missed it",
        "i didn't catch that",
        "i didn't catch it",
        "i didn't hear that",
        "i didn't hear it",
        // "One more time" / "again" forms
        "one more time",
        "again",
        "again please",
        "play that again",
        "play it again",
        "play that back",
        // "Tell me again" forms
        "tell me again",
        "tell me that again",
    ]

    /// Returns true if `transcript` (voice-mode) is a replay command.
    /// Lenient matching: strips em-dashes/dashes, collapses whitespace,
    /// lowercases, strips trailing punctuation, then does an exact
    /// match against the phrase set. The exact-match requirement (not
    /// substring) ensures transcripts like "can you say that again but
    /// slower" still go to Claude as new questions.
    static func isVoiceReplayCommand(_ transcript: String) -> Bool {
        let original = transcript
        var normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Strip em-dashes and en-dashes (AssemblyAI emits these on
        // pauses; "say— that again" should match "say that again").
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]*[—–][ \t]*"#,
            with: " ",
            options: .regularExpression
        )

        // Collapse all whitespace runs to single spaces.
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        // Strip leading/trailing punctuation. Internal punctuation
        // (e.g. "say that again, please") gets stripped via the comma
        // step below.
        let trailingPunct: Set<Character> = [".", "!", "?", ",", ":", ";"]
        while let last = normalized.last, trailingPunct.contains(last) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        while let first = normalized.first, trailingPunct.contains(first) {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }

        // Strip internal commas so "say that again, please" matches
        // "say that again please".
        normalized = normalized.replacingOccurrences(of: ",", with: "")
        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.trimmingCharacters(in: .whitespaces)

        let matched = voiceReplayPhrases.contains(normalized)
        print("🔁 Replay-command check: '\(original)' → '\(normalized)' → matched=\(matched)")
        return matched
    }

    /// Speaks the most recent assistant response via TTS. If the conversation
    /// history is empty, speaks a brief notice instead. Used by the v12v
    /// voice-mode replay command. Distinct from pasteLastAssistantResponse
    /// (typing-mode) because voice users want it spoken back, not typed
    /// into a focused field.
    ///
    /// v12v hotfix (2026-04-28): bulletproof cleanup. Any exit path —
    /// success, error, cancellation by interrupt — guarantees voiceState
    /// returns to .idle so subsequent hotkeys / state transitions aren't
    /// blocked by a stuck "still responding" flag. Uses defer because
    /// cancellation can occur at any await point.
    private func replayLastAssistantResponseViaTTS() {
        print("🔁 Replay: ENTRY — history count=\(conversationHistory.count) ttsProvider=\(type(of: ttsClient))")

        // Cancel any in-flight Claude/TTS so the replay isn't fighting
        // a previous unfinished response.
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        guard let lastEntry = conversationHistory.last else {
            print("ℹ️ Voice replay: no history yet")
            currentResponseTask = Task { [weak self] in
                defer {
                    Task { @MainActor in
                        guard let self = self else { return }
                        if self.voiceState != .idle {
                            self.voiceState = .idle
                            self.scheduleTransientHideIfNeeded()
                        }
                    }
                }
                guard let self else { return }
                self.voiceState = .responding
                do {
                    try await self.ttsClient.speakText("I haven't said anything yet.")
                } catch {
                    print("⚠️ Voice replay (no-history notice): TTS error \(error)")
                }
            }
            return
        }

        let responseText = lastEntry.assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !responseText.isEmpty else {
            print("ℹ️ Voice replay: history entry was empty")
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        print("🔁 Voice replay: speaking \(responseText.count) chars from last response")
        currentResponseTask = Task { [weak self] in
            // BULLETPROOF cleanup. Defer fires even on cancellation, on
            // throw, on early return — every exit path reaches here. The
            // inner main-actor Task is fire-and-forget so cancellation
            // of the outer Task doesn't cascade and skip the cleanup.
            defer {
                Task { @MainActor in
                    guard let self = self else { return }
                    self.ttsClient.stopPlayback()
                    if self.voiceState == .processing || self.voiceState == .responding {
                        self.voiceState = .idle
                        self.scheduleTransientHideIfNeeded()
                    }
                    print("🔁 Voice replay: cleanup ran (final state: \(self.voiceState))")
                }
            }

            guard let self else { return }
            // v13n: keep voiceState at .processing (spinner) throughout
            // synthesis + playback. Was flipping to .responding BEFORE the
            // await, which meant during the TTS synthesis delay the orb
            // showed .responding (no spinner) — Steph rightly noted this
            // looked like nothing was happening. speakText is one blocking
            // call doing both synthesis and playback; the spinner is the
            // honest signal that Clicky is working.
            self.voiceState = .processing
            // Force stopPlayback to drain any residual TTS state (same
            // root cause as the v13m burst fix).
            self.ttsClient.stopPlayback()
            do {
                try await self.ttsClient.speakText(responseText)
                print("🔁 Voice replay: TTS playback finished cleanly")
            } catch is CancellationError {
                print("🔁 Voice replay: cancelled (interrupted by next interaction)")
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                print("🔁 Voice replay: TTS cancelled (URLError.cancelled)")
                return
            } catch {
                print("⚠️ Voice replay: TTS error \(error)")
                self.speakCreditsErrorFallback(error: error)
            }
        }
    }

    /// Pastes the most recent assistant response into the focused field.
    /// v15p3hh (2026-05-19): repointed from base PTT's `conversationHistory`
    /// (now stale — base PTT was retired) to Marin's live shared history
    /// at `~/Library/Application Support/com.stephenpierson.clickyplus/
    /// marin-conversation-history.json`. Both Gemini Marin and OpenAI Marin
    /// write to that file, so "dictate last" / "show last response" /
    /// "paste last response" / etc. now reflect what Marin actually just
    /// said in voice — which is what Steph wants. Uses .iso8601 date
    /// decoding to match the encoder (default seconds-since-1970 fails
    /// silently on the file's ISO timestamps).
    private func pasteLastAssistantResponse() {
        let responseText = Self.loadLatestMarinAssistantTurn()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        RealtimeConversationManager.appendDiag(
            "[paste-last] loaded Marin assistant chars=\(responseText.count) preview=\"\(responseText.prefix(100))\""
        )

        guard !responseText.isEmpty else {
            RealtimeConversationManager.appendDiag("[paste-last] empty result, speaking notice")
            let synthesizer = NSSpeechSynthesizer()
            synthesizer.startSpeaking("No prior response to show, Steph.")
            voiceState = .responding
            // Reset to idle after a moment so the overlay can hide.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.voiceState = .idle
                self?.scheduleTransientHideIfNeeded()
            }
            return
        }

        RealtimeConversationManager.appendDiag("[paste-last] pasting \(responseText.count) chars")
        currentResponseTask?.cancel()
        currentResponseTask = Task { [weak self] in
            self?.voiceState = .processing
            await Self.typeTextViaClipboard(responseText)
            ClickyAnalytics.trackAIResponseReceived(response: responseText)
            if !Task.isCancelled {
                self?.voiceState = .idle
                self?.scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Window within which our own "we just pasted" memory is
    /// considered fresh. Outside this window we assume the user has
    /// moved on / edited / switched apps.
    private static let voiceToTextMemoryWindowSeconds: TimeInterval = 60

    /// Decides whether to prepend a single space to `transcript`.
    /// Pure function; easy to unit-test. Two signals:
    /// Cleans up the punctuated/polished transcript before paste.
    ///
    /// v12i (2026-04-27): em-dash stripping RE-ADDED at user's preference.
    /// Steph: "sometimes em dashes appear randomly, maybe we should just
    /// take them out." AssemblyAI still inserts em-dashes on speech pauses
    /// even with format_turns=false, AND Haiku polish occasionally uses
    /// them as stylistic separators despite the prompt. Cleanest fix is
    /// to strip them at the post-processing layer regardless of source.
    /// Replace " — " with ", " (preserves meaning — em-dash usually
    /// represents a pause/aside that comma handles fine).
    /// v12n: Collapse runs of horizontal whitespace (spaces/tabs) to a
    /// single space, preserving newlines. Used after em-dash strip so
    /// "word — word" → "word  word" → "word word" without flattening
    /// paragraph breaks.
    static func collapseHorizontalDoubleSpaces(_ input: String) -> String {
        var output = input
        // Repeated `replacingOccurrences` is O(n) per pass; bound it so a
        // pathological input can't loop forever.
        var safety = 8
        while output.contains("  ") && safety > 0 {
            output = output.replacingOccurrences(of: "  ", with: " ")
            safety -= 1
        }
        // Collapse "tab + space" / "space + tab" / "tab + tab" runs too.
        output = output.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return output
    }

    static func stripVoiceToTextArtifacts(_ transcript: String) -> String {
        var cleaned = transcript

        // Em-dash / en-dash strip. v12l (2026-04-28): replace any em-dash
        // (and en-dash) with a single space, regardless of surrounding
        // whitespace.
        // v15p3bh (2026-05-12): replacement changed from " " to ", " —
        // single space was destroying sentence boundaries when AssemblyAI
        // emitted em-dashes for speech pauses between clauses. A comma
        // preserves the pause semantics and never produces run-ons.
        // Subsequent double-space collapse still cleans "pulls— Total"
        // → "pulls, Total" (vs old "pulls Total" via space).
        //
        // Uses [ \t]* (horizontal whitespace) NOT \s* so we don't
        // accidentally eat newlines from spoken-punctuation paragraph
        // breaks adjacent to a dash.
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]*[—–][ \t]*"#,
            with: ", ",
            options: .regularExpression
        )

        // Spoken punctuation substitution. When Steph dictates "comma",
        // "period", "question mark", etc., we substitute the actual
        // symbol so the pasted output reads correctly. Case-insensitive
        // (AssemblyAI may capitalize at sentence starts) and applied
        // BEFORE double-space collapsing so we can clean up the
        // post-substitution spacing.
        //
        // Tradeoff: if Steph dictates one of these words AS LITERAL
        // CONTENT ("I drove for a period of time"), it'll get replaced.
        // Wispr Flow / Dragon both ship this default behavior and accept
        // the rare false positive — these words almost never appear in
        // natural dictation.
        cleaned = substituteSpokenPunctuation(in: cleaned)

        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        // Trim only horizontal whitespace — preserve any leading/trailing
        // `\n` or `\n\n` produced by spoken-punctuation substitution.
        // If Steph utters JUST "new paragraph" with no other words, we
        // want a literal `\n\n` to be pasted; .whitespacesAndNewlines
        // would strip it back to empty string.
        let horizontalWhitespace = CharacterSet(charactersIn: " \t")
        return cleaned.trimmingCharacters(in: horizontalWhitespace)
    }

    /// Replaces spoken-punctuation phrases with their symbol equivalents.
    /// Order matters — longer multi-word phrases are matched FIRST so
    /// "exclamation point" doesn't get partially-matched as "exclamation"
    /// + "point" via shorter rules. Each substitution uses a regex with
    /// `\b` word boundaries so partial-word matches (e.g. "comma" inside
    /// "commander") don't fire.
    private static func substituteSpokenPunctuation(in transcript: String) -> String {
        var workingTranscript = applySpokenPunctuationSubstitutions(to: transcript)

        // Cleanup: AssemblyAI auto-adds a terminal period based on
        // speech inflection, so "test exclamation point" gets transcribed
        // as "test exclamation point." which after substitution becomes
        // "test!." — the user's explicit `!` followed by AssemblyAI's
        // auto `.`. Collapse adjacent terminal punctuation, preferring
        // the explicit `!` or `?` over the auto `.` (and dedupe doubles
        // like `!!` or `??`).
        workingTranscript = collapseAdjacentTerminalPunctuation(in: workingTranscript)
        return workingTranscript
    }

    /// Standalone substitution-only pass — applies the spoken-phrase →
    /// symbol mappings without running the cleanup pipeline. Used to do
    /// substitution BEFORE Haiku /repunctuate so Haiku never sees phrases
    /// like "new paragraph" as text it could interpret. Haiku is incon-
    /// sistent about preserving them despite explicit prompt instruction —
    /// so we don't trust it and pre-substitute.
    static func applySpokenPunctuationSubstitutions(to transcript: String) -> String {
        // (spoken phrase → replacement) — ordered LONGEST FIRST so
        // multi-word phrases match before their substrings.
        let spokenToSymbolSubstitutions: [(spokenPhrase: String, replacementSymbol: String)] = [
            // Multi-word punctuation (must come first)
            ("exclamation point", "!"),
            ("exclamation mark", "!"),
            ("question mark", "?"),
            ("open paren", "("),
            ("open parenthesis", "("),
            ("close paren", ")"),
            ("close parenthesis", ")"),
            ("open quote", "\""),
            ("close quote", "\""),
            // All newline-ish phrases substitute to `\n\n` (paragraph
            // break). Steph's intent: "new line" is easier to say than
            // "new paragraph" but means the same thing — start a new
            // sentence on its own block, with auto-period before and
            // capital after. A true single-line break almost never
            // matters in voice dictation, so we treat all four as
            // synonyms of "new paragraph."
            ("new paragraph", "\n\n"),
            ("paragraph break", "\n\n"),
            ("new line", "\n\n"),
            ("line break", "\n\n"),
            // Single-word forms (AssemblyAI sometimes joins "new line"
            // → "newline")
            ("newline", "\n\n"),
            ("linebreak", "\n\n"),
            ("ellipsis", "..."),
            ("semicolon", ";"),
            ("colon", ":"),
            ("comma", ","),
            ("period", "."),
        ]

        var workingTranscript = transcript

        for (spokenPhrase, replacementSymbol) in spokenToSymbolSubstitutions {
            // Build a case-insensitive regex with word boundaries on
            // both sides. The LEADING `[\s.,]*` consumes any whitespace
            // AND any AssemblyAI auto-punctuation that precedes the
            // spoken-cue phrase. AssemblyAI with format_turns=false still
            // sometimes inserts periods/commas at speech-pause points,
            // and we want to "absorb" those into the user's deliberate
            // punctuation cue (e.g. "hey there. comma. how" → "hey there, how"
            // by replacing "[whitespace+period]+comma+[whitespace+period]"
            // with the comma symbol). Without this, the auto-punct would
            // collide with the substituted symbol and produce ugly ".,."
            // patterns that downstream Haiku might "fix" by dropping the
            // wrong one.
            //
            // For MULTI-WORD spoken phrases like "new paragraph",
            // AssemblyAI sometimes inserts punctuation between the
            // words ("New. Paragraph." instead of "new paragraph"). The
            // inter-word `[\s.,]+` handles that.
            let escapedSpokenPhrase = NSRegularExpression.escapedPattern(for: spokenPhrase)
            let lenientInterWordPattern = escapedSpokenPhrase
                .replacingOccurrences(of: " ", with: #"[\s.,]+"#)
            let pattern = #"(?i)[\s.,]*\b\#(lenientInterWordPattern)\b"#

            guard let punctuationRegex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            // Use direct range-replacement instead of `withTemplate:` so
            // the replacement string is inserted as a literal — no
            // template-syntax interpretation. This matters because
            // NSRegularExpression's template parser treats `$` and `\`
            // specially, which can mangle replacements containing
            // newline characters (e.g. "\n\n" for paragraph breaks).
            // Iterate matches in REVERSE so earlier ranges aren't
            // shifted by later replacements.
            let nsTranscript = workingTranscript as NSString
            let fullRange = NSRange(location: 0, length: nsTranscript.length)
            let matches = punctuationRegex.matches(in: workingTranscript, options: [], range: fullRange)
            for match in matches.reversed() {
                if let swiftRange = Range(match.range, in: workingTranscript) {
                    workingTranscript.replaceSubrange(swiftRange, with: replacementSymbol)
                }
            }
        }

        return workingTranscript
    }

    /// Collapse adjacent punctuation marks so the user's explicit `!`
    /// or `?` always wins over AssemblyAI's auto-inserted `.` or `,`.
    /// The auto-punctuation comes from speech inflection / pauses
    /// detection ("test exclamation point" can be transcribed as
    /// "test, exclamation point" if AssemblyAI hears a tiny pause
    /// before "exclamation point"). Doubles of terminals are also
    /// collapsed (`!!` → `!`, `??` → `?`).
    ///
    /// Examples:
    ///   "test!."   → "test!"     (auto period after explicit !)
    ///   "test?."   → "test?"
    ///   "test.!"   → "test!"     (auto period before explicit !)
    ///   "test,!"   → "test!"     (auto comma before explicit !)
    ///   "test, ?"  → "test?"     (auto comma + space before explicit ?)
    ///   "test!?"   → "test?"     (last explicit mark wins)
    ///   "test!!"   → "test!"
    private static func collapseAdjacentTerminalPunctuation(in text: String) -> String {
        var workingText = text

        // Run the cleanup multiple times in case substitutions create
        // new adjacencies (e.g. ",.!" → ",!" → "!"). Two passes is
        // enough for any realistic input.
        //
        // CRITICAL: use [ \t] for "horizontal whitespace only" instead
        // of \s. The \s class includes newline characters, which means
        // a regex like (,\s*){2,} would match `,\n\n,` and collapse the
        // newlines into a space — eating any paragraph break that
        // the spoken-punctuation substitution just inserted.
        for _ in 0..<2 {
            // ! or ? followed by . or , (with optional horizontal whitespace) → drop the . or ,
            workingText = workingText.replacingOccurrences(
                of: #"([!?])[ \t]*[.,]+"#,
                with: "$1",
                options: .regularExpression
            )
            // . or , (with optional horizontal whitespace) followed by ! or ? → drop the . or ,
            workingText = workingText.replacingOccurrences(
                of: #"[.,]+[ \t]*([!?])"#,
                with: "$1",
                options: .regularExpression
            )
            // !! → !, ?? → ?
            workingText = workingText.replacingOccurrences(
                of: #"!{2,}"#,
                with: "!",
                options: .regularExpression
            )
            workingText = workingText.replacingOccurrences(
                of: #"\?{2,}"#,
                with: "?",
                options: .regularExpression
            )

            // Collapse runs of consecutive commas (with optional
            // horizontal whitespace between) into a single comma.
            // Common bug case: user says "hey there comma how are you"
            // — AssemblyAI transcribes as "hey there, comma, how are
            // you" (auto comma before AND after the spoken "comma"
            // word due to pause detection), and after our `comma` →
            // `,` substitution the result has ",,," — three commas in
            // a row. Same logic for repeated semicolons / colons via
            // spoken substitution. Uses [ \t] not \s so we don't
            // accidentally eat newlines from paragraph-break substitutions.
            workingText = workingText.replacingOccurrences(
                of: #"(?:,[ \t]*){2,}"#,
                with: ", ",
                options: .regularExpression
            )
            workingText = workingText.replacingOccurrences(
                of: #";{2,}"#,
                with: ";",
                options: .regularExpression
            )
            workingText = workingText.replacingOccurrences(
                of: #":{2,}"#,
                with: ":",
                options: .regularExpression
            )

            // For repeated periods, only collapse exactly TWO into one
            // (leaves ellipsis `...` alone). Pattern uses negative
            // lookbehind/lookahead so we don't munch ellipsis dots.
            workingText = workingText.replacingOccurrences(
                of: #"(?<!\.)\.{2}(?!\.)"#,
                with: ".",
                options: .regularExpression
            )

            // Strip commas immediately adjacent to newlines. AssemblyAI's
            // pause-detection auto-inserts commas before/after spoken
            // phrases like "new paragraph", "newline" — when our
            // substitution turns those into actual newlines, the
            // auto-commas end up bracketing the newline ugly:
            // "Sentence,\n\nSecond" — the user wanted just "Sentence\n\nSecond".
            // We only strip COMMAS, not periods, because periods at
            // end-of-sentence before a newline are often intentional
            // (e.g. "Hello period newline Goodbye" → "Hello.\nGoodbye").
            //
            // CRITICAL: use lookahead/lookbehind so we don't consume
            // any newlines themselves. Naive `,[ \t]*\n` → `\n` would
            // strip ONE newline along with the comma, collapsing
            // "\n\n" to "\n" and breaking paragraph breaks.
            workingText = workingText.replacingOccurrences(
                of: #",[ \t]*(?=\n)"#,
                with: "",
                options: .regularExpression
            )
            workingText = workingText.replacingOccurrences(
                of: #"(?<=\n)[ \t]*,[ \t]*"#,
                with: "",
                options: .regularExpression
            )

            // Comma immediately before a period → just the period.
            // Auto-comma at the pause before spoken "period" produces
            // "Hello, period" → after substitution "Hello,." — strip
            // the orphan comma. Same logic applies for any letter+,+. ;
            // a comma directly before a period is always an artifact.
            workingText = workingText.replacingOccurrences(
                of: #",[ \t]*(?=\.)"#,
                with: "",
                options: .regularExpression
            )

            // Orphan period or comma at the start of a paragraph.
            // AssemblyAI's auto-period at the pause before spoken
            // "new paragraph" gets stranded after our substitution
            // turns "new paragraph" into "\n\n" — leaves ".\n\nhow"
            // → strip the leading "." so the paragraph starts clean.
            workingText = workingText.replacingOccurrences(
                of: #"(?<=\n)[ \t]*[.,]+[ \t]*"#,
                with: "",
                options: .regularExpression
            )
        }

        // After comma cleanup, format paragraph breaks: ensure each
        // `\n\n` is preceded by terminal punctuation (insert `.` if
        // not) AND that the first letter on the next paragraph is
        // capitalized. Mirrors normal sentence-boundary conventions
        // since "new paragraph" is a strong sentence-end signal.
        // (Single `\n` from "new line"/"newline" is left alone — line
        // breaks within sentences shouldn't auto-capitalize.)
        workingText = formatParagraphBreaksWithSentenceCasing(in: workingText)

        return workingText
    }

    /// For each paragraph break (`\n\n` or longer run of newlines),
    /// ensure the preceding text ends in `.`/`!`/`?` and that the
    /// first letter of the next paragraph is uppercase. Skips paragraph
    /// breaks at the very start/end of the text where there's nothing
    /// to terminate or capitalize.
    private static func formatParagraphBreaksWithSentenceCasing(in text: String) -> String {
        // Pattern captures: any non-newline char + run of newlines + any non-newline char.
        // We rebuild that triplet with sentence-casing rules applied.
        let paragraphBreakPattern = #"([^\n])(\n{2,})([^\n])"#
        guard let paragraphBreakRegex = try? NSRegularExpression(pattern: paragraphBreakPattern) else {
            return text
        }

        var workingText = text
        let nsTextForRanges = workingText as NSString
        let fullRange = NSRange(location: 0, length: nsTextForRanges.length)
        let matches = paragraphBreakRegex.matches(in: workingText, options: [], range: fullRange)

        // Iterate in reverse so earlier ranges aren't shifted by later
        // replacements.
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let beforeCharRange = match.range(at: 1)
            let newlinesRange = match.range(at: 2)
            let afterCharRange = match.range(at: 3)

            let nsTextSnapshot = workingText as NSString
            let beforeChar = nsTextSnapshot.substring(with: beforeCharRange)
            let newlinesString = nsTextSnapshot.substring(with: newlinesRange)
            let afterChar = nsTextSnapshot.substring(with: afterCharRange)

            // Add terminal `.` before the paragraph break if the
            // preceding char is a letter, digit, or closing-quote — i.e.
            // any "content character." Skip if it's already `.`/`!`/`?`
            // or if it's punctuation that doesn't terminate a sentence
            // (don't double-period or attach period to a comma).
            let charactersThatNeedTerminator: CharacterSet = CharacterSet
                .letters
                .union(.decimalDigits)
                .union(CharacterSet(charactersIn: "\")"))
            let beforeScalar = beforeChar.unicodeScalars.first
            let needsTerminator: Bool
            if let beforeScalar = beforeScalar {
                needsTerminator = charactersThatNeedTerminator.contains(beforeScalar)
            } else {
                needsTerminator = false
            }
            let rebuiltBefore = needsTerminator ? "\(beforeChar)." : beforeChar

            // Capitalize the first letter of the next paragraph if it's
            // currently lowercase. Leave non-letters (digits, quotes,
            // etc.) alone — they don't have casing.
            let rebuiltAfter: String
            if let afterScalar = afterChar.unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(afterScalar) {
                rebuiltAfter = afterChar.uppercased()
            } else {
                rebuiltAfter = afterChar
            }

            let rebuiltSegment = "\(rebuiltBefore)\(newlinesString)\(rebuiltAfter)"
            if let swiftRange = Range(match.range, in: workingText) {
                workingText.replaceSubrange(swiftRange, with: rebuiltSegment)
            }
        }

        // Edge case: leading paragraph break ("new paragraph hello"
        // becomes "\n\nhello"). The pattern above requires a non-newline
        // char on BOTH sides, so it skips this. Capitalize the first
        // letter that follows a run of leading newlines.
        if let leadingParagraphRegex = try? NSRegularExpression(pattern: #"^(\n{2,})([a-z])"#) {
            let nsLeading = workingText as NSString
            let leadingRange = NSRange(location: 0, length: nsLeading.length)
            if let firstMatch = leadingParagraphRegex.firstMatch(in: workingText, options: [], range: leadingRange),
               firstMatch.numberOfRanges == 3 {
                let newlinesPart = nsLeading.substring(with: firstMatch.range(at: 1))
                let lowerLetter = nsLeading.substring(with: firstMatch.range(at: 2))
                let rebuiltLeading = "\(newlinesPart)\(lowerLetter.uppercased())"
                if let swiftRange = Range(firstMatch.range, in: workingText) {
                    workingText.replaceSubrange(swiftRange, with: rebuiltLeading)
                }
            }
        }

        return workingText
    }

    ///   - axRecentText: tail of the focused field per AX (may be nil)
    ///   - lastPasteEndedWith + lastPasteAt: our own memory fallback
    ///
    /// Precedence:
    ///   1. If transcript already starts with whitespace → keep as-is
    ///   2. If AX says field ends in whitespace/newline → no prefix
    ///      (explicit negative signal wins, even over memory)
    ///   3. If AX says field ends in word/digit/closing-punct → prefix
    ///   4. If AX is silent AND memory says we just pasted (within
    ///      window) ending in word/digit/closing-punct → prefix
    ///   5. Otherwise → no prefix
    static func applySmartSpacePrefix(
        to transcript: String,
        axRecentText: String?,
        lastPasteEndedWith: Character?,
        lastPasteAt: Date?,
        now: Date
    ) -> String {
        // v15p3at (2026-05-11): re-enable AX-only smart-space path. Steph
        // prefers the AX-based behavior (with a known false-positive on
        // new lines, where AX often returns the previous paragraph's text
        // without a trailing newline) over no smart-space at all — because
        // pasting "Hi there." then VTTing "How are you?" should produce
        // "Hi there. How are you?" not "Hi there.How are you?".
        //
        // Local-memory fallback (using lastPasteEndedWith / lastPasteAt)
        // remains DISABLED — that was the worse offender (memory persisted
        // across manual edits + new lines). AX-only is more conservative
        // and less false-positive-prone.
        //
        // Future fix for the new-line case: query AX for cursor position
        // explicitly, look at the character at position-1 to check for \n,
        // rather than trusting tail-of-recentText.
        _ = lastPasteEndedWith
        _ = lastPasteAt
        _ = now

        if let first = transcript.first, first.isWhitespace {
            return transcript
        }

        let needsSpaceAfter: Set<Character> = [
            ".", "?", "!", ",", ";", ":", ")", "]", "}", "\"", "'", "”", "’"
        ]

        func needsSpace(_ c: Character) -> Bool {
            return c.isLetter || c.isNumber || needsSpaceAfter.contains(c)
        }

        if let tail = axRecentText, let lastChar = tail.last {
            if lastChar.isWhitespace || lastChar.isNewline {
                return transcript
            }
            if needsSpace(lastChar) {
                return " " + transcript
            }
            return transcript
        }

        // AX silent — be conservative, do nothing.
        return transcript
    }

    private func sendTypingQueryToClaude(
        transcript: String,
        screenshot: CompanionScreenCapture?,
        focusedContext: FocusedElementContext?
    ) {
        let trimmedRawTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawTranscript.isEmpty else {
            // Nothing said — bail silently. Don't paste anything.
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        // v15p3hh (2026-05-19): the "dictate last" / "show last response"
        // phrase intercept is owned by `isShowLastResponseCommand` at the
        // call site upstream (sendTypingQueryToClaude's caller). That path
        // calls `pasteLastAssistantResponse`, which v15p3hh repoints to
        // Marin's live shared history. So we don't need a second dispatch
        // here. Earlier v15p3hc–hg attempts to add one were redundant and
        // never fired because the v11k intercept matched first. Keeping
        // the dispatch-diag line so we can confirm typing-mode reaches
        // this function on every call.
        RealtimeConversationManager.appendDiag(
            "[typing-dispatch] rawTranscript=\"\(trimmedRawTranscript.prefix(120))\""
        )

        // v11l: dictate prefix removed — VTT toggle (double-tap Ctrl)
        // now serves the long-form raw-or-polished dictation use case,
        // making "dictate" prefix redundant and a footgun (e.g.
        // "dictate last response" was being parsed as the prefix instead
        // of the show-last-response command).
        let trimmed = trimmedRawTranscript

        guard !trimmed.isEmpty else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            do {
                // Build the image payload. If we have a focused-element
                // frame inside this screenshot, draw a green box on it
                // so Claude's vision model knows exactly where the text
                // will land. The annotator is a no-op if the conversion
                // or drawing fails, so this is safe.
                let annotatedScreenshot: CompanionScreenCapture? = {
                    guard let shot = screenshot else { return nil }
                    guard let axFrame = focusedContext?.elementFrameInAXCoords else {
                        return shot
                    }
                    return CompanionScreenshotAnnotator.addFocusBoundingBox(
                        to: shot,
                        axFrame: axFrame
                    )
                }()

                let labeledImages: [(data: Data, label: String)]
                if let shot = annotatedScreenshot {
                    let dims = " (image dimensions: \(shot.screenshotWidthInPixels)x\(shot.screenshotHeightInPixels) pixels)"
                    let boxHint = focusedContext?.elementFrameInAXCoords != nil
                        ? " — the green rectangle marks the text field the response will paste into"
                        : ""
                    labeledImages = [(data: shot.imageData, label: "screen at time of request" + dims + boxHint)]
                } else {
                    labeledImages = []
                }

                // Build the user-facing prompt. buildTypingPrompt
                // handles optional focused-element context internally
                // and also injects the rolling reference block of
                // recent spoken prompts (so "rewrite my last prompt"
                // style follow-ups have something to reference).
                let prompt = Self.buildTypingPrompt(
                    request: trimmed,
                    context: focusedContext,
                    isDictateIntent: false
                )

                let activeSystemPrompt = Self.typingModeSystemPrompt

                // Typing mode intentionally does NOT include conversation
                // history — each paste is a one-shot text-generation task.
                // Mixing in voice-companion history would confuse the
                // "output only the text to paste" instruction.
                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: activeSystemPrompt,
                    conversationHistory: [],
                    userPrompt: prompt,
                    personalFacts: Self.loadCurrentObsidianMemoryContents(),
                    onTextChunk: { _ in }
                )

                guard !Task.isCancelled else { return }

                // Strip any accidental [POINT:...] tags the model may
                // emit out of habit — typing mode never wants those.
                let cleaned = Self.parsePointingCoordinates(from: fullResponseText).spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                ClickyAnalytics.trackAIResponseReceived(response: cleaned)

                if !cleaned.isEmpty {
                    await Self.typeTextViaClipboard(cleaned)
                    Self.rememberTypingRequest(trimmedRawTranscript)

                    // v11y: persist typing-mode interaction
                    let typingInteractionId = ClickyTranscriptLogger.newInteractionId()
                    let typingTimestamp = Date()
                    var typingScreenshotPaths: [String] = []
                    if let shot = annotatedScreenshot {
                        if let path = ClickyTranscriptLogger.shared.saveScreenshotJPEG(
                            shot.imageData,
                            forInteractionId: typingInteractionId,
                            frameIndex: 0,
                            timestamp: typingTimestamp
                        ) {
                            typingScreenshotPaths.append(path)
                        }
                    }
                    ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
                        id: typingInteractionId,
                        timestamp: typingTimestamp,
                        mode: .typing,
                        rawTranscript: trimmedRawTranscript,
                        finalOutput: cleaned,
                        claudeResponse: nil,
                        polishModifier: nil,
                        appName: focusedContext?.appName,
                        screenshotPaths: typingScreenshotPaths,
                        polishStatus: nil
                    ))
                }
            } catch is CancellationError {
                // User started another interaction — drop this response
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Typing mode response error: \(error)")
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Max number of prior spoken requests we remember for the
    /// typing-mode reference block. Rolling — oldest drops off.
    private static let recentTypingRequestsCap = 5

    /// Session-scoped rolling buffer of the user's most recent spoken
    /// transcriptions passed to typing mode. Ordered newest-first.
    /// Intentionally in-memory only (not persisted) so it resets each
    /// app launch — "my last prompt" should mean "in this sitting."
    ///
    /// We surface these in the user prompt as a labeled reference
    /// block rather than via `conversationHistory`, because typing
    /// mode deliberately keeps `conversationHistory: []` — threading
    /// full assistant history would reintroduce preamble ("sure,
    /// here's...") and paste-style contamination.
    private static var recentTypingRequests: [String] = []

    /// Recovery phrases that route through `handleDictateLastRecovery`
    /// instead of the normal typing-mode pipeline. Match is exact (after
    /// lowercasing + stripping trailing punctuation) — too lax a match
    /// would risk hijacking real dictations or requests.
    private static let dictateLastRecoveryPhrases: Set<String> = [
        "dictate last",
        "dictate the last",
        "dictate that instead",
        "redo as dictate",
        "redo dictate",
        "dictate that"
    ]

    /// v15p3hb (2026-05-18): minimal mirror of
    /// `GeminiRealtimeConversationManager.SharedMarinHistoryEntry`.
    /// Schema is intentionally simple (timestamp/user/assistant) so the
    /// CompanionManager can read the file without depending on the
    /// realtime managers' private types.
    private struct SharedMarinHistoryEntryForDictateLast: Decodable {
        let timestamp: Date
        let user: String
        let assistant: String
    }

    /// Returns the most recent `assistant` text from the shared Marin
    /// conversation history file, or an empty string on any miss
    /// (file missing, parse error, empty array, latest entry has no
    /// assistant text). Reads from disk every call — the file is at
    /// most a few KB, and "show last response" is invoked rarely.
    /// v15p3hh (2026-05-19): switched to `.iso8601` date decoding to
    /// match Gemini's encoder. Default seconds-since-1970 strategy
    /// failed silently on the file's ISO8601 timestamps, returning
    /// an empty array — making the whole function a silent no-op.
    private static func loadLatestMarinAssistantTurn() -> String {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return "" }
        let url = appSupport
            .appendingPathComponent("com.stephenpierson.clickyplus", isDirectory: true)
            .appendingPathComponent("marin-conversation-history.json")
        guard let data = try? Data(contentsOf: url) else { return "" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode(
            [SharedMarinHistoryEntryForDictateLast].self, from: data
        ) else { return "" }
        // Entries are appended chronologically; the latest is at the
        // end. Walk back to find the first entry with non-empty
        // assistant text (skip seed/empty rows).
        for entry in entries.reversed() {
            let candidate = entry.assistant
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
        }
        return ""
    }

    /// Returns true if the trimmed transcript matches a recovery phrase.
    /// Strips a single trailing terminal punctuation mark (period, comma,
    /// exclamation, question mark) before comparison so AssemblyAI's
    /// auto-punctuation doesn't hide a match.
    static func isDictateLastRecoveryPhrase(_ transcript: String) -> Bool {
        let trimmedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedTrailingPunctuation = trimmedTranscript.hasSuffix(".")
            || trimmedTranscript.hasSuffix(",")
            || trimmedTranscript.hasSuffix("!")
            || trimmedTranscript.hasSuffix("?")
            ? String(trimmedTranscript.dropLast())
            : trimmedTranscript
        let normalizedForMatching = strippedTrailingPunctuation.lowercased()
        return dictateLastRecoveryPhrases.contains(normalizedForMatching)
    }

    /// v15p3hb (2026-05-18): repurposed. The phrase now pastes the most
    /// recent thing **Marin** said, pulled from the shared conversation
    /// history file that both the Gemini and OpenAI Realtime providers
    /// persist to (`marin-conversation-history.json`). The original
    /// "undo previous typing-mode paste and redo as dictate" behavior
    /// was retired — Steph wasn't using it, and the trigger phrase
    /// reads more naturally as "give me what Marin just said in text."
    private func handleDictateLastRecovery() {
        let latestMarinTurnText = Self.loadLatestMarinAssistantTurn()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // v15p3hg (2026-05-19): persistent diag so we can confirm
        // what got read from marin-conversation-history.json and
        // what got pasted.
        RealtimeConversationManager.appendDiag(
            "[dictate-last] loaded latestMarinTurn chars=\(latestMarinTurnText.count) preview=\"\(latestMarinTurnText.prefix(100))\""
        )

        guard !latestMarinTurnText.isEmpty else {
            RealtimeConversationManager.appendDiag("[dictate-last] empty result, bailing")
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            await Self.typeTextViaClipboard(latestMarinTurnText)
            ClickyAnalytics.trackAIResponseReceived(response: latestMarinTurnText)

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Synthesize a Cmd+Z to undo the previous paste in whatever app
    /// has keyboard focus. Mirror of synthesizeCommandV/synthesizeCommandA;
    /// uses CGEvent so it works regardless of keyboard layout.
    @MainActor
    private static func synthesizeCommandZ() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key code 6 = 'z' on US layouts. Same semantic-rewrite
        // story as Cmd+V — reliable across keyboard layouts.
        let keyZCode: CGKeyCode = 6

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyZCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyZCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Detect the typing-mode "dictate" intent override. If the
    /// transcript starts with the word "dictate" (case-insensitive,
    /// optionally followed by `:`, `,`, or just whitespace), return
    /// the transcript with that prefix stripped + a flag indicating
    /// the override fired. Otherwise return the input unchanged + flag false.
    ///
    /// Only the prefix form fires the override. A transcript that
    /// merely contains "dictate" mid-sentence is treated as a normal
    /// respond-to-my-request typing-mode call.
    static func detectDictatePrefix(_ transcript: String) -> (transcriptWithPrefixStripped: String, didMatchDictatePrefix: Bool) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return (transcriptWithPrefixStripped: transcript, didMatchDictatePrefix: false)
        }

        // Lowercase the first 8 chars to do a cheap case-insensitive
        // prefix check without allocating a full lowercased copy.
        let lowercasedTranscript = trimmedTranscript.lowercased()
        guard lowercasedTranscript.hasPrefix("dictate") else {
            return (transcriptWithPrefixStripped: transcript, didMatchDictatePrefix: false)
        }

        // The prefix matched. Now confirm "dictate" is a STANDALONE
        // word (not the start of e.g. "dictated" or "dictation"). We
        // do this by looking at the character immediately after the
        // 7-char "dictate" prefix.
        let prefixEndIndex = trimmedTranscript.index(trimmedTranscript.startIndex, offsetBy: 7)
        if prefixEndIndex == trimmedTranscript.endIndex {
            // Transcript is JUST "dictate" — match, with empty remainder.
            return (transcriptWithPrefixStripped: "", didMatchDictatePrefix: true)
        }
        let charAfterPrefix = trimmedTranscript[prefixEndIndex]
        let isWordBoundaryAfterPrefix = charAfterPrefix.isWhitespace
            || charAfterPrefix == ":"
            || charAfterPrefix == ","
        guard isWordBoundaryAfterPrefix else {
            // It was "dictated" / "dictation" / "dictates" etc — not the override.
            return (transcriptWithPrefixStripped: transcript, didMatchDictatePrefix: false)
        }

        // Strip "dictate" + the boundary character + any extra
        // leading whitespace from the remainder.
        let remainderStartIndex = trimmedTranscript.index(after: prefixEndIndex)
        let remainder = trimmedTranscript[remainderStartIndex...]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:")))
        return (transcriptWithPrefixStripped: remainder, didMatchDictatePrefix: true)
    }

    /// System prompt for TYPING MODE. Computed (not `let`) so the
    /// current date is re-stamped on every call — this prevents Claude
    /// from back-dating content to model-training-cutoff dates when the
    /// user asks it to write anything date-sensitive (emails, notes,
    /// "what day is today", etc.).
    private static var typingModeSystemPrompt: String {
        let today = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withFullDate]
        )
        return """
        current date: \(today). any dated references (today, yesterday, "this week", "next month", etc.) resolve relative to that — never guess, never fall back to a training-cutoff date.

        you're clicky, operating in TYPING MODE. the user held Fn+Cmd, spoke a request, and your reply will be pasted directly into whatever text field they had focused — slack, email, a doc, a code editor, anywhere. a screenshot of their screen at the moment they triggered you is attached so you can see the context. if a green rectangle is drawn on the screenshot, that's the exact field your response will land in — anchor on it.

        alongside the screenshot you may receive structured context: the target app, the kind of field (role/description), its label, the window title, and a short tail of text already in the field. treat that as authoritative — it's more reliable than inferring from pixels. when "current field text" is provided, mirror its voice, tense, capitalization style, and sign-off pattern. if the user's cursor is mid-sentence, continue the sentence naturally rather than starting a fresh one.

        your ONLY job is to produce the exact text they want pasted. nothing else.

        strict rules:
        - output ONLY the content to be pasted. no preamble like "sure, here's...", no "let me know if you need changes", no closing remarks, no meta-commentary.
        - do not wrap the output in quotation marks, backticks, or code fences unless the target field is clearly a code block that needs them.
        - match the tone and register implied by the context. slack casual, email polite, code terse, doc formal, terminal commands raw. when in doubt, lean on the current field text.
        - no markdown unless the target field clearly supports it (e.g. a markdown editor, readme, obsidian note). in slack, email composers, most form inputs — use plain text.
        - if they ask for a message reply, write only the body. no subject line or greeting unless explicitly asked or clearly expected from context.
        - if the request is ambiguous, make a reasonable choice and produce something useful. DO NOT ask a clarifying question — the output is being pasted immediately, there's no back-and-forth.
        - do NOT emit any [POINT:...] tags. no pointing in typing mode.
        - do NOT lowercase everything by reflex — typing mode uses normal capitalization, punctuation, and formatting appropriate to the destination.
        - execute the user's LITERAL spoken request. do NOT reinterpret it through the lens of the surrounding conversation theme or recent session context — if they said "write X", write X, even if the broader conversation has been about something else.
        - if the user asks you to include, repeat, or quote their own words verbatim (e.g. "put my exact question at the top", "quote what I just said", "transcribe this prompt"), reproduce the transcribed request EXACTLY as received, inside quotes, without paraphrasing, cleaning up, rewording, or fixing grammar. verbatim means verbatim — typos and filler words included.
        - if the user references a PREVIOUS prompt ("my last prompt", "the one before", "what I said earlier", "rewrite the last thing I said", etc.), look it up in the "[recent spoken prompts this session]" reference block (if present in the user message) and reproduce it per the verbatim rule above. NEVER paste the reference block itself — it's metadata, not content to paste. if no reference block is present, say so in a short bracketed note.
        - if you genuinely cannot produce the text (e.g. the screenshot is blank and the request is meaningless), output a single short bracketed note like "(couldn't tell what to write — say more?)" so the user sees it in-place.
        """
    }

    /// System prompt for the typing-mode DICTATE intent override
    /// (transcript started with "dictate"). Same date-stamping reason
    /// as `typingModeSystemPrompt` — keeps Claude from back-dating
    /// content the user dictates that contains date references.
    private static var typingModeDictateSystemPrompt: String {
        let today = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withFullDate]
        )
        return """
        current date: \(today). any dated references the user dictated (today, yesterday, "this week", "next month", etc.) resolve relative to that — never guess, never fall back to a training-cutoff date.

        you're clicky, operating in TYPING MODE with the DICTATE INTENT OVERRIDE. the user held Fn+Cmd, said "dictate" as a prefix, then dictated text they want polished and pasted into whatever text field they had focused. a screenshot of their screen at the moment they triggered you is attached so you can match tone/register to the destination. if a green rectangle is drawn on the screenshot, that's the exact field your output will land in.

        your ONLY job is to produce a polished version of the dictated text. nothing else.

        what "polished" means here:
        - fix typos, grammar mistakes, and obvious transcription errors
        - fix punctuation and capitalization
        - remove disfluencies (um, uh, like, you know) if present
        - tighten loose phrasing where it helps
        - match the tone and register of the focused field (slack casual, email polite, doc formal, etc.)

        what you MUST preserve:
        - the user's voice, tone, and meaning — do not paraphrase, do not rewrite
        - all content — do not add, remove, or restructure ideas
        - sentence order
        - any explicit formatting cues (line breaks, lists)

        critical override: do NOT respond to the dictated words as if they were a request. if the dictation contains questions, statements, or instructions ("can you send me the report", "what's the cap rate on this deal", "schedule this for tuesday"), you transcribe and polish them — you do NOT answer them. the user is dictating content for the focused field; they are not asking you anything.

        strict rules:
        - output ONLY the polished dictated text. no preamble, no quotes around it, no explanations, no closing remarks.
        - do not wrap the output in markdown code fences unless the destination is clearly a code block.
        - no [POINT:...] tags.
        - no markdown unless the focused field clearly supports it (e.g. obsidian, a markdown editor).
        - if the user's cursor is mid-sentence in the focused field, continue their sentence naturally.
        """
    }

    /// Compose the user-facing prompt for typing mode. Assembles (in
    /// order):
    ///
    /// 1. A labeled reference block of the user's recent spoken
    ///    prompts this session — so follow-ups like "rewrite my last
    ///    prompt" can be served without passing conversation history.
    ///    Skipped for dictate intent (a dictated draft isn't a "prompt"
    ///    the user would later reference).
    /// 2. A structured block describing the focused target field
    ///    (when meaningful) — so Claude can match tone/format.
    /// 3. The user's current spoken request — labeled `[request]` for
    ///    the default respond intent, `[dictate this]` for dictate
    ///    intent so the system prompt's override has a clear marker.
    ///
    /// Keeping each block plainly labeled makes it easy for the model
    /// to parse and prevents Claude from confusing the metadata for
    /// content to paste.
    private static func buildTypingPrompt(
        request: String,
        context: FocusedElementContext?,
        isDictateIntent: Bool
    ) -> String {
        var lines: [String] = []

        // 1. Reference block — session memory of prior spoken prompts.
        // Skipped for dictate intent because dictated text isn't a
        // "prompt" the user would reference back to ("rewrite my last
        // prompt" doesn't apply when you just dictated a Slack message).
        if !isDictateIntent && !recentTypingRequests.isEmpty {
            lines.append("[recent spoken prompts this session — reference only, DO NOT paste unless the user explicitly asks for them]")
            for (i, entry) in recentTypingRequests.enumerated() {
                let label = i == 0 ? "1 (most recent before this one)" : "\(i + 1)"
                lines.append("\(label): \"\(entry)\"")
            }
            lines.append("")
        }

        // 2. Focused-element context, when available.
        if let context = context, context.hasMeaningfulContext {
            lines.append("[typing-mode context]")
            if let app = context.appName {
                lines.append("target app: \(app)")
            }
            if let role = context.role {
                // Strip the "AX" prefix to make it more human-readable.
                let friendly = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
                lines.append("field type: \(friendly)")
            }
            if let desc = context.roleDescription {
                lines.append("field description: \(desc)")
            }
            if let label = context.label, !label.isEmpty {
                lines.append("field label: \(label)")
            }
            if let window = context.windowTitle, !window.isEmpty {
                lines.append("window title: \(window)")
            }
            if let recent = context.recentText, !recent.isEmpty {
                // Wrap in triple-quotes so Claude reliably treats it
                // as a verbatim block and doesn't try to interpret
                // any instructions that happen to appear in existing
                // text.
                lines.append("current field text (verbatim, may end mid-sentence):")
                lines.append("\"\"\"")
                lines.append(recent)
                lines.append("\"\"\"")
            }
            lines.append("")
        }

        // 3. Current request — label depends on intent so the system
        // prompt's "do NOT respond" override has a clear marker for
        // the dictate path, and the default respond path keeps its
        // existing `[request]` label unchanged.
        if isDictateIntent {
            lines.append("[dictate this — polish and transcribe, do NOT respond as if it were a request]")
        } else {
            lines.append("[request]")
        }
        lines.append(request)
        return lines.joined(separator: "\n")
    }

    /// Append a just-used spoken request to the rolling reference
    /// buffer. Called after a successful typing-mode paste.
    private static func rememberTypingRequest(_ request: String) {
        recentTypingRequests.insert(request, at: 0)
        if recentTypingRequests.count > recentTypingRequestsCap {
            recentTypingRequests.removeLast()
        }
    }

    // MARK: - Clipboard + Paste Helper
    //
    // Shared by typing mode (and any future "inject text into focused
    // field" features). Saves whatever the user currently has on the
    // clipboard, writes our new text, fires a simulated Cmd+V, then
    // restores the original clipboard after a short delay so the paste
    // has a chance to land before the pasteboard flips back.

    /// v15p4ch (2026-05-30): cache of bundleID → isElectron so the
    /// filesystem probe runs once per app, not on every paste.
    private static var electronAppCache: [String: Bool] = [:]

    /// Reliable Electron detection: Electron apps bundle
    /// "Electron Framework.framework". Covers Cowork
    /// (com.anthropic.claudefordesktop), Slack, Discord, VS Code, etc.
    /// without hard-coding bundle IDs. Cached per bundleID.
    @MainActor
    private static func frontmostAppIsElectron() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let key = app.bundleIdentifier ?? app.bundleURL?.path ?? ""
        if let cached = electronAppCache[key] { return cached }
        var result = false
        if let url = app.bundleURL {
            let fw = url.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework"
            )
            result = FileManager.default.fileExists(atPath: fw.path)
        }
        electronAppCache[key] = result
        return result
    }

    /// Places `text` on the clipboard, simulates Cmd+V to paste it into
    /// whatever view has focus, then restores the previous clipboard
    /// contents. Runs entirely on the main actor because NSPasteboard
    /// and CGEvent synthesis both want the main thread.
    // v16po (2026-06-05): de-private'd so Marin's `fill_cells` tool can
    // reuse this exact paste path (clipboard + Cmd+V + Electron latch).
    @MainActor
    static func typeTextViaClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // Write our text to the clipboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the destination app a beat to notice the new clipboard
        // contents, then fire Cmd+V.
        // VTT-SPEED Tier 1 (v15m, 2026-05-01): tightened 80ms → 30ms.
        // Most apps notice clipboard changes in well under 30ms; the
        // older 80ms was conservative padding from when we were also
        // restoring the prior clipboard (which we no longer do).
        //
        // Tunable via UserDefaults `clicky.prePasteLatchMs` (default 30,
        // clamped 0...500) so we can A/B if 30ms turns out too tight
        // for any app without rebuilding.
        // v15p4ch (2026-05-30): Electron/Chromium apps (Cowork, Slack,
        // Discord, VS Code) are slow to register a freshly-written
        // clipboard before a synthetic Cmd+V — the 30ms default raced
        // and silently dropped pastes into Cowork (the chime still
        // played, so it looked like a clean transcript just vanished).
        // Use a longer latch when the frontmost app is Electron.
        let isElectronTarget = Self.frontmostAppIsElectron()
        let defaultLatch = isElectronTarget
            ? (UserDefaults.standard.object(forKey: "clicky.prePasteLatchMsElectron") as? Int ?? 110)
            : (UserDefaults.standard.object(forKey: "clicky.prePasteLatchMs") as? Int ?? 30)
        let prePasteLatchMs = max(0, min(500, defaultLatch))
        if prePasteLatchMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(prePasteLatchMs) * 1_000_000)
        }
        await synthesizeCommandV()

        // Wait for the paste to land.
        // VTT-SPEED Tier 1 (v15m, 2026-05-01): tightened 400ms → 150ms.
        // Empirically, AppKit / WebKit / Electron all consume the
        // pasteboard in 30–80ms after Cmd+V. 150ms keeps a safety
        // margin for slow Electron apps without burning a quarter
        // second of perceived latency on every VTT.
        //
        // Tunable via UserDefaults `clicky.postPasteWaitMs` (default 150,
        // clamped 0...2000) for the same A/B reasons.
        let postPasteWaitMs = max(0, min(2000,
            UserDefaults.standard.object(forKey: "clicky.postPasteWaitMs") as? Int ?? 150
        ))
        if postPasteWaitMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(postPasteWaitMs) * 1_000_000)
        }

        // SAFETY NET (v11i, 2026-04-27): we INTENTIONALLY leave the
        // transcript in the clipboard rather than restoring the user's
        // prior clipboard contents. Reason: silent paste-failures (focus
        // wrong, focused field rejected the input, simulated Cmd+V
        // didn't fire correctly) used to lose the entire transcript.
        // Now Steph can always Cmd+V to retrieve the most recent VTT /
        // typing-mode / polish output if the auto-paste didn't take.
        //
        // Tradeoff: Steph's prior clipboard contents get overwritten on
        // every VTT-style action. Acceptable since VTT runs ~hundreds of
        // times a day and clipboard data is rarely so precious that
        // losing it (vs losing a transcript) is the worse outcome.
    }

    /// Synthesize a Cmd+V key down + key up to paste. Uses CGEvent so it
    /// works against whatever app currently has keyboard focus.
    @MainActor
    private static func synthesizeCommandV() async {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key code 9 = 'v' on US layouts. Paste is a standard
        // shortcut across layouts because AppKit rewrites by semantic
        // meaning, so this keycode works globally.
        let keyVCode: CGKeyCode = 9

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyVCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)

        // v15p4ch (2026-05-30): brief gap between key-down and key-up.
        // Chromium/Electron (Cowork) intermittently drops a synthetic
        // Cmd+V posted as a zero-duration chord; a ~12ms hold makes the
        // keystroke register reliably. Negligible perceived latency.
        try? await Task.sleep(nanoseconds: 12_000_000)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyVCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    image context (v12r):
    you may receive TWO kinds of images in a single request:
    1. "click frame N of M — pre-click at (x,y)" or "post-click at (x,y)" — these are screenshots captured WHILE the user was holding push-to-talk and clicking through their workflow. each click captures a pre-frame (the screen the user was about to act on) and a post-frame (the screen ~350ms after the click, showing any UI reaction). frames arrive in chronological order and tell a step-by-step story of what the user did during this voice session. the (x,y) coordinates are the screen pixel location of the click.
    2. "final baseline" / "primary focus" — the full all-screens snapshot taken at the moment the user finished speaking, showing the final state of their work.
    when you see click frames, treat the sequence as the context for the user's question — they're often asking about something they just did, want to understand, or want documented. reference specific clicks when it helps ("after you clicked the export button…", "i saw you switch from the inventory tab to the launches tab…"). if a question is general or abstract, you can ignore the click context entirely.

    rules:
    - MATCH STEPH'S ENERGY. a tiny conversational question gets a tiny conversational answer. a substantive question gets a substantive answer. a "tell me more" / "explain X" gets a thorough answer. don't pad short questions with extra material.
        - examples (memorize these — the most common pattern):
            - "hey, are you there?" → "yeah, i'm here." (4 words. nothing else.)
            - "you good?" → "yep." or "all good."
            - "can you hear me?" → "yeah, loud and clear."
            - "what's today's date?" → "april thirtieth."
            - "what time is it?" → "twelve fifty-eight."
        - examples for substantive questions (you're allowed to be longer here):
            - "what's the difference between X and Y?" → 1-3 sentences explaining
            - "explain how this code works" → as long as it needs to be
            - "what's on my screen?" → describe what's actually there
    - DO NOT volunteer commentary on the screen unless the user's question is about the screen, OR they explicitly invited it ("anything you notice?", "what do you see?"). if the question is purely conversational ("are you there?"), the screen is NOT relevant — just answer the question. no "i can see you've got X open" tacked on.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - for substantive answers: focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends.
    - for substantive answers: when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper. it's okay to not end with anything extra if the answer is complete on its own. NEVER plant seeds on tiny conversational answers — that's the same padding behavior we're trying to eliminate.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing (OPT-IN ONLY):
    you have a small blue triangle cursor that can fly to and point at things on screen, but it's OFF BY DEFAULT. only point when the user EXPLICITLY asks you to locate something visually — phrases like "where is", "show me", "point at", "point to", "where's the", "find the", "where do I click", "how do I navigate to". if the user is asking a general "how" question, asking you to explain something, or asking a knowledge question, do NOT point — just answer.

    when pointing IS requested, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if the user did not explicitly ask you to locate or show something on screen, append [POINT:none] — this is the default for the vast majority of questions.

    examples:
    - user asks "where's the color inspector?" (explicit "where") → "you'll want to open the color inspector — it's right up in the top right area of the toolbar. [POINT:1100,42:color inspector]"
    - user asks "how do I color grade in final cut?" (general how-to, not asking to be shown) → "you'll want to open the color inspector and use the color wheels and curves. [POINT:none]"
    - user asks "what is html?" → "html stands for hypertext markup language, it's basically the skeleton of every web page. [POINT:none]"
    - user asks "show me where to commit in xcode" (explicit "show me") → "see that source control menu up top? click that and hit commit. [POINT:285,11:source control]"
    - user asks "how do I commit in xcode?" (general how-to) → "you can use the source control menu, or hit command option c as a shortcut. [POINT:none]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    /// v16qp (2026-06-17): base-PTT diagnostic log. Writes pipeline
    /// milestones to action-log/base-ptt.log so a stuck-spinner hang is
    /// diagnosable without a terminal launch (which breaks TCC perms).
    nonisolated static func logBasePTT(_ msg: String) {
        let dir = ("~/Library/Application Support/Clicky/action-log" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("base-ptt.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()

        Self.logBasePTT("START transcript=\"\(transcript.prefix(60))\"")
        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            // v12r: snapshot the click-capture buffer at the START of
            // the send so any late-arriving post-frames after this point
            // belong to the next session, not this one. The buffer is
            // cleared on the next session's start.
            let clickFramesSnapshot = await MainActor.run { [weak self] in
                self?.voiceModeClickFrames ?? []
            }

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // v12r: dedup the click-pair frames (drop post-frames
                // that didn't change the screen — usually clicks on
                // text or already-selected items).
                let dedupedClickFrames = await MainActor.run { [weak self] in
                    self?.dedupedVoiceModeClickFrames(clickFramesSnapshot) ?? clickFramesSnapshot
                }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                //
                // v12r: click-capture frames are sent FIRST in chronological
                // order, then the final all-screens baseline. Each click
                // frame's label includes the click coordinates, pre/post
                // tag, and a sequence number so Claude can reason about
                // the user's step-by-step process.
                var labeledImages: [(data: Data, label: String)] = []

                for (idx, frame) in dedupedClickFrames.enumerated() {
                    let phase = frame.isPostClick ? "post-click" : "pre-click"
                    let coords = "(\(Int(frame.clickPoint.x)), \(Int(frame.clickPoint.y)))"
                    let dims = " (image dimensions: \(frame.widthInPixels)x\(frame.heightInPixels) pixels)"
                    let label = "click frame \(idx + 1) of \(dedupedClickFrames.count) — \(phase) at \(coords)" + dims
                    labeledImages.append((data: frame.imageData, label: label))
                }

                // v16qs (2026-06-17): send ONLY the active screen (the one the
                // cursor is on), like Marin. Base PTT used to map ALL screenCaptures
                // into the baseline, so Claude narrated every monitor. Fall back to
                // all screens only if the cursor screen can't be identified, so we
                // never send zero baseline frames.
                let cursorScreenCaptures = screenCaptures.filter { $0.isCursorScreen }
                let baselineSource = cursorScreenCaptures.isEmpty ? screenCaptures : cursorScreenCaptures
                let baselineImages = baselineSource.map { capture -> (data: Data, label: String) in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    let prefix = dedupedClickFrames.isEmpty ? "" : "final baseline — "
                    return (data: capture.imageData, label: prefix + capture.label + dimensionInfo)
                }
                labeledImages.append(contentsOf: baselineImages)

                // v16qp (2026-06-17): Marin-grade vision. Add a high-detail
                // FOVEA CROP around the cursor — the sharp tile of the screen
                // Steph is actually working on. Without this, base PTT only
                // sent the full (downscaled) all-screens view, so Claude
                // couldn't read fine detail like Marin can. Mirrors Marin's
                // sendVisionContent fovea pipeline.
                if let cursorCapture = screenCaptures.first(where: { $0.isCursorScreen }),
                   let cg = cursorCapture.cgImage,
                   let crop = CursorFoveaCropper.cropAroundCursor(
                       sourceImage: cg,
                       cursorInImagePixels: cursorCapture.cursorPositionInImagePixels) {
                    let cx = Int(crop.cursorInCropPixels.x.rounded())
                    let cy = Int(crop.cursorInCropPixels.y.rounded())
                    labeledImages.append((
                        data: crop.jpegData,
                        label: "high-detail crop around the cursor (\(crop.widthInPixels)x\(crop.heightInPixels) pixels) — trust this as the sharp source for fine detail near the cursor; cursor is at pixel (\(cx),\(cy)) within this crop"
                    ))
                }

                if !dedupedClickFrames.isEmpty {
                    print("📸 Voice mode → Claude: \(dedupedClickFrames.count) click frame(s) + \(baselineImages.count) baseline screen(s)")
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }
                // v16qn: attach the last few turns' screenshots so Claude
                // SEES recent screens, not just text (Claude Vision Phase 1).
                let historyImages: [[Data]] = {
                    let n = conversationHistory.count
                    return conversationHistory.enumerated().map { idx, entry in
                        idx >= n - claudeVisualMemoryTurns ? entry.screenshots : []
                    }
                }()


                // Streaming TTS (v11j): per-sentence chunking with a
                // sequential player loop. Each sentence boundary in the
                // stream queues its own synthesis Task; the player loop
                // dequeues completed audio and plays them in order.
                // Synthesis runs ~4× faster than playback so the queue
                // stays ahead — eliminates the multi-second mid-response
                // gap that one-big-TTS#2 produced.
                //
                // Voicebox-only: only LocalVoiceboxTTSClient supports the
                // synthesizeAudio/playAudio split. Other providers fall
                // through to the legacy single-shot path after streaming.
                let streamingState = StreamingMultiSentenceState()
                // v13e: expose to Esc handler so it can kill all queued
                // sentences in one shot. Cleared in defer at function exit.
                self.currentStreamingState = streamingState
                defer {
                    Task { @MainActor [weak self] in
                        // Only clear if it's still our state — guards against
                        // a newer PTT session that already replaced it.
                        if self?.currentStreamingState === streamingState {
                            self?.currentStreamingState = nil
                        }
                    }
                }
                let voiceboxClient = ttsClient as? LocalVoiceboxTTSClient

                if let voiceboxClient {
                    // Wire the synthesis-task stream + player loop. The
                    // player loop runs as a child Task; it drains the
                    // stream, awaits each synthesis Task in order, plays
                    // the audio. When the continuation finishes (after
                    // streaming completes + final chunk emitted), the
                    // for-await loop terminates and the loop returns.
                    let (taskStream, taskContinuation) = AsyncStream<Task<Data, Error>>.makeStream()
                    streamingState.taskContinuation = taskContinuation
                    streamingState.playerLoopTask = Task { [weak self] in
                        for await synthesisTask in taskStream {
                            if Task.isCancelled { break }
                            let audio: Data
                            do {
                                audio = try await synthesisTask.value
                            } catch {
                                if Task.isCancelled { break }
                                print("⚠️ Streaming TTS: synthesis task failed (\(error))")
                                continue
                            }
                            // First playback: triangle visible, voiceState .responding
                            await MainActor.run {
                                guard let self else { return }
                                streamingState.lock.lock()
                                let firstPlayback = !streamingState.didFlipToResponding
                                streamingState.didFlipToResponding = true
                                streamingState.lock.unlock()
                                if firstPlayback {
                                    self.voiceState = .responding
                                }
                            }
                            do {
                                try await voiceboxClient.playAudio(audio)
                            } catch {
                                if Task.isCancelled { break }
                                print("⚠️ Streaming TTS: playback failed (\(error))")
                                continue
                            }
                        }
                    }
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    historyImages: historyImages,
                    userPrompt: transcript,
                    personalFacts: Self.loadCurrentObsidianMemoryContents(),
                    onTextChunk: { [weak voiceboxClient] chunk in
                        // ClaudeAPI passes CUMULATIVE accumulated text per
                        // call, not delta — assign, don't append.
                        guard let voiceboxClient else { return }
                        streamingState.lock.lock()
                        streamingState.sentenceBuffer = chunk
                        var sentencesToEmit: [String] = []
                        // Drain ALL newly-completed sentences past the
                        // emitted offset. A single chunk can contain
                        // multiple sentence boundaries.
                        while let range = Self.nextSentenceCharRange(
                            in: streamingState.sentenceBuffer,
                            startCharOffset: streamingState.emittedCharOffset
                        ) {
                            let nsBuffer = streamingState.sentenceBuffer as NSString
                            let sentenceNSRange = NSRange(location: range.start, length: range.end - range.start)
                            let rawSentence = nsBuffer.substring(with: sentenceNSRange)
                            let cleaned = Self.parsePointingCoordinates(from: rawSentence).spokenText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            streamingState.emittedCharOffset = range.end
                            if !cleaned.isEmpty {
                                sentencesToEmit.append(cleaned)
                            }
                        }
                        let continuation = streamingState.taskContinuation
                        streamingState.lock.unlock()

                        for sentence in sentencesToEmit {
                            let synthesisTask = Task<Data, Error> {
                                try await voiceboxClient.synthesizeAudio(text: sentence)
                            }
                            continuation?.yield(synthesisTask)
                            print("🗣️ Streaming TTS: queued sentence (\(sentence.count) chars)")
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                Self.logBasePTT("CLAUDE_RETURNED len=\(fullResponseText.count)")
                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText
                Self.logBasePTT("SPOKEN len=\(spokenText.count) preview=\"\(spokenText.prefix(40))\"")

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                // v16qn: store the cursor screen so Claude can recall this
                // view on later turns (Claude Vision Phase 1).
                let memoryShot = (screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first)?.imageData
                conversationHistory.append(ConversationEntry(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    screenshots: memoryShot.map { [$0] } ?? []
                ))

                // Keep only the last 30 exchanges to avoid unbounded context growth
                if conversationHistory.count > 30 {
                    conversationHistory.removeFirst(conversationHistory.count - 30)
                }

                // Persist history to disk so continuity survives app restarts
                saveConversationHistory()

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // v11y: persist base-PTT interaction (transcript + Claude
                // response + screenshot paths). Screenshots saved per-frame.
                let basePTTInteractionId = ClickyTranscriptLogger.newInteractionId()
                let basePTTTimestamp = Date()
                var basePTTScreenshotPaths: [String] = []
                for (frameIndex, capture) in screenCaptures.enumerated() {
                    if let path = ClickyTranscriptLogger.shared.saveScreenshotJPEG(
                        capture.imageData,
                        forInteractionId: basePTTInteractionId,
                        frameIndex: frameIndex,
                        timestamp: basePTTTimestamp
                    ) {
                        basePTTScreenshotPaths.append(path)
                    }
                }
                ClickyTranscriptLogger.shared.log(ClickyInteractionLog(
                    id: basePTTInteractionId,
                    timestamp: basePTTTimestamp,
                    mode: .basePTT,
                    rawTranscript: transcript,
                    finalOutput: nil,
                    claudeResponse: spokenText,
                    polishModifier: nil,
                    appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                    screenshotPaths: basePTTScreenshotPaths,
                    polishStatus: nil
                ))

                // Play the response via TTS. Two paths:
                //   • Voicebox streaming (preferred): the per-sentence
                //     player loop is already running. Emit the final
                //     trailing chunk (text past the last sentence boundary,
                //     with [POINT:] stripped), finish the task continuation,
                //     await the loop to drain.
                //   • Fallback (ElevenLabs/Grok): just speak the whole text
                //     in one shot — those clients don't support the
                //     synthesizeAudio/playAudio split.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        Self.logBasePTT("TTS_PATH voicebox=\(voiceboxClient != nil) cont=\(streamingState.taskContinuation != nil) loop=\(streamingState.playerLoopTask != nil)")
                        if let voiceboxClient,
                           let taskContinuation = streamingState.taskContinuation,
                           let playerLoopTask = streamingState.playerLoopTask {
                            // Streaming-Voicebox path. Compute the FINAL
                            // chunk (text past the last sentence boundary)
                            // and emit it as one last synthesis task. Then
                            // finish the continuation and await the player.
                            let nsResponse = fullResponseText as NSString
                            streamingState.lock.lock()
                            let finalOffset = streamingState.emittedCharOffset
                            streamingState.lock.unlock()
                            if finalOffset < nsResponse.length {
                                let finalRawText = nsResponse.substring(
                                    from: finalOffset
                                )
                                let finalCleaned = Self.parsePointingCoordinates(from: finalRawText).spokenText
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if !finalCleaned.isEmpty {
                                    let finalSynthTask = Task<Data, Error> {
                                        try await voiceboxClient.synthesizeAudio(text: finalCleaned)
                                    }
                                    taskContinuation.yield(finalSynthTask)
                                    print("🗣️ Streaming TTS: queued final chunk (\(finalCleaned.count) chars)")
                                }
                            }
                            // Signal that no more synthesis tasks are coming.
                            // The player loop's for-await ends when the
                            // continuation finishes AND all queued items
                            // have been processed.
                            taskContinuation.finish()

                            // Await the player loop. Resolves when all
                            // queued audio has finished playing.
                            try await playerLoopTask.value

                            // Cursor flight already ran during playback
                            // (voiceState was flipped to .idle when we
                            // parsed [POINT:] earlier in this method, so
                            // the triangle was visible during audio).
                        } else {
                            // Fallback for non-Voicebox providers.
                            try await ttsClient.speakText(spokenText)
                            voiceState = .responding
                        }
                    } catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            // Interrupted by another interaction — stay silent
                            return
                        }
                        Self.logBasePTT("ERROR(tts): \((error as NSError).localizedDescription)")
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ TTS error (streaming): \(error)")
                        speakCreditsErrorFallback(error: error)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    // Interrupted by another interaction — stay silent
                    return
                }
                Self.logBasePTT("ERROR(response): \((error as NSError).localizedDescription)")
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback(error: error)
            }

            Self.logBasePTT("REACHED_END cancelled=\(Task.isCancelled)")
            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks an error fallback using macOS system TTS. Inspects the error
    /// and only claims "out of credits" when it's actually a credit-related
    /// HTTP error from Anthropic. Other errors get a generic "something went
    /// wrong" message — and the actual error is printed to console so future
    /// debugging surfaces the real cause instead of a misleading credit message.
    /// Uses NSSpeechSynthesizer so it works even when our normal TTS is down.
    private func speakCreditsErrorFallback(error: Error? = nil) {
        let utterance: String
        if let error {
            print("⚠️ Error fallback raised — actual error: \(error)")
            let description = (error as NSError).localizedDescription.lowercased()
            if description.contains("credit") || description.contains("402")
                || description.contains("billing") || description.contains("insufficient") {
                utterance = "Heads up Steph, I'm out of credits. Top up the Anthropic account and I'll be right back."
            } else if (error as? URLError) != nil {
                utterance = "Network hiccup, Steph. Try that again in a sec."
            } else {
                utterance = "Something went wrong on my end, Steph. Check the console."
            }
        } else {
            utterance = "Something went wrong on my end, Steph. Check the console."
        }
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Streaming TTS Helpers

    /// Holds mutable state for the per-sentence streaming-TTS pipeline.
    /// As Claude streams text chunks, sentence boundaries are detected
    /// and each sentence is queued as a synthesis task. A separate
    /// player-loop dequeues completed audio and plays sequentially.
    /// Synthesis runs ~4× faster than playback so the queue stays ahead,
    /// eliminating mid-response gaps.
    final class StreamingMultiSentenceState {
        /// Cumulative accumulated text from `analyzeImageStreaming`.
        var sentenceBuffer = ""
        /// Char offset (in `sentenceBuffer`) we've already emitted as
        /// completed sentences. Each new chunk: scan for boundaries past
        /// this offset, slice + emit, advance.
        var emittedCharOffset = 0
        /// True once we've started the player loop. We start it lazily on
        /// the first sentence so playback begins ASAP.
        var playerLoopStarted = false
        /// Continuation for the synthesis-task stream consumed by the
        /// player loop. Each detected sentence yields a Task<Data, Error>;
        /// the player loop awaits each in order, plays the audio.
        var taskContinuation: AsyncStream<Task<Data, Error>>.Continuation?
        /// Handle to the player loop. Awaiting `.value` blocks until all
        /// queued audio has finished playing.
        var playerLoopTask: Task<Void, Error>?
        /// Set after voiceState has flipped to .responding on first play.
        /// We use this so subsequent chunks don't re-set the same state.
        var didFlipToResponding = false
        let lock = NSLock()
    }

    /// Returns the index AFTER the first sentence-ending punctuation
    /// (period, exclamation, or question mark) followed by whitespace
    /// or end-of-string. Returns nil if no sentence end is found.
    static func indexAfterFirstSentenceEnd(in text: String) -> String.Index? {
        guard let regex = try? NSRegularExpression(pattern: #"[.!?](?:\s|$)"#) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        let endLocation = match.range.location + 1
        return Range(NSRange(location: endLocation, length: 0), in: text)?.lowerBound
    }

    /// Returns the (start..end) char-offset range of the NEXT sentence in
    /// `text` starting at `startCharOffset`, OR nil if no complete sentence
    /// terminator follows. Used by per-sentence streaming TTS to slice each
    /// new sentence as the buffer grows. Char offsets are in UTF-16 units
    /// (NSString-compatible) for safe indexing into a cumulative buffer.
    static func nextSentenceCharRange(in text: String, startCharOffset: Int) -> (start: Int, end: Int)? {
        let nsText = text as NSString
        guard startCharOffset < nsText.length else { return nil }
        let searchRange = NSRange(location: startCharOffset, length: nsText.length - startCharOffset)
        guard let regex = try? NSRegularExpression(pattern: #"[.!?](?:\s|$)"#) else {
            return nil
        }
        guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else {
            return nil
        }
        let endOffset = match.range.location + 1
        return (start: startCharOffset, end: endOffset)
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

    // MARK: - Conversation Persistence

    /// URL of the on-disk JSON file holding the conversation history.
    /// Lives in ~/Library/Application Support/<bundleID>/conversation-history.json
    private var conversationHistoryURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.stephenpierson.clickyplus"
        let directory = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("conversation-history.json")
    }

    /// Persist the current conversation history to disk. Called after each new
    /// exchange so continuity survives app restarts.
    private func saveConversationHistory() {
        guard let url = conversationHistoryURL else { return }
        do {
            let data = try JSONEncoder().encode(conversationHistory)
            try data.write(to: url, options: .atomic)
        } catch {
            print("⚠️ Failed to save conversation history: \(error)")
        }
    }

    /// Load any prior conversation history from disk. Called once on startup.
    /// Silent no-op if no file exists yet (first run).
    private func loadConversationHistory() {
        guard let url = conversationHistoryURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([ConversationEntry].self, from: data)
            conversationHistory = loaded
            print("🧠 Loaded \(loaded.count) prior exchanges from disk")
        } catch {
            print("⚠️ Failed to load conversation history: \(error)")
        }
    }
}
