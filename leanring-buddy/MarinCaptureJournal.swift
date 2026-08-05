//  MarinCaptureJournal.swift
//  Clicky+
//
//  v16r17 (2026-08-04): "undo that last thing" — cross-store capture journal.
//
//  WHY THIS EXISTS. Marin has two independent capture destinations:
//  the Marin Memory note (MarinMemoryStore, vector-indexed) and the
//  Obsidian Idea Inbox (MarinHelperSubAgent.appendToIdeaInbox, a plain
//  append with no index at all). `memory operation=forget` searches
//  ONLY the vector index, so an inbox capture is invisible to it.
//
//  Live failure 2026-08-04: Steph hit the realtime key by mistake
//  instead of the VTT key. Marin routed the utterance to
//  append_to_inbox and said "Captured." He said "undo that last
//  thing" -> forget searched the vector index, found nothing, and
//  replied "I didn't find a matching memory." Then "where did you
//  capture it to?" -> "I didn't capture anything." The note was
//  sitting in Idea Inbox.md the whole time. Semantic search is the
//  wrong tool for "the last thing" — recency is not similarity.
//
//  THE FIX. Every capture, whichever store it lands in, appends one
//  record here. `last_capture` reads the head; `undo_last` pops it and
//  deletes the line from whichever file it actually went to. No
//  embedding, no query, no guessing — Steph never has to describe what
//  he just said in order to take it back.
//
//  The journal is DERIVED and disposable: the note and the inbox stay
//  the source of truth. Losing this file costs undo, never data.
//

import Foundation

enum MarinCaptureJournal {

    /// Where a capture landed. Determines which file `undo_last` edits.
    enum Kind: String, Codable {
        case memory  // Claude Memory/Marin Memory.md (vector-indexed)
        case inbox   // Inbox/Idea Inbox.md (plain append)
    }

    struct Entry: Codable {
        let id: String
        let kind: Kind
        /// The exact text written to the file, minus the bullet prefix —
        /// this is what the deleters match on, so it must be verbatim.
        let line: String
        let path: String
        let category: String?
        /// If this capture REPLACED an existing memory (remember()'s
        /// dedupe/update path), the line it overwrote — so undo restores
        /// it instead of silently destroying a real memory that the
        /// accidental capture happened to land on top of.
        let replaced: String?
        let at: Date
    }

    /// Enough to cover a rambling session; small enough to rewrite whole.
    private static let maxEntries = 20

    private static let lock = NSLock()

    private static var journalPath: String {
        let dir = ("~/Library/Application Support/Clicky/marin-memory" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("capture-journal.json")
    }

    // MARK: - Write

    /// Append a capture. Called from the write path of every capture
    /// tool, AFTER the file write succeeds — a failed capture must not
    /// leave an undo record pointing at a line that was never written.
    static func record(kind: Kind, line: String, path: String, category: String? = nil, replaced: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.append(
            Entry(
                id: UUID().uuidString,
                kind: kind,
                line: line,
                path: path,
                category: category,
                replaced: replaced,
                at: Date()
            )
        )
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        saveLocked(entries)
    }

    // MARK: - Read

    /// Most recent capture, or nil if nothing has been captured since
    /// the journal was created.
    static func last() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().last
    }

    /// Drop a specific entry (after `undo_last` deleted the line).
    static func drop(id: String) {
        lock.lock()
        defer { lock.unlock() }
        saveLocked(loadLocked().filter { $0.id != id })
    }

    // MARK: - Disk

    private static func loadLocked() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: journalPath),
              let entries = try? Self.decoder.decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func saveLocked(_ entries: [Entry]) {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: journalPath), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
