//
//  HelperTask.swift
//  leanring-buddy
//
//  v15p4u (2026-05-23): Phase 2 of the helper sub-agent — async,
//  fire-and-forget tasks with their own UI surface. Steph can keep
//  talking to Marin while the helper runs.
//
//  HelperTask is the single source of truth for one helper invocation:
//  its lifecycle (queued → running → completed | failed | abandoned),
//  its category (drives icon + color), input, result, timestamps.
//
//  Tasks live in HelperTaskStore (separate file) which persists to JSON
//  at ~/Desktop/Claude Cowork/Clicky+ State/helper-tasks.json — that
//  location is Cowork-accessible by default so any Cowork session can
//  read helper history for debugging or context.

import Foundation
import SwiftUI

/// Category drives icon + color. Marin tags each delegation; falls
/// back to .generic if she omits.
enum HelperTaskCategory: String, Codable, CaseIterable {
    case research
    case drafting
    case code
    case crossTool = "cross-tool"
    case generic

    /// Tabler icon name (used as `ti ti-{value}` in HTML / direct asset name in SwiftUI).
    var iconName: String {
        switch self {
        case .research: return "magnifyingglass"
        case .drafting: return "pencil"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .crossTool: return "link"
        case .generic: return "lightbulb"
        }
    }

    /// Base HSB anchor for the category. Hue is what gives the color
    /// its identity; saturation + brightness tune it for dark-mode chrome.
    var baseHSB: (hue: Double, saturation: Double, brightness: Double) {
        switch self {
        case .research:  return (hue: 0.09, saturation: 0.85, brightness: 0.75)  // amber
        case .drafting:  return (hue: 0.69, saturation: 0.55, brightness: 0.70)  // purple
        case .code:      return (hue: 0.46, saturation: 0.85, brightness: 0.50)  // teal
        case .crossTool: return (hue: 0.94, saturation: 0.65, brightness: 0.60)  // pink
        case .generic:   return (hue: 0.58, saturation: 0.80, brightness: 0.65)  // blue
        }
    }

    /// SwiftUI Color for the category at its base hue (no per-task shift).
    func baseColor() -> Color {
        let h = baseHSB
        return Color(hue: h.hue, saturation: h.saturation, brightness: h.brightness)
    }

    /// Per-task color — pulls from the same soft pastel rainbow palette
    /// used for the chrome (border + halo). Each task gets a stable
    /// pick based on its id hash. v15p4ak (2026-05-24): replaces v15p4aa's
    /// full-spectrum HSB random which produced darker / off-palette
    /// emblems that didn't match the rainbow chrome. Emblems and chrome
    /// now share the same color family.
    func color(for taskId: String) -> Color {
        var h: UInt64 = 14695981039346656037
        for byte in taskId.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        let palette = HelperTaskCategory.rainbowPalette
        let index = Int(h % UInt64(palette.count))
        return palette[index]
    }

    /// Rainbow palette — mirrors HelperColumnStyle.rainbowColors (kept
    /// here as a copy so HelperTask doesn't have to import the UI
    /// module). v15p4bb (2026-05-25): de-washed. Previous palette
    /// (v15p4ap) targeted "darkened pastel" but read as muddy against
    /// the dark chrome. New palette is fully saturated and bright —
    /// reads as actual rainbow on a black background. If you tune
    /// the chrome rainbow, mirror the change here.
    static let rainbowPalette: [Color] = [
        Color(red: 1.00, green: 0.42, blue: 0.32),  // vivid coral
        Color(red: 1.00, green: 0.72, blue: 0.18),  // golden amber
        Color(red: 0.35, green: 0.88, blue: 0.45),  // bright mint
        Color(red: 0.20, green: 0.78, blue: 0.98),  // electric sky
        Color(red: 0.45, green: 0.55, blue: 1.00),  // bright periwinkle
        Color(red: 0.78, green: 0.42, blue: 1.00),  // vivid lavender
        Color(red: 1.00, green: 0.42, blue: 0.72),  // hot rose
    ]

    /// v15p4bb (2026-05-25): collision-avoidant color assignment for
    /// the floating icon column. Given an ORDERED list of tasks (e.g.
    /// HelperTaskStore.floatingSlots), returns a map taskId → Color
    /// such that no two tasks share a color (until we exceed palette
    /// size, which is currently 7; floatingSlots is capped at 5 so
    /// collisions are impossible in normal use). Each task keeps its
    /// hash-preferred color if available; later tasks shift to the
    /// next unused palette slot.
    static func collisionAvoidantColors(for tasks: [HelperTask]) -> [String: Color] {
        let palette = rainbowPalette
        var used: Set<Int> = []
        var result: [String: Color] = [:]
        for task in tasks {
            // Compute the task's hash-preferred index.
            var h: UInt64 = 14695981039346656037
            for byte in task.id.utf8 {
                h ^= UInt64(byte)
                h &*= 1099511628211
            }
            var idx = Int(h % UInt64(palette.count))
            // If preferred is taken, walk forward until we find an
            // unused slot. Wraps around. If everything is taken
            // (more tasks than palette), fall back to the preferred
            // index even though it duplicates.
            if used.contains(idx) {
                var probe = idx
                for _ in 0..<palette.count {
                    probe = (probe + 1) % palette.count
                    if !used.contains(probe) { idx = probe; break }
                }
            }
            used.insert(idx)
            result[task.id] = palette[idx]
        }
        return result
    }
}

/// Lifecycle states for a task.
enum HelperTaskStatus: String, Codable {
    case queued        // submitted, not yet started
    case running       // executing
    case completed     // success — `result` is set
    case failed        // error — `errorMessage` is set
    case abandoned     // was running when app quit; can't be resumed
}

/// One helper invocation.
struct HelperTask: Codable, Identifiable, Equatable {
    let id: String
    let task: String
    let context: String?
    let category: HelperTaskCategory
    var status: HelperTaskStatus
    var result: String?
    var errorMessage: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    /// Whether the user has viewed this task's result. Drives unread badge.
    var isRead: Bool
    /// JSON-encoded `[[String: Any]]` of the agent's full conversation
    /// history with Anthropic. Persists after each successful turn so
    /// follow-ups can resume the SAME agent loop (true threading) rather
    /// than spawning a fresh task with prior result as context. Stored
    /// as raw Data because the message-block structure includes tool_use
    /// + tool_result + text content blocks that don't map cleanly to a
    /// Codable struct without flattening. v15p4x (2026-05-23).
    var messagesJSON: Data?
    /// Number of follow-up turns this task has accumulated. 0 = original.
    var turnCount: Int
    /// v15p4ai (2026-05-24): when true, hidden from the floating sidebar
    /// column but still present in HelperTaskStore.tasks (so the notch
    /// history still shows it). Set by the Dismiss button on the card.
    /// History is sacred — we never actually delete tasks from the store.
    var dismissedFromColumn: Bool
    /// Short 3-5 word summary of the task, provided by Marin when she
    /// delegates. Shows as the card title by default; user can expand
    /// to see the full task text. v15p4as (2026-05-24).
    var summary: String?

    init(
        task: String,
        context: String? = nil,
        category: HelperTaskCategory = .generic
    ) {
        self.id = UUID().uuidString
        self.task = task
        self.context = context
        self.category = category
        self.status = .queued
        self.result = nil
        self.errorMessage = nil
        self.createdAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.inputTokens = 0
        self.outputTokens = 0
        self.costUSD = 0.0
        self.isRead = false
        self.messagesJSON = nil
        self.turnCount = 0
        self.dismissedFromColumn = false
        self.summary = nil
    }

    /// Decode the persisted messages array. Returns empty if missing or corrupt.
    func loadMessages() -> [[String: Any]] {
        guard let data = messagesJSON,
              let json = try? JSONSerialization.jsonObject(with: data),
              let arr = json as? [[String: Any]] else {
            return []
        }
        return arr
    }

    /// Encode a messages array for storage on the task.
    static func encodeMessages(_ messages: [[String: Any]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: messages, options: [])
    }

    /// Short preview for the floating-card / notch-row body.
    var preview: String {
        if let r = result, !r.isEmpty {
            let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
        }
        if let e = errorMessage {
            return "Error: \(e)"
        }
        switch status {
        case .queued: return "Queued…"
        case .running: return "Working on it…"
        case .abandoned: return "Was running when Clicky+ quit. Re-run if you still need it."
        default: return ""
        }
    }

    /// Short title for the icon-hover tooltip / row title — first ~60
    /// chars of the task with smart trimming.
    var shortTitle: String {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 60 { return t }
        return String(t.prefix(57)) + "…"
    }

    // MARK: - Backward-compatible Codable
    //
    // v15p4z (2026-05-24): hand-written init(from:) so adding new fields
    // to HelperTask doesn't nuke historical persistence. Every new field
    // MUST use `decodeIfPresent` with a sensible default. Auto-synthesized
    // Decodable treats every property as required, which silently
    // dropped Steph's 5/23 task history when turnCount + messagesJSON
    // shipped in v15p4x.

    enum CodingKeys: String, CodingKey {
        case id, task, context, category, status, result, errorMessage,
             createdAt, startedAt, completedAt, inputTokens, outputTokens,
             costUSD, isRead, messagesJSON, turnCount, dismissedFromColumn,
             summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.task = try c.decode(String.self, forKey: .task)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.category = (try? c.decode(HelperTaskCategory.self, forKey: .category)) ?? .generic
        self.status = (try? c.decode(HelperTaskStatus.self, forKey: .status)) ?? .completed
        self.result = try c.decodeIfPresent(String.self, forKey: .result)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        self.outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        self.costUSD = (try? c.decode(Double.self, forKey: .costUSD)) ?? 0.0
        self.isRead = (try? c.decode(Bool.self, forKey: .isRead)) ?? true
        self.messagesJSON = try c.decodeIfPresent(Data.self, forKey: .messagesJSON)
        self.turnCount = (try? c.decode(Int.self, forKey: .turnCount)) ?? 0
        self.dismissedFromColumn = (try? c.decode(Bool.self, forKey: .dismissedFromColumn)) ?? false
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}
