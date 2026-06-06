//
//  MarinMemoryStore.swift
//  Clicky+
//
//  v16qc (2026-06-06): Marin Memory Repository.
//
//  Voice-addressable memory for Marin: "remember this for me" /
//  "what did I call X". Architecture:
//
//  SOURCE OF TRUTH — `Claude Memory/Marin Memory.md` in the Obsidian
//  vault. Human-readable, Steph-editable, categorized sections, one
//  line per memory: `- [2026-06-06] Q4 deck = "Phoenix" — Drive/Decks`.
//  The note is ALWAYS authoritative; everything else is derived.
//
//  DERIVED INDEX — VecturaKit (on-device vector DB, hybrid BM25 +
//  vector search) at ~/Library/Application Support/Clicky/marin-memory.
//  Embeddings via Apple NaturalLanguage (NLContextualEmbedder — in-
//  process, zero deps, no second server, no RAM contention with the
//  qwen3.5-4b repunctuate server). Synced from the note by per-chunk
//  content hash at every launch + incrementally on writes, so Steph's
//  hand edits are picked up and the index is fully disposable (delete
//  the dir to force a rebuild). ALSO indexes the rest of the
//  `Claude Memory/*.md` files chunked by heading, so recall is
//  semantic over everything ("what did I say about returns?"), not
//  just voice-captured lines — capability-gap #3.
//
//  WRITE PATH — the spoken ramble is distilled to one fact line +
//  category by the LOCAL qwen3.5-4b server (tiny prompt <1K chars —
//  cache-safe per the v16qa single-slot rule; tiny prompts do NOT
//  evict the big repunctuate prompt). Prompt source of truth is the
//  Worker (`/memory-extract` with promptOnly:true, same pattern as
//  /repunctuate); Worker/Haiku executes as fallback; if both fail the
//  raw utterance is stored verbatim — capture is never blocked.
//
//  CONFIRMATION — SILENT + VISUAL ("✓ Saved" notch badge via
//  NotificationCenter → CompanionManager). Code-played chimes are
//  banned during realtime sessions (v15p4dk: any code audio collides
//  with Gemini Live and hangs the notch voiceState) and Steph vetoed
//  spoken acks 2026-06-06 ("tone is all messed up").
//

import CryptoKit
import Foundation
import NaturalLanguage
import VecturaKit
import VecturaNLKit

actor MarinMemoryStore {

    static let shared = MarinMemoryStore()

    /// Posted after a successful remember. userInfo: ["updated": Bool].
    /// CompanionManager observes this and flashes the notch badge.
    static let memorySavedNotification = Notification.Name("clicky.marinMemorySaved")

    // MARK: - Paths

    private let vaultDir = ("~/Desktop/Claude Cowork/Obsidian/Steph Vault" as NSString).expandingTildeInPath
    private var memoryDir: String { vaultDir + "/Claude Memory" }
    private var notePath: String { memoryDir + "/Marin Memory.md" }
    private let dbDir = ("~/Library/Application Support/Clicky/marin-memory" as NSString).expandingTildeInPath
    private var sidecarPath: String { dbDir + "/sync-meta.json" }

    // MARK: - Categories

    static let categories: [(key: String, heading: String)] = [
        ("files", "Files & Locations"),
        ("todos", "To-Dos"),
        ("personal", "Personal"),
        ("references", "References"),
    ]

    // MARK: - State

    private var vectorDB: VecturaKit?
    /// uuid → meta for every indexed chunk. Mirrors the Vectura DB so we
    /// can hash-diff against the note + vault files on every sync. Saved
    /// as JSON next to the DB; both are disposable together.
    private var sidecar: [String: ChunkMeta] = [:]
    private var extractPrompt: String?
    private var workerBaseURL = "https://clicky-proxy.sapierso.workers.dev"
    private var syncedOnce = false

    struct ChunkMeta: Codable {
        let hash: String
        let kind: String      // "marin" | "vault"
        let line: String?     // raw note line (marin only)
        let category: String? // category key (marin only)
    }

    // MARK: - Launch

    /// Call once at app launch (CompanionManager). Builds/syncs the
    /// index and prefetches the extract prompt in the background.
    /// Never blocks; failures degrade to error results at tool time.
    nonisolated func launchSync(workerBaseURL: String) {
        Task.detached(priority: .utility) {
            await self.performLaunchSync(workerBaseURL: workerBaseURL)
        }
    }

    private func performLaunchSync(workerBaseURL: String) async {
        self.workerBaseURL = workerBaseURL
        await fetchExtractPromptIfNeeded()
        do {
            try await syncIndex()
        } catch {
            print("🧠 MarinMemory: launch sync failed (\(error)) — recall degraded until next launch")
        }
    }

    // MARK: - DB bootstrap

    private func database() async throws -> VecturaKit {
        if let vectorDB { return vectorDB }
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let config = try VecturaConfig(
            name: "marin-memory",
            directoryURL: URL(fileURLWithPath: dbDir)
        )
        let embedder = try await NLContextualEmbedder(language: .english)
        let db = try await VecturaKit(config: config, embedder: embedder)
        vectorDB = db
        return db
    }

    // MARK: - Hash sync (note + vault → index)

    /// Reconciles the Vectura index against the note and the Claude
    /// Memory files by content hash. Adds new/changed chunks, deletes
    /// vanished ones. Hand edits to any file are picked up here.
    private func syncIndex() async throws {
        let db = try await database()
        loadSidecar()
        ensureNoteExists()

        // Desired chunk set: hash → (text, meta).
        var desired: [String: (text: String, meta: ChunkMeta)] = [:]
        for entry in parseNoteLines() {
            let text = "[Marin Memory — \(entry.heading)] \(entry.line)"
            let h = Self.chunkHash(kind: "marin", text: text)
            desired[h] = (text, ChunkMeta(hash: h, kind: "marin", line: entry.line, category: entry.categoryKey))
        }
        for chunk in vaultChunks() {
            let h = Self.chunkHash(kind: "vault", text: chunk)
            desired[h] = (chunk, ChunkMeta(hash: h, kind: "vault", line: nil, category: nil))
        }

        // Deletes — indexed chunks whose hash no longer exists.
        var deleteIDs: [UUID] = []
        for (uuidString, meta) in sidecar where desired[meta.hash] == nil {
            if let id = UUID(uuidString: uuidString) { deleteIDs.append(id) }
            sidecar.removeValue(forKey: uuidString)
        }
        if !deleteIDs.isEmpty {
            try await db.deleteDocuments(ids: deleteIDs)
        }

        // Adds — desired chunks not yet indexed.
        let indexedHashes = Set(sidecar.values.map(\.hash))
        var addTexts: [String] = []
        var addIDs: [UUID] = []
        var addMetas: [ChunkMeta] = []
        for (h, item) in desired where !indexedHashes.contains(h) {
            addTexts.append(item.text)
            addIDs.append(UUID())
            addMetas.append(item.meta)
        }
        if !addTexts.isEmpty {
            let ids = try await db.addDocuments(texts: addTexts, ids: addIDs)
            for (i, id) in ids.enumerated() where i < addMetas.count {
                sidecar[id.uuidString] = addMetas[i]
            }
        }
        saveSidecar()
        syncedOnce = true
        print("🧠 MarinMemory: index synced (\(sidecar.count) chunks; +\(addTexts.count) −\(deleteIDs.count))")
    }

    // MARK: - Operations (dispatched from the Marin `memory` tool)

    func remember(utterance: String, categoryOverride: String?) async -> [String: Any] {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["status": "error", "reason": "Nothing to remember — empty content"]
        }

        // 1. Distill: local qwen → Worker/Haiku → verbatim. Never blocks capture.
        var memoryLine = trimmed
        var category = categoryOverride ?? "references"
        var engine = "verbatim"
        if let extracted = await extractMemory(utterance: trimmed) {
            memoryLine = extracted.memory
            if categoryOverride == nil { category = extracted.category }
            engine = extracted.engine
        }
        if !Self.categories.contains(where: { $0.key == category }) {
            category = "references"
        }

        // 2. Dedupe — a near-identical existing voice memory gets
        // replaced instead of duplicated.
        var replacedLine: String?
        if syncedOnce, let db = try? await database(),
           let results = try? await db.search(query: .text(memoryLine), numResults: 3, threshold: 0) {
            for r in results {
                guard let meta = sidecar[r.id.uuidString], meta.kind == "marin",
                      let line = meta.line, r.score >= 0.92 else { continue }
                replacedLine = line
                break
            }
        }

        // 3. Write the note (source of truth) FIRST.
        let newLine = "[\(Self.dateStamp())] \(memoryLine)"
        do {
            ensureNoteExists()
            if let replacedLine { try removeLineFromNote(replacedLine) }
            try appendLineToNote(newLine, categoryKey: category)
        } catch {
            return ["status": "error", "reason": "Could not write Marin Memory note: \(error.localizedDescription)"]
        }

        // 4. Update the index incrementally. Best effort — the launch
        // hash-sync self-heals any miss here.
        await applyWriteToIndex(newLine: newLine, category: category, removedLine: replacedLine)

        NotificationCenter.default.post(
            name: Self.memorySavedNotification, object: nil,
            userInfo: ["updated": replacedLine != nil]
        )
        return [
            "status": "ok",
            "stored": newLine,
            "category": category,
            "action": replacedLine != nil ? "updated_existing" : "added",
            "engine": engine,
        ]
    }

    func recall(query: String) async -> [String: Any] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ["status": "error", "reason": "Empty query"]
        }
        guard let db = try? await database() else {
            return ["status": "error", "reason": "Memory index unavailable — read 'Claude Memory/Marin Memory.md' via read_obsidian_note instead"]
        }
        if !syncedOnce { try? await syncIndex() }
        guard let results = try? await db.search(query: .text(q), numResults: 6, threshold: 0) else {
            return ["status": "error", "reason": "Search failed"]
        }
        let matches: [[String: Any]] = results.prefix(5).map { r in
            let meta = sidecar[r.id.uuidString]
            return [
                "text": r.text,
                "score": Double(r.score),
                "source": meta?.kind == "marin" ? "voice memory" : "Claude Memory note",
            ]
        }
        return ["matches": matches, "count": matches.count]
    }

    func forget(query: String) async -> [String: Any] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ["status": "error", "reason": "Empty query"]
        }
        guard let db = try? await database() else {
            return ["status": "error", "reason": "Memory index unavailable"]
        }
        if !syncedOnce { try? await syncIndex() }
        guard let results = try? await db.search(query: .text(q), numResults: 8, threshold: 0),
              let target = results.first(where: { sidecar[$0.id.uuidString]?.kind == "marin" }),
              let meta = sidecar[target.id.uuidString], let line = meta.line else {
            return ["status": "not_found", "reason": "No stored voice memory matched. Only voice-stored memories can be forgotten — Claude Memory notes are read-only here."]
        }
        do {
            try removeLineFromNote(line)
        } catch {
            return ["status": "error", "reason": "Could not edit note: \(error.localizedDescription)"]
        }
        try? await db.deleteDocuments(ids: [target.id])
        sidecar.removeValue(forKey: target.id.uuidString)
        saveSidecar()
        return ["status": "ok", "forgot": line]
    }

    func list(categoryKey: String?) -> [String: Any] {
        ensureNoteExists()
        guard let content = try? String(contentsOfFile: notePath, encoding: .utf8) else {
            return ["status": "error", "reason": "Could not read Marin Memory note"]
        }
        guard let categoryKey, !categoryKey.isEmpty else {
            return ["status": "ok", "content": content]
        }
        guard let heading = Self.categories.first(where: { $0.key == categoryKey })?.heading else {
            return ["status": "error", "reason": "Unknown category '\(categoryKey)'. Valid: files, todos, personal, references."]
        }
        let lines = parseNoteLines().filter { $0.categoryKey == categoryKey }
        return [
            "status": "ok",
            "category": heading,
            "memories": lines.map(\.line),
            "count": lines.count,
        ]
    }

    // MARK: - Extraction (local-first, worker fallback)

    private func extractMemory(utterance: String) async -> (memory: String, category: String, engine: String)? {
        await fetchExtractPromptIfNeeded()
        // Local path — TINY prompt, cache-safe (v16qa single-slot rule:
        // tiny prompts don't evict the big repunctuate prompt).
        if let prompt = extractPrompt, LocalLLMManager.shared.isAvailable {
            if let raw = try? await LocalLLMManager.shared.runSmallTask(
                systemPrompt: prompt, userText: utterance, maxTokens: 200, timeout: 6
            ), let parsed = Self.parseExtractJSON(raw) {
                return (parsed.memory, parsed.category, "local")
            }
        }
        // Worker/Haiku fallback.
        if let result = await workerExtract(utterance: utterance) {
            return (result.memory, result.category, "worker")
        }
        return nil
    }

    /// Fetch the extract prompt from the Worker (single source of
    /// truth, promptOnly pattern — same as repunctuate/polish).
    private func fetchExtractPromptIfNeeded() async {
        guard extractPrompt == nil else { return }
        guard let url = URL(string: "\(workerBaseURL)/memory-extract") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["promptOnly": true])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = parsed["prompt"] as? String, !prompt.isEmpty else {
            print("🧠 MarinMemory: extract-prompt fetch failed — worker fallback only")
            return
        }
        extractPrompt = prompt
        print("🧠 MarinMemory: extract prompt loaded (\(prompt.count) chars)")
    }

    private func workerExtract(utterance: String) async -> (memory: String, category: String)? {
        guard let url = URL(string: "\(workerBaseURL)/memory-extract") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["utterance": utterance])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memory = parsed["memory"] as? String, !memory.isEmpty else {
            return nil
        }
        let category = (parsed["category"] as? String) ?? "references"
        return (memory, category)
    }

    /// Parse the model's JSON output. Mirrors parseMemoryExtractJSON in
    /// the Worker — tolerate code fences / stray prose around the object.
    private static func parseExtractJSON(_ raw: String) -> (memory: String, category: String)? {
        guard let range = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
              let data = String(raw[range]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let validCategories = Set(categories.map(\.key))
        let category = (obj["category"] as? String).flatMap { validCategories.contains($0) ? $0 : nil } ?? "references"
        guard let memory = (obj["memory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !memory.isEmpty else {
            return nil
        }
        return (memory, category)
    }

    // MARK: - Note file (source of truth)

    private func ensureNoteExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: notePath) else { return }
        try? fm.createDirectory(atPath: memoryDir, withIntermediateDirectories: true)
        let template = ([
            "# Marin Memory",
            "",
            "Voice-captured memories, managed by Clicky+ (Marin's `memory` tool).",
            "Safe to edit by hand — the search index re-syncs from this note on",
            "every app launch. One memory per `- ` line.",
            "",
        ] + Self.categories.flatMap { ["## \($0.heading)", ""] })
            .joined(separator: "\n")
        try? template.write(toFile: notePath, atomically: true, encoding: .utf8)
        print("🧠 MarinMemory: created \(notePath)")
    }

    private struct NoteLine {
        let line: String
        let heading: String
        let categoryKey: String
    }

    private func parseNoteLines() -> [NoteLine] {
        guard let content = try? String(contentsOfFile: notePath, encoding: .utf8) else { return [] }
        var results: [NoteLine] = []
        var currentHeading = ""
        var currentKey = ""
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.hasPrefix("## ") {
                currentHeading = String(rawLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentKey = Self.categories.first(where: { $0.heading == currentHeading })?.key ?? "references"
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), !currentHeading.isEmpty else { continue }
            let line = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard line.count >= 3 else { continue }
            results.append(NoteLine(line: line, heading: currentHeading, categoryKey: currentKey))
        }
        return results
    }

    /// Append a memory line at the END of its category section (just
    /// before the next `## ` heading, or EOF).
    private func appendLineToNote(_ line: String, categoryKey: String) throws {
        let heading = Self.categories.first(where: { $0.key == categoryKey })?.heading ?? "References"
        var content = (try? String(contentsOfFile: notePath, encoding: .utf8)) ?? ""
        if !content.contains("## \(heading)") {
            content += "\n## \(heading)\n"
        }
        var lines = content.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(of: "## \(heading)") else {
            throw NSError(domain: "MarinMemoryError", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Section '\(heading)' not found"])
        }
        // Insert before the next heading; trim trailing blank lines of
        // the section so entries stay contiguous.
        var insertIdx = lines.count
        for i in (headingIdx + 1)..<lines.count where lines[i].hasPrefix("## ") {
            insertIdx = i
            break
        }
        while insertIdx > headingIdx + 1, lines[insertIdx - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertIdx -= 1
        }
        lines.insert("- \(line)", at: insertIdx)
        try lines.joined(separator: "\n").write(toFile: notePath, atomically: true, encoding: .utf8)
    }

    private func removeLineFromNote(_ line: String) throws {
        let content = try String(contentsOfFile: notePath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "- \(line)"
        }) else { return }
        lines.remove(at: idx)
        try lines.joined(separator: "\n").write(toFile: notePath, atomically: true, encoding: .utf8)
    }

    // MARK: - Incremental index write

    private func applyWriteToIndex(newLine: String, category: String, removedLine: String?) async {
        guard let db = try? await database() else { return }
        if let removedLine {
            let staleIDs = sidecar.filter { $0.value.kind == "marin" && $0.value.line == removedLine }
                .compactMap { UUID(uuidString: $0.key) }
            if !staleIDs.isEmpty {
                try? await db.deleteDocuments(ids: staleIDs)
                for id in staleIDs { sidecar.removeValue(forKey: id.uuidString) }
            }
        }
        let heading = Self.categories.first(where: { $0.key == category })?.heading ?? "References"
        let text = "[Marin Memory — \(heading)] \(newLine)"
        let h = Self.chunkHash(kind: "marin", text: text)
        let id = UUID()
        if (try? await db.addDocument(text: text, id: id)) != nil {
            sidecar[id.uuidString] = ChunkMeta(hash: h, kind: "marin", line: newLine, category: category)
        }
        saveSidecar()
    }

    // MARK: - Vault chunks (Claude Memory/*.md, minus the Marin note)

    /// Heading-level chunks of every other Claude Memory note so recall
    /// is semantic over Steph's whole memory, not just voice captures.
    /// Each chunk self-describes its source in the text so Marin can
    /// cite where a hit came from. Capped to keep embeddings cheap.
    private func vaultChunks() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: memoryDir) else { return [] }
        var chunks: [String] = []
        for entry in entries.sorted()
        where entry.hasSuffix(".md") && !entry.hasPrefix(".") && entry != "Marin Memory.md" {
            let path = (memoryDir as NSString).appendingPathComponent(entry)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let name = (entry as NSString).deletingPathExtension
            // Split on H2 headings; the preamble before the first
            // heading is its own chunk.
            let sections = content.components(separatedBy: "\n## ")
            for (i, section) in sections.enumerated() {
                var heading = ""
                var body = section
                if i > 0 {
                    let parts = section.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    heading = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
                    body = parts.count > 1 ? String(parts[1]) : ""
                }
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedBody.count >= 40 else { continue }
                let label = heading.isEmpty ? "[\(name)]" : "[\(name) — \(heading)]"
                chunks.append("\(label)\n\(String(trimmedBody.prefix(1500)))")
            }
        }
        return chunks
    }

    // MARK: - Sidecar persistence

    private func loadSidecar() {
        guard sidecar.isEmpty,
              let data = FileManager.default.contents(atPath: sidecarPath),
              let decoded = try? JSONDecoder().decode([String: ChunkMeta].self, from: data) else { return }
        sidecar = decoded
    }

    private func saveSidecar() {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: URL(fileURLWithPath: sidecarPath))
    }

    // MARK: - Small helpers

    private static func chunkHash(kind: String, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(kind)\u{1F}\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
