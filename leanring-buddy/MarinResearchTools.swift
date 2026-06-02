//
//  MarinResearchTools.swift
//  leanring-buddy / Clicky+
//
//  Created 2026-05-02 (v15p2). File-system research tools that Marin
//  (Realtime mode) can call to answer questions about Steph's setup —
//  scheduled tasks, skills, plugins, Obsidian notes, the clicky-plus
//  codebase, the Clicky roadmap.
//
//  All methods are pure Swift — no network, no Cowork session needed.
//  Marin reads the same source files Cowork's Claude reads.
//
//  Returns are dictionaries shaped for JSON encoding back to the
//  Realtime API. Errors return {"status":"error","reason":"..."} so
//  Marin can verbalize the failure naturally.
//

import AppKit
import Foundation

@MainActor
enum MarinResearchTools {

    // MARK: - Hardcoded paths
    //
    // These point at Steph's specific directory layout. If anything
    // moves we update here. Could parameterize via UserDefaults later
    // but a rare cost vs. the simplicity of static paths.

    private static var scheduledTasksDir: String {
        NSString("~/Documents/Claude/Scheduled").expandingTildeInPath
    }

    private static var obsidianVaultDir: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault").expandingTildeInPath
    }

    private static var clickyRepoDir: String {
        NSString("~/clicky-plus").expandingTildeInPath
    }

    private static var clickyRoadmapPath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Projects/Clicky Plus - Roadmap.md").expandingTildeInPath
    }

    private static var claudeSessionsDir: String {
        NSString("~/Library/Application Support/Claude/local-agent-mode-sessions").expandingTildeInPath
    }

    /// v15p2 (2026-05-03): Bridge file for the Cowork Claude ↔ Marin
    /// shared-channel pattern. Cowork writes via Obsidian MCP; Marin
    /// writes via `append_to_bridge` (below). Both read on demand.
    private static var bridgeFilePath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Bridges/Claude-Marin Channel.md").expandingTildeInPath
    }

    private static var bridgeDir: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Bridges").expandingTildeInPath
    }

    // MARK: - 1. list_scheduled_tasks

    static func listScheduledTasks() -> [String: Any] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: scheduledTasksDir) else {
            return ["status": "error", "reason": "Scheduled tasks directory not found"]
        }
        var tasks: [[String: Any]] = []
        for entry in entries.sorted() {
            // Skip dotfiles
            if entry.hasPrefix(".") { continue }
            let entryPath = (scheduledTasksDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let description = readTaskDescription(taskDir: entryPath, taskName: entry)
            tasks.append([
                "name": entry,
                "description": description,
            ])
        }
        return ["tasks": tasks, "count": tasks.count]
    }

    private static func readTaskDescription(taskDir: String, taskName: String) -> String {
        let fm = FileManager.default
        // v15p2 hotfix (2026-05-02): scheduled tasks store metadata
        // in SKILL.md (YAML front matter). Parse description out of
        // the front matter properly — handles multi-line block
        // scalars (`description: >`) which the previous version
        // captured as literal ">".
        let candidates = ["SKILL.md", "README.md", "task.md", "\(taskName).md", "prompt.md", "description.md"]
        for candidate in candidates {
            let path = (taskDir as NSString).appendingPathComponent(candidate)
            if fm.fileExists(atPath: path),
               let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                if let yamlDesc = parseYAMLDescription(from: contents), !yamlDesc.isEmpty {
                    return String(yamlDesc.prefix(400))
                }
                // Fallback: first non-empty lines.
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
                let preview = lines.prefix(5).joined(separator: " ")
                let cleaned = String(preview)
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                return String(cleaned.prefix(300))
            }
        }
        return "(no description file in task directory)"
    }

    /// Parse the `description:` value from YAML front matter, handling
    /// multi-line block scalars (`description: >`) by gathering all
    /// indented continuation lines until the front matter closes or
    /// a non-indented key starts.
    /// v15p2 hotfix (2026-05-02).
    private static func parseYAMLDescription(from contents: String) -> String? {
        guard contents.hasPrefix("---") else { return nil }
        let allLines = contents.components(separatedBy: "\n")
        var inFrontMatter = false
        var i = 0
        while i < allLines.count {
            let line = allLines[i]
            if i == 0 && line == "---" {
                inFrontMatter = true
                i += 1
                continue
            }
            if inFrontMatter && line == "---" {
                return nil
            }
            if !inFrontMatter {
                i += 1
                continue
            }
            if line.hasPrefix("description:") {
                let value = line.replacingOccurrences(of: "description:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Inline value, e.g. `description: short text`
                if value != ">" && value != "|" && !value.isEmpty {
                    return value
                }
                // Multi-line block scalar — gather indented lines until
                // we hit an unindented line OR the front-matter close.
                var collected: [String] = []
                var j = i + 1
                while j < allLines.count {
                    let next = allLines[j]
                    if next == "---" { break }
                    // Indented continuation = part of the description.
                    if next.hasPrefix(" ") || next.hasPrefix("\t") {
                        let stripped = next.trimmingCharacters(in: .whitespaces)
                        if !stripped.isEmpty {
                            collected.append(stripped)
                        }
                        j += 1
                    } else if next.isEmpty {
                        // Blank line within block scalar — preserve as space.
                        j += 1
                    } else {
                        // Non-indented, non-empty line = next YAML key.
                        break
                    }
                }
                let joined = collected.joined(separator: " ")
                return joined.isEmpty ? nil : joined
            }
            i += 1
        }
        return nil
    }

    // MARK: - 2. list_skills

    static func listSkills() -> [String: Any] {
        guard let pluginsBaseDir = mostRecentSessionRpmDir() else {
            return ["status": "error", "reason": "Could not locate plugin directory"]
        }
        let fm = FileManager.default
        var skills: [[String: Any]] = []
        guard let plugins = try? fm.contentsOfDirectory(atPath: pluginsBaseDir) else {
            return ["status": "error", "reason": "Could not enumerate plugins"]
        }
        for plugin in plugins where plugin.hasPrefix("plugin_") {
            let skillsDir = ((pluginsBaseDir as NSString).appendingPathComponent(plugin) as NSString).appendingPathComponent("skills")
            guard let skillDirs = try? fm.contentsOfDirectory(atPath: skillsDir) else { continue }
            for skillDir in skillDirs.sorted() where !skillDir.hasPrefix(".") {
                let skillMdPath = ((skillsDir as NSString).appendingPathComponent(skillDir) as NSString).appendingPathComponent("SKILL.md")
                guard let contents = try? String(contentsOfFile: skillMdPath, encoding: .utf8) else { continue }
                let (name, description) = parseSkillFrontMatter(contents: contents, fallbackName: skillDir)
                skills.append([
                    "name": name,
                    "description": description,
                    "plugin_id": plugin,
                ])
            }
        }
        return ["skills": skills, "count": skills.count]
    }

    /// Parse SKILL.md front matter for `name:` and `description:`.
    /// Uses parseYAMLDescription so multi-line block scalars
    /// (`description: >`) work correctly.
    private static func parseSkillFrontMatter(contents: String, fallbackName: String) -> (String, String) {
        var name: String? = nil

        // Find name from front matter.
        if contents.hasPrefix("---") {
            let lines = contents.components(separatedBy: "\n")
            var inFrontMatter = false
            for (idx, line) in lines.enumerated() {
                if idx == 0 && line == "---" { inFrontMatter = true; continue }
                if inFrontMatter && line == "---" { break }
                if !inFrontMatter { continue }
                if line.hasPrefix("name:") {
                    name = line.replacingOccurrences(of: "name:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        let resolvedName = (name?.isEmpty == false) ? name! : fallbackName
        let description = parseYAMLDescription(from: contents).map { String($0.prefix(400)) }
            ?? "(no description in front matter)"

        return (resolvedName, description)
    }

    // MARK: - 3. list_plugins

    static func listPlugins() -> [String: Any] {
        guard let pluginsBaseDir = mostRecentSessionRpmDir() else {
            return ["status": "error", "reason": "Could not locate plugin directory"]
        }
        let fm = FileManager.default
        guard let pluginDirs = try? fm.contentsOfDirectory(atPath: pluginsBaseDir) else {
            return ["status": "error", "reason": "Could not enumerate plugins"]
        }
        var plugins: [[String: Any]] = []
        for pluginDir in pluginDirs.sorted() where pluginDir.hasPrefix("plugin_") {
            let pluginPath = (pluginsBaseDir as NSString).appendingPathComponent(pluginDir)
            // Try plugin manifest first, then fall back to enumerating skills.
            let (name, description) = parsePluginManifest(pluginPath: pluginPath, fallbackId: pluginDir)
            plugins.append([
                "name": name,
                "description": description,
                "plugin_id": pluginDir,
            ])
        }
        return ["plugins": plugins, "count": plugins.count]
    }

    private static func parsePluginManifest(pluginPath: String, fallbackId: String) -> (String, String) {
        let fm = FileManager.default
        // Look for plugin.json or manifest.json with name/description.
        let candidates = ["plugin.json", "manifest.json", "package.json"]
        for candidate in candidates {
            let path = (pluginPath as NSString).appendingPathComponent(candidate)
            guard fm.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let name = (json["name"] as? String) ?? fallbackId
            let description = (json["description"] as? String) ?? "(no description in manifest)"
            return (name, String(description.prefix(400)))
        }
        // Fallback: count skills under this plugin and report that.
        let skillsDir = (pluginPath as NSString).appendingPathComponent("skills")
        if let skillNames = try? fm.contentsOfDirectory(atPath: skillsDir) {
            let visible = skillNames.filter { !$0.hasPrefix(".") }
            let summary = "Plugin with \(visible.count) skill(s): \(visible.prefix(3).joined(separator: ", "))\(visible.count > 3 ? "..." : "")"
            return (fallbackId, summary)
        }
        return (fallbackId, "(no manifest, no skills directory)")
    }

    /// Find the plugin directory inside the most recently active Claude
    /// session. The session-state directory layout:
    ///   ~/Library/Application Support/Claude/local-agent-mode-sessions
    ///     /<owner-id>/<project-id>/rpm/plugin_*
    /// We pick the most-recently-modified `<owner>/<project>/rpm` dir.
    private static func mostRecentSessionRpmDir() -> String? {
        let fm = FileManager.default
        guard let owners = try? fm.contentsOfDirectory(atPath: claudeSessionsDir) else {
            return nil
        }
        var newestPath: String?
        var newestDate: Date = .distantPast
        for owner in owners where !owner.hasPrefix(".") {
            let ownerPath = (claudeSessionsDir as NSString).appendingPathComponent(owner)
            guard let projects = try? fm.contentsOfDirectory(atPath: ownerPath) else { continue }
            for project in projects where !project.hasPrefix(".") {
                let rpmPath = ((ownerPath as NSString).appendingPathComponent(project) as NSString).appendingPathComponent("rpm")
                guard fm.fileExists(atPath: rpmPath) else { continue }
                if let attrs = try? fm.attributesOfItem(atPath: rpmPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > newestDate {
                    newestDate = modDate
                    newestPath = rpmPath
                }
            }
        }
        return newestPath
    }

    // MARK: - 4. search_obsidian

    static func searchObsidian(query: String) -> [String: Any] {
        guard !query.isEmpty else {
            return ["status": "error", "reason": "Empty search query"]
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: obsidianVaultDir) else {
            return ["status": "error", "reason": "Obsidian vault not found at \(obsidianVaultDir)"]
        }
        let queryLower = query.lowercased()
        var matches: [[String: Any]] = []
        let maxResults = 15

        guard let enumerator = fm.enumerator(atPath: obsidianVaultDir) else {
            return ["status": "error", "reason": "Could not enumerate vault"]
        }
        while let relPath = enumerator.nextObject() as? String {
            guard relPath.hasSuffix(".md") else { continue }
            let fullPath = (obsidianVaultDir as NSString).appendingPathComponent(relPath)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            guard let range = lower.range(of: queryLower) else { continue }

            // Build a snippet around the first match.
            let lowerStart = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let snippetStart = max(0, lowerStart - 60)
            let snippetEnd = min(content.count, lowerStart + queryLower.count + 100)
            let startIdx = content.index(content.startIndex, offsetBy: snippetStart)
            let endIdx = content.index(content.startIndex, offsetBy: snippetEnd)
            let snippet = String(content[startIdx..<endIdx])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)

            let title = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
            matches.append([
                "title": title,
                "path": relPath,
                "snippet": snippet,
            ])
            if matches.count >= maxResults { break }
        }
        return [
            "matches": matches,
            "count": matches.count,
            "truncated": matches.count >= maxResults,
        ]
    }

    // MARK: - 5. read_obsidian_note

    static func readObsidianNote(path: String) -> [String: Any] {
        guard !path.isEmpty else {
            return ["status": "error", "reason": "Empty path"]
        }
        // Allow relative-to-vault paths or absolute paths within the vault.
        let fullPath: String
        if path.hasPrefix("/") {
            fullPath = path
        } else {
            // Strip leading slashes from relative paths.
            let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
            fullPath = (obsidianVaultDir as NSString).appendingPathComponent(cleaned)
        }
        // Sanity: ensure resolved path is inside the vault to prevent
        // accidental path-traversal reads outside Obsidian.
        let standardized = (fullPath as NSString).standardizingPath
        guard standardized.hasPrefix(obsidianVaultDir) else {
            return ["status": "error", "reason": "Path is outside Obsidian vault"]
        }
        guard let content = try? String(contentsOfFile: standardized, encoding: .utf8) else {
            return ["status": "error", "reason": "Could not read note: \(path)"]
        }
        // Truncate very long notes so they don't blow Marin's context.
        let maxChars = 8000
        let truncated = content.count > maxChars
        let displayContent = truncated
            ? String(content.prefix(maxChars)) + "\n\n[truncated — read full note in Obsidian]"
            : content
        return [
            "path": path,
            "content": displayContent,
            "char_count": content.count,
            "truncated": truncated,
        ]
    }

    // MARK: - 6. search_clicky_codebase

    static func searchClickyCodebase(query: String) -> [String: Any] {
        guard !query.isEmpty else {
            return ["status": "error", "reason": "Empty search query"]
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: clickyRepoDir) else {
            return ["status": "error", "reason": "Clicky repo not found at \(clickyRepoDir)"]
        }
        let queryLower = query.lowercased()
        var matches: [[String: Any]] = []
        let maxResults = 15

        // Only walk source-ish files. Skip binaries, build artifacts.
        let allowedExtensions: Set<String> = [
            "swift", "ts", "tsx", "js", "jsx", "md", "json", "yaml", "yml", "toml", "txt", "sh",
        ]
        let blockedDirComponents: Set<String> = [
            ".git", "build", "node_modules", "DerivedData", ".wrangler", "Pods", ".next",
        ]

        guard let enumerator = fm.enumerator(atPath: clickyRepoDir) else {
            return ["status": "error", "reason": "Could not enumerate repo"]
        }
        while let relPath = enumerator.nextObject() as? String {
            // Skip blocked dirs anywhere in the path.
            let pathComponents = relPath.split(separator: "/").map(String.init)
            if pathComponents.contains(where: { blockedDirComponents.contains($0) }) {
                continue
            }
            let ext = (relPath as NSString).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            let fullPath = (clickyRepoDir as NSString).appendingPathComponent(relPath)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (lineIdx, line) in lines.enumerated() {
                if line.lowercased().contains(queryLower) {
                    let snippet = String(line.prefix(180)).trimmingCharacters(in: .whitespaces)
                    matches.append([
                        "file": relPath,
                        "line": lineIdx + 1,
                        "snippet": snippet,
                    ])
                    if matches.count >= maxResults { break }
                }
            }
            if matches.count >= maxResults { break }
        }
        return [
            "matches": matches,
            "count": matches.count,
            "truncated": matches.count >= maxResults,
        ]
    }

    // MARK: - 7a. list_memory_files (v15p2 hotfix, 2026-05-02)

    private static var memoryDir: String {
        (obsidianVaultDir as NSString).appendingPathComponent("Claude Memory")
    }

    /// List the memory files in `Claude Memory/`. Useful so Marin
    /// can see what reference notes are available before reading
    /// any specific one (About Me, Working Principles, API Keys, etc.).
    static func listMemoryFiles() -> [String: Any] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: memoryDir) else {
            return ["status": "error", "reason": "Claude Memory directory not found"]
        }
        var files: [[String: Any]] = []
        for entry in entries.sorted() where entry.hasSuffix(".md") && !entry.hasPrefix(".") {
            let path = (memoryDir as NSString).appendingPathComponent(entry)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            files.append([
                "name": entry,
                "size_bytes": size,
            ])
        }
        return ["files": files, "count": files.count]
    }

    // MARK: - 7b. read_memory_file (v15p2 hotfix, 2026-05-02)

    /// Read a specific memory file from `Claude Memory/`. Use when
    /// Marin needs deeper context that isn't in the auto-injected
    /// Clicky Profile or Facts — most commonly About Me.md, but also
    /// Working Principles, AI & Data Initiatives, etc.
    /// Truncates very long files to keep Marin's context manageable.
    static func readMemoryFile(name: String) -> [String: Any] {
        guard !name.isEmpty else {
            return ["status": "error", "reason": "Empty file name"]
        }
        // Accept both with and without .md suffix.
        let normalized = name.hasSuffix(".md") ? name : "\(name).md"
        let fullPath = (memoryDir as NSString).appendingPathComponent(normalized)
        // Sanity: ensure resolved path is inside the memory dir.
        let standardized = (fullPath as NSString).standardizingPath
        guard standardized.hasPrefix(memoryDir) else {
            return ["status": "error", "reason": "Path is outside Claude Memory"]
        }
        guard let content = try? String(contentsOfFile: standardized, encoding: .utf8) else {
            return ["status": "error", "reason": "Could not read memory file: \(name)"]
        }
        // About Me.md is 80KB+; truncate to keep conversation lean.
        let maxChars = 12000
        let truncated = content.count > maxChars
        let displayContent = truncated
            ? String(content.prefix(maxChars)) + "\n\n[truncated — read full note in Obsidian]"
            : content
        return [
            "name": normalized,
            "content": displayContent,
            "char_count": content.count,
            "truncated": truncated,
        ]
    }

    // MARK: - 7. read_clicky_roadmap

    static func readClickyRoadmap() -> [String: Any] {
        guard let content = try? String(contentsOfFile: clickyRoadmapPath, encoding: .utf8) else {
            return ["status": "error", "reason": "Could not read Clicky roadmap"]
        }
        // Roadmap is large; truncate the same way as Obsidian notes.
        let maxChars = 12000
        let truncated = content.count > maxChars
        let displayContent = truncated
            ? String(content.prefix(maxChars)) + "\n\n[truncated — read full roadmap in Obsidian]"
            : content
        return [
            "content": displayContent,
            "char_count": content.count,
            "truncated": truncated,
        ]
    }

    // MARK: - append_to_bridge (v15p2, 2026-05-03)

    /// Append a message to the Claude–Marin Bridge file. Auto-stamps a
    /// timestamp + "Marin → Claude" header in the standard bridge
    /// format. If the bridge directory or file doesn't exist yet, this
    /// creates them with a header so first-write doesn't lose context.
    ///
    /// Restrict-by-design: this tool ONLY writes to the canonical
    /// bridge path. We don't expose a generic `append_obsidian_note`
    /// for v1 — keeps the surface small and removes the risk of Marin
    /// being persuaded to write to arbitrary vault notes.
    static func appendToBridge(message: String, threadId: String?) -> [String: Any] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["status": "error", "reason": "Empty message — nothing to append"]
        }

        let fm = FileManager.default

        // Ensure the Bridges directory exists.
        if !fm.fileExists(atPath: bridgeDir) {
            do {
                try fm.createDirectory(atPath: bridgeDir, withIntermediateDirectories: true)
            } catch {
                return ["status": "error", "reason": "Could not create Bridges directory: \(error.localizedDescription)"]
            }
        }

        // Format the entry header: "## YYYY-MM-DD HH:MM — Marin → Claude (thread: id)"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())
        let threadSuffix: String
        if let raw = threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            threadSuffix = " (thread: \(raw))"
        } else {
            threadSuffix = ""
        }
        let entry = "\n## \(timestamp) — Marin → Claude\(threadSuffix)\n\n\(trimmed)\n\n---\n"

        guard let entryData = entry.data(using: .utf8) else {
            return ["status": "error", "reason": "Could not encode message as UTF-8"]
        }

        // If the bridge file doesn't exist, seed it with the standard
        // header. Otherwise append.
        if fm.fileExists(atPath: bridgeFilePath) {
            let url = URL(fileURLWithPath: bridgeFilePath)
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: entryData)
            } catch {
                return ["status": "error", "reason": "Append failed: \(error.localizedDescription)"]
            }
        } else {
            let header = """
            # Claude ↔ Marin Bridge

            Shared message log between Cowork Claude and Marin (Clicky+ Realtime). Append-only — see prior entries for context.

            ---
            """
            let full = header + "\n" + entry
            do {
                try full.write(toFile: bridgeFilePath, atomically: true, encoding: .utf8)
            } catch {
                return ["status": "error", "reason": "Initial bridge write failed: \(error.localizedDescription)"]
            }
        }

        return [
            "status": "ok",
            "timestamp": timestamp,
            "char_count": trimmed.count,
            "thread_id": threadId ?? "",
            "path": "Bridges/Claude-Marin Channel.md",
        ]
    }

    // MARK: - read_clipboard (v15p3eh, 2026-05-16)
    //
    // Steph asked: "she had no trouble copying something to my clipboard,
    // but it seems that she can't read what's in my clipboard." Now she
    // can. NSPasteboard.string(forType: .string) is the canonical way to
    // pull the current text content. Returns empty + status=ok if the
    // clipboard is empty or non-text (we don't enumerate image / file
    // content for v1 — text is what Marin can actually do something with).
    //
    // Available on both providers via the dispatcher; the Gemini side
    // wires it into geminiToolDefinitions. To expose to OpenAI Marin,
    // the worker /realtime-session route also needs a tool definition
    // added — that's a separate worker deploy.

    static func readClipboard() -> [String: Any] {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string) else {
            return [
                "status": "ok",
                "content": "",
                "char_count": 0,
                "note": "Clipboard is empty or contains non-text content (image, file, etc.).",
            ]
        }
        // Trim outsized payloads so a giant clipboard (e.g. a huge
        // text dump) doesn't blow up the model's context. 10K char
        // cap mirrors the write_clipboard tool's limit.
        let trimmed: String
        let truncated: Bool
        if text.count > 10_000 {
            trimmed = String(text.prefix(10_000))
            truncated = true
        } else {
            trimmed = text
            truncated = false
        }
        return [
            "status": "ok",
            "content": trimmed,
            "char_count": text.count,
            "truncated": truncated,
        ]
    }

    // MARK: - run_applescript (v15p4cw, 2026-06-01)
    //
    // Catch-all local OS-control tool. Lets Marin drive any scriptable Mac
    // app (Spotify, Reminders, Notes, Finder, Mail, Music, System Events, etc.)
    // by generating AppleScript on the fly — the "super functional, broadly"
    // capability Steph wanted, modeled on Farza's GPT-Realtime-2 demo.
    //
    // SAFETY (Steph's machine runs real business work — voice mishearing flows
    // straight to execution, so this is gated harder than other tools):
    //   1. Deny-list — scripts containing genuinely destructive patterns are
    //      REFUSED outright and never run (shell-outs, rm, disk erase, mass
    //      delete, sudo, etc.). A misheard command can't reach these.
    //   2. requiresConfirmation flag — the CALLER (Gemini dispatcher) is told
    //      via the tool description to read back + wait for explicit yes before
    //      calling with confirmed=true on any mutating/destructive action.
    //      Benign actions (play/pause, volume, open app) run immediately.
    //   3. Full logging — every script (run or refused) is written to
    //      /tmp/clicky_applescript.log with the outcome, so anything odd is
    //      reconstructable. Mirrors the calendar-tool verbose logging.
    //
    // AppleScript (not raw shell) is the deliberate choice: it reaches the
    // structured app-automation doorway, which is broad but far more contained
    // than `bash`. We additionally block AppleScript's `do shell script`
    // escape hatch so it can't be used to smuggle arbitrary shell in.

    private static let applescriptLogPath = "/tmp/clicky_applescript.log"

    /// Patterns that cause an OUTRIGHT REFUSAL — never executed regardless of
    /// confirmation. Case-insensitive substring match on the script source.
    private static let applescriptDenyList: [String] = [
        "do shell script",   // AppleScript → shell escape hatch
        "rm -rf", "rm -r ", "/bin/rm", "diskutil erase", "erase disk",
        "sudo ", "mkfs", "dd if=", "dd of=",
        "delete every", "delete folder", "delete disk",
        "empty trash",       // mass destructive; allow explicitly later if wanted
        "system shutdown", "shut down", "restart computer",
    ]

    static func runAppleScript(source: String, confirmed: Bool) -> [String: Any] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ["status": "error", "reason": "Empty script"]
        }
        let lower = trimmed.lowercased()

        // 1. Deny-list — refuse outright, never execute.
        for pattern in applescriptDenyList where lower.contains(pattern) {
            appendAppleScriptLog(script: trimmed, outcome: "REFUSED (deny-list: \(pattern))")
            return [
                "status": "refused",
                "reason": "This script contains a blocked operation (\(pattern)) and was not run. Destructive/shell operations are disabled for safety.",
            ]
        }

        // 2. Confirmation gate. The tool description instructs the model to set
        // confirmed=true only after reading back a mutating action and getting
        // an explicit yes. If a heuristic flags this as mutating and it's not
        // confirmed, refuse and ask the caller to confirm. Benign read/playback
        // verbs are allowed through without confirmation.
        if Self.appleScriptLooksMutating(lower) && !confirmed {
            appendAppleScriptLog(script: trimmed, outcome: "BLOCKED (needs confirmation)")
            return [
                "status": "needs_confirmation",
                "reason": "This looks like it changes or creates something. Read the action back to Steph and call again with confirmed=true once he says yes.",
            ]
        }

        // 3. Execute on the MAIN thread, with an AppleScript-level timeout.
        //
        // v15p4cz (2026-06-01): REVERTED the v15p4cx background-thread approach.
        // It fixed the freeze but BROKE the macOS automation PERMISSION PROMPT:
        // TCC only surfaces the "Clicky wants to control <app>" prompt when the
        // Apple event is sent from the MAIN thread. From a background queue macOS
        // silently denies (errAEEventNotPermitted, "Not authorized") and never
        // even lists the app under Privacy → Automation — exactly what Steph saw
        // (no prompt, Clicky absent from the list).
        //
        // To get the prompt back AND avoid the original ~120s freeze on an
        // unresponsive app, we run on the main thread but wrap the user's script
        // in `with timeout of N seconds`, which caps how long app commands wait
        // for a reply. Worst case the main thread blocks ~N seconds instead of
        // 120 — a tolerable hitch, and only when an app is genuinely wedged.
        let timeoutSeconds = 12
        let wrapped = "with timeout of \(timeoutSeconds) seconds\n\(trimmed)\nend timeout"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: wrapped) else {
            // Fall back to the unwrapped script if the wrap fails to compile
            // (rare — e.g. the script defines top-level handlers).
            guard let bare = NSAppleScript(source: trimmed) else {
                appendAppleScriptLog(script: trimmed, outcome: "ERROR (could not compile)")
                return ["status": "error", "reason": "Could not compile the AppleScript."]
            }
            let out = bare.executeAndReturnError(&errorInfo)
            return finishAppleScript(trimmed, out, errorInfo)
        }
        let output = script.executeAndReturnError(&errorInfo)
        return finishAppleScript(trimmed, output, errorInfo)
    }

    private static func finishAppleScript(_ source: String, _ output: NSAppleEventDescriptor, _ errorInfo: NSDictionary?) -> [String: Any] {
        if let errorInfo {
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            appendAppleScriptLog(script: source, outcome: "ERROR: \(msg)")
            return ["status": "error", "reason": msg]
        }
        let resultString = output.stringValue ?? ""
        appendAppleScriptLog(script: source, outcome: "OK\(resultString.isEmpty ? "" : " → \(resultString.prefix(200))")")
        return ["status": "ok", "result": resultString]
    }

    /// Heuristic: does this script create/modify/delete/send rather than just
    /// read or control playback? Conservative — when unsure, treats as mutating
    /// so the confirmation gate fires. Playback/volume/open are allow-listed as
    /// benign because they're reversible and low-stakes.
    private static func appleScriptLooksMutating(_ lower: String) -> Bool {
        // v15p4cy (2026-06-01): tightened to avoid false positives on READ-ONLY
        // scripts. The old list flagged bare "set " — but reading data routinely
        // uses "set x to text of ..." for a LOCAL VARIABLE, which is not a
        // mutation. Steph hit this reading an iMessage ("set latestMessage to
        // text of first message...") — it got blocked for confirmation wrongly.
        //
        // New rule: only treat as mutating when a verb ACTS ON AN APP/SYSTEM
        // OBJECT. "set ... to" as local assignment is allowed; "set <property of
        // app object>" still caught via the app-targeting verbs below. We err
        // toward allowing reads (low stakes) while still catching real writes,
        // creates, sends, deletes, and anything that types into apps.
        let mutatingVerbs = [
            "make new", "delete ", "create ", "add ", "remove ", "move ",
            "duplicate ", "save ", "quit ", "close ", "keystroke", "key code",
            "send ",                 // Messages/Mail send
            "set the clipboard",     // overwrites clipboard
            "set volume",            // system volume (mild, but a change)
            "set value of",          // UI scripting writes
            "perform action",        // UI scripting clicks
            "click ",                // UI scripting clicks
        ]
        // "set <var> to" with no app-object target is a local read assignment —
        // don't treat the generic "set " as mutating anymore.
        return mutatingVerbs.contains { lower.contains($0) }
    }

    private static func appendAppleScriptLog(script: String, outcome: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] outcome=\(outcome)\n  script: \(script.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: applescriptLogPath),
               let handle = FileHandle(forWritingAtPath: applescriptLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: applescriptLogPath))
            }
        }
    }

    // MARK: - web_fetch (v15p3em, 2026-05-17)
    //
    // Fetch a URL and return its text content. Pairs with Gemini's
    // built-in google_search — search finds things, fetch reads them
    // by URL. Steph asked for both: "I definitely want web fetch and
    // Google search because web fetch would be useful to me."
    //
    // Implementation: URLSession.shared.data(from:) → decode UTF-8
    // → strip HTML tags to plain text → cap at 20K chars. Best-effort
    // HTML stripping (regex), not a full parser. Most articles come
    // through readable.

    static func webFetch(url urlString: String) async -> [String: Any] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["status": "error", "reason": "Empty URL"]
        }
        // Allow user to omit the scheme — default to https.
        let normalized: String = {
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return trimmed
            }
            return "https://" + trimmed
        }()
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            return ["status": "error", "reason": "Invalid URL: \(normalized)"]
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Marin/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ["status": "error", "reason": "No HTTP response"]
            }
            if !(200..<300).contains(http.statusCode) {
                return [
                    "status": "error",
                    "reason": "HTTP \(http.statusCode)",
                    "url": url.absoluteString,
                ]
            }
            guard let raw = String(data: data, encoding: .utf8) else {
                return ["status": "error", "reason": "Response is not UTF-8 text (binary content?)"]
            }
            let stripped = stripHTML(raw)
            let truncated = stripped.count > 20_000
            let content = truncated ? String(stripped.prefix(20_000)) : stripped
            return [
                "status": "ok",
                "url": url.absoluteString,
                "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? "",
                "char_count": stripped.count,
                "truncated": truncated,
                "content": content,
            ]
        } catch {
            return [
                "status": "error",
                "reason": "Fetch failed: \(error.localizedDescription)",
                "url": url.absoluteString,
            ]
        }
    }

    /// Best-effort HTML → plain text. Strips scripts, styles, tags,
    /// collapses whitespace, decodes a handful of common entities.
    /// Not a full parser — fine for typical articles/docs.
    private static func stripHTML(_ html: String) -> String {
        var s = html
        // Drop script/style blocks entirely.
        let dropBlocks = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<noscript[^>]*>[\\s\\S]*?</noscript>",
            "<!--[\\s\\S]*?-->",
        ]
        for pattern in dropBlocks {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Convert <br>, <p>, <div>, headings to newlines.
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // Strip remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common entities.
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&copy;", "©"), ("&rsquo;", "'"),
            ("&lsquo;", "'"), ("&ldquo;", "\""), ("&rdquo;", "\""),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse runs of whitespace.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Guidance memory + log (v15p3gq, 2026-05-18)
    //
    // Two related pieces of infrastructure Marin uses during multi-step
    // guidance sessions:
    //
    // 1. pinnedPlaybookContent — the playbook (typically the directions
    //    Steph has on his clipboard at start of a tutorial). Pinning it
    //    once means Marin doesn't have to re-read the clipboard on
    //    every turn and won't lose anchor if Steph copies something
    //    else mid-session.
    //
    // 2. Marin Guidance Log — every completed guidance session is
    //    appended to a single Obsidian file so Steph (or anyone asking
    //    "what can Marin help with?") has a real record of the
    //    multi-step things she's walked him through.
    //
    // Process-lifetime scope: pinnedPlaybookContent lives as long as
    // Clicky+ runs. Marin clears it explicitly when guidance ends.

    private static var pinnedPlaybookContent: String?

    private static var marinGuidanceLogPath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Marin Guidance Log.md")
            .expandingTildeInPath
    }

    /// v15p3gr (2026-05-18): also mirror the pinned playbook to disk so
    /// Steph can see what Marin's anchored on without asking. Single
    /// file, overwritten on each pin, cleared on unpin.
    private static var marinCurrentPlaybookPath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Marin Current Playbook.md")
            .expandingTildeInPath
    }

    /// v15p3gv (2026-05-18): append-only history of every playbook
    /// that's ever been pinned. Backstop for the case where Marin
    /// overwrites or clears the current playbook — without this,
    /// Steph loses the directions he was following. Archive is
    /// dumb-simple: timestamp header + full playbook body, separated
    /// by `---`. Newest entries at the bottom (append) so the file
    /// is chronological.
    private static var marinPlaybookArchivePath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Marin Playbook Archive.md")
            .expandingTildeInPath
    }

    /// Archive the currently-pinned playbook (if any) to the archive
    /// file. Called BEFORE any operation that would destroy the
    /// current playbook — pin (overwrite with new content) and clear.
    /// `reason` shows up in the archive entry header so Steph can tell
    /// "Marin replaced this with her own bad pin" from "Marin properly
    /// cleared this at session end."
    private static func archiveCurrentPlaybookIfPresent(reason: String) {
        // Prefer the in-memory copy because it's guaranteed-clean
        // (the on-disk file may already have been overwritten by the
        // time we get here on some code paths). Fall back to disk if
        // memory is empty.
        let bodyToArchive: String? = {
            if let memoryCopy = pinnedPlaybookContent, !memoryCopy.isEmpty {
                return memoryCopy
            }
            if let diskCopy = try? String(contentsOfFile: marinCurrentPlaybookPath, encoding: .utf8) {
                let trimmed = diskCopy.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.contains("No playbook pinned right now") {
                    return trimmed
                }
            }
            return nil
        }()
        guard let body = bodyToArchive else { return }

        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()

        let path = marinPlaybookArchivePath
        let fm = FileManager.default

        // Create with header on first call.
        if !fm.fileExists(atPath: path) {
            let header = """
            # Marin Playbook Archive

            Append-only history of every playbook Marin has been instructed
            to pin via `pin_playbook`. This is the recovery file — if Marin
            ever overwrites or clears the current playbook unexpectedly, the
            original is preserved here.

            Newest entries are at the bottom. Each entry shows when it was
            pinned and why it left the "Current" slot.

            """
            try? header.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let entry = """

        ---

        ## \(timestamp) — Archived (\(reason))

        \(body)

        """

        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func pinPlaybook(content: String) -> [String: Any] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["status": "error", "reason": "Empty playbook — nothing to pin"]
        }
        // v15p3gv (2026-05-18): archive whatever was previously pinned
        // before overwriting. Today Marin overwrote a real Amazon Ads
        // playbook with her own response text via pin_playbook, losing
        // the original. The archive is the safety net — any prior
        // content survives even when Marin misuses the tool.
        archiveCurrentPlaybookIfPresent(reason: "replaced by new pin_playbook call")
        pinnedPlaybookContent = trimmed

        // Mirror to Obsidian so Steph can see what's pinned.
        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()
        let fileBody = """
        # Marin Current Playbook

        *Pinned \(timestamp). Auto-cleared when Marin finishes guidance.*

        ---

        \(trimmed)
        """
        try? fileBody.write(toFile: marinCurrentPlaybookPath, atomically: true, encoding: .utf8)

        return [
            "status": "ok",
            "pinned_chars": trimmed.count,
            "preview": String(trimmed.prefix(160)),
            "obsidian_path": "Marin Current Playbook.md"
        ]
    }

    static func getPinnedPlaybook() -> [String: Any] {
        if let playbook = pinnedPlaybookContent {
            return [
                "status": "ok",
                "content": playbook,
                "chars": playbook.count,
                "source": "memory"
            ]
        }
        // v15p3gv (2026-05-18): fall back to the Obsidian mirror file
        // when in-memory state is empty. This covers the common case
        // of the app being restarted mid-guidance (rebuilds, crashes,
        // explicit restart) — the on-disk playbook survives even when
        // the static `pinnedPlaybookContent` doesn't. We strip the
        // "no playbook pinned right now" empty-state body so we don't
        // hand Marin a meaningless placeholder.
        let path = marinCurrentPlaybookPath
        if let fileContent = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEmptyStateMarker = trimmed.contains("No playbook pinned right now")
            if !trimmed.isEmpty && !isEmptyStateMarker {
                // Re-hydrate memory so subsequent calls within this
                // session hit the fast path.
                pinnedPlaybookContent = trimmed
                return [
                    "status": "ok",
                    "content": trimmed,
                    "chars": trimmed.count,
                    "source": "obsidian-mirror"
                ]
            }
        }
        return [
            "status": "empty",
            "reason": "No playbook pinned. If Steph has guidance directions, call read_clipboard then pin_playbook with what you read."
        ]
    }

    static func clearPinnedPlaybook() -> [String: Any] {
        let hadOne = pinnedPlaybookContent != nil
        // v15p3gv (2026-05-18): archive before clearing so the post-
        // session playbook is still recoverable. clearPinnedPlaybook
        // gets called automatically at session end (rule 7) — without
        // archiving, completed-guidance playbooks would be lost the
        // moment Marin says "done."
        archiveCurrentPlaybookIfPresent(reason: "cleared at session end")
        pinnedPlaybookContent = nil
        // Replace the Obsidian mirror with an empty-state note rather
        // than deleting the file — that way Steph can navigate to the
        // path and see "no playbook pinned" instead of a missing-file
        // error.
        let emptyBody = """
        # Marin Current Playbook

        *No playbook pinned right now. This file fills in automatically when Marin starts a guidance session.*
        """
        try? emptyBody.write(toFile: marinCurrentPlaybookPath, atomically: true, encoding: .utf8)
        return ["status": "ok", "had_playbook": hadOne]
    }

    /// Append a guidance session record to the Marin Guidance Log. Creates
    /// the file with a header on first call. Always appends — never
    /// overwrites existing entries.
    static func logGuidanceSession(
        title: String,
        summary: String,
        stepsCompleted: Int?,
        outcome: String?
    ) -> [String: Any] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedSummary.isEmpty else {
            return ["status": "error", "reason": "title and summary are both required"]
        }

        let fm = FileManager.default
        let path = marinGuidanceLogPath
        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()

        // Build the entry
        var entry = "\n## \(timestamp) — \(trimmedTitle)\n"
        if let steps = stepsCompleted {
            entry += "- Steps walked through: \(steps)\n"
        }
        if let outcome = outcome, !outcome.trimmingCharacters(in: .whitespaces).isEmpty {
            entry += "- Outcome: \(outcome)\n"
        }
        entry += "- Summary: \(trimmedSummary)\n"

        // Create file with header on first call.
        if !fm.fileExists(atPath: path) {
            let header = """
            # Marin Guidance Log

            Log of multi-step guidance sessions Marin walked Steph through.
            Used as a public record of what kind of help she can give — show
            this file to anyone asking "what can Marin help with?"

            Each entry is appended automatically by Marin at the end of a
            guidance session via the `log_guidance_session` tool.

            """
            do {
                try header.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return [
                    "status": "error",
                    "reason": "Failed to create guidance log: \(error.localizedDescription)"
                ]
            }
        }

        // Append.
        do {
            let url = URL(fileURLWithPath: path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            return [
                "status": "error",
                "reason": "Failed to append to guidance log: \(error.localizedDescription)"
            ]
        }

        return [
            "status": "ok",
            "logged_at": timestamp,
            "title": trimmedTitle,
            "path": "Marin Guidance Log.md"
        ]
    }

    // MARK: - update_leverage_roadmap_item (v15p3gn, 2026-05-17)
    //
    // Marin's first WRITE-capable Obsidian tool. Modifies Steph's
    // Leverage Roadmap.md based on a verb + optional payload. Designed
    // so Steph can point at any item in the morning brief's Roadmap
    // tab and say "check this off" / "push the date out" / "change
    // the next step to X" / "park this with reason Y" — Marin reads
    // the file, locates the matching Active item by fuzzy name match,
    // applies the operation, and writes back atomically.
    //
    // Operations:
    //   • ship / done / shipped / completed → move to Done table, dated today
    //   • keep → move to Done, "Steph decided to keep it"
    //   • kill / drop / retire → move to Done, marked killed
    //   • park / shelf → move to Parked section, with reason
    //   • replace_text → find a substring within the item's lines and replace
    //   • append_note → add a new sub-bullet under the item
    //
    // The Active section uses nested bullets:
    //   - **Item Name** — *added YYYY-MM-DD*
    //     - Why: ...
    //     - Next step: ...
    //     - Source: ...
    //
    // We treat each `- **` line as the start of an item, and slurp
    // everything (indented sub-bullets, blank lines) until the next
    // `- **` / `## ` / `### ` line.

    private static var leverageRoadmapPath: String {
        NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Leverage/Roadmap.md").expandingTildeInPath
    }

    static func updateLeverageRoadmapItem(
        name: String,
        operation: String,
        reason: String? = nil,
        findText: String? = nil,
        replaceWith: String? = nil,
        appendText: String? = nil
    ) -> [String: Any] {
        let path = leverageRoadmapPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ["status": "error", "reason": "Roadmap.md not found at \(path)"]
        }

        var lines = content.components(separatedBy: "\n")
        let op = operation.lowercased()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        // RESTORE — search Done table and Parked section, move item back
        // to Active. v15p3go (2026-05-17): added after Steph killed an
        // item and tried to "unkill" it; Marin had no way to undo.
        // Restored items get a stub bullet in Active because the
        // original sub-bullets (Why / Next step / Source) aren't
        // preserved in Done (table) or Parked (single-line entries).
        if op == "restore" {
            let nameLower = name.lowercased()

            // 1. Try Done table first. Rows look like:
            //    | Item Name | YYYY-MM-DD | Closed by note |
            guard let doneStart = lines.firstIndex(where: { $0.hasPrefix("## ✅ Done") }) else {
                return ["status": "error", "reason": "Done section not found"]
            }
            var foundInDone: (index: Int, itemName: String, closedBy: String)?
            for k in doneStart..<lines.count {
                let line = lines[k]
                if !line.hasPrefix("|") { continue }
                if line.hasPrefix("|---") || line.contains("| Item ") { continue }
                // Cells split on `|`. First non-empty cell is the item name.
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let nonEmpty = cells.filter { !$0.isEmpty }
                guard nonEmpty.count >= 3 else { continue }
                let itemName = nonEmpty[0]
                let closedBy = nonEmpty[2]
                if itemName.lowercased().contains(nameLower) {
                    foundInDone = (k, itemName, closedBy)
                    break
                }
            }

            // 2. If not in Done, try Parked. Entries look like:
            //    - **Item Name** — reason
            var foundInParked: (index: Int, itemName: String, parkedReason: String)?
            if foundInDone == nil {
                guard let parkedStart = lines.firstIndex(where: { $0.hasPrefix("## 🟡 Parked") }) else {
                    return ["status": "error", "reason": "Parked section not found"]
                }
                let parkedEnd: Int = {
                    for k in (parkedStart + 1)..<lines.count {
                        if lines[k].hasPrefix("## ") { return k }
                    }
                    return lines.count
                }()
                for k in parkedStart..<parkedEnd {
                    let line = lines[k]
                    if !line.hasPrefix("- **") { continue }
                    let afterPrefix = line.index(line.startIndex, offsetBy: 4)
                    guard let closeRange = line.range(of: "**", range: afterPrefix..<line.endIndex) else { continue }
                    let itemName = String(line[afterPrefix..<closeRange.lowerBound])
                    // Reason is everything after the closing ** and the
                    // em-dash separator (— or --).
                    let afterClose = line[closeRange.upperBound..<line.endIndex]
                    let reasonText = afterClose
                        .replacingOccurrences(of: "— ", with: "")
                        .replacingOccurrences(of: "-- ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if itemName.lowercased().contains(nameLower) {
                        foundInParked = (k, itemName, reasonText)
                        break
                    }
                }
            }

            if foundInDone == nil && foundInParked == nil {
                return [
                    "status": "error",
                    "reason": "No item matched '\(name)' in Done or Parked. (Restore only works on items already closed/parked.)"
                ]
            }

            // Build the restored Active bullet. Sub-bullets are minimal
            // because the original context wasn't preserved.
            let restoredName: String
            let originLine: String
            if let inDone = foundInDone {
                restoredName = inDone.itemName
                originLine = "Restored from Done — original close note: \(inDone.closedBy)"
                lines.remove(at: inDone.index)
            } else if let inParked = foundInParked {
                restoredName = inParked.itemName
                originLine = "Restored from Parked — original park reason: \(inParked.parkedReason)"
                lines.remove(at: inParked.index)
            } else {
                return ["status": "error", "reason": "Internal state error"]
            }

            let bulletLines = [
                "- **\(restoredName)** — *restored \(today)*",
                "  - \(originLine)",
                "  - Next step: TBD — edit this item to add current context",
                ""
            ]

            // Insert at the top of the first subsection inside Active
            // (right after the first "### " heading).
            guard let activeStartIdx = lines.firstIndex(where: { $0.hasPrefix("## 🟢 Active") }) else {
                return ["status": "error", "reason": "Active section not found"]
            }
            let activeEndIdx: Int = {
                for k in (activeStartIdx + 1)..<lines.count {
                    if lines[k].hasPrefix("## ") { return k }
                }
                return lines.count
            }()
            var insertAt: Int?
            for k in (activeStartIdx + 1)..<activeEndIdx {
                if lines[k].hasPrefix("### ") {
                    // Insert right AFTER this subsection header, plus any
                    // blank line that immediately follows it.
                    var idx = k + 1
                    if idx < activeEndIdx && lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                        idx += 1
                    }
                    insertAt = idx
                    break
                }
            }
            // Fallback: just after the Active heading.
            let insertIdx = insertAt ?? (activeStartIdx + 1)
            lines.insert(contentsOf: bulletLines, at: insertIdx)

            // Write back atomically.
            let newContent = lines.joined(separator: "\n")
            do {
                try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return ["status": "error", "reason": "Failed to write Roadmap.md: \(error.localizedDescription)"]
            }
            return [
                "status": "ok",
                "item": restoredName,
                "operation": "restore",
                "date": today,
                "note": "Restored as a stub; original Why/Next step/Source were lost when archived. Edit to add current context."
            ]
        }

        // Locate the Active section (still required as the move
        // destination / origin reference for some paths).
        guard let activeStart = lines.firstIndex(where: { $0.hasPrefix("## 🟢 Active") }) else {
            return ["status": "error", "reason": "Active section not found"]
        }
        let activeEnd: Int = {
            for i in (activeStart + 1)..<lines.count {
                if lines[i].hasPrefix("## ") { return i }
            }
            return lines.count
        }()

        // v15p4m (2026-05-23): broadened search to include all
        // top-level sections EXCEPT Parked and Done. Why: items
        // captured to the roadmap via Idea-Inbox-Sweep land under
        // "## How this doc gets updated" → "### Inbox Sweep …"
        // and don't get merged into Active until the biweekly audit.
        // Marin needs to be able to mark those done/killed/parked
        // directly. Real failure (2026-05-23T19:44): Steph pointed
        // at "Agent-based visual QA for dashboards" (in Inbox Sweep
        // 2026-05-11) and Marin returned "No item matched in Active
        // section." even after silently re-reading the file.
        //
        // We do NOT search Parked or Done — those sections hold
        // already-closed items, and matching them for a fresh
        // ship/kill/park would be incoherent (use `restore` first).
        struct SearchRegion {
            let start: Int
            let end: Int  // exclusive
            let label: String
        }
        var regions: [SearchRegion] = [
            SearchRegion(start: activeStart, end: activeEnd, label: "Active")
        ]
        var scan = 0
        while scan < lines.count {
            let line = lines[scan]
            if line.hasPrefix("## ")
                && !line.hasPrefix("## 🟢 Active")
                && !line.hasPrefix("## 🟡 Parked")
                && !line.hasPrefix("## ✅ Done") {
                let regionStart = scan
                var regionEnd = lines.count
                for j in (scan + 1)..<lines.count {
                    if lines[j].hasPrefix("## ") {
                        regionEnd = j
                        break
                    }
                }
                let label = line
                    .replacingOccurrences(of: "## ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                regions.append(SearchRegion(start: regionStart, end: regionEnd, label: label))
                scan = regionEnd
            } else {
                scan += 1
            }
        }

        // Find the matching item. Case-insensitive substring on the
        // bold name. Returns (start index, end index exclusive, name).
        // Multiple matches → return candidates so Marin can clarify
        // with the user verbally before retrying.
        struct ItemRange {
            let start: Int
            let end: Int
            let boldName: String
            let regionLabel: String
        }
        let nameLower = name.lowercased()
        var matches: [ItemRange] = []
        for region in regions {
            var i = region.start
            while i < region.end {
                let line = lines[i]
                if line.hasPrefix("- **") {
                    // Extract bold name between leading `- **` and the next `**`.
                    let afterPrefix = line.index(line.startIndex, offsetBy: 4)
                    if let closeRange = line.range(of: "**", range: afterPrefix..<line.endIndex) {
                        let boldName = String(line[afterPrefix..<closeRange.lowerBound])
                        // Walk forward to find this bullet's end.
                        var j = i + 1
                        while j < region.end {
                            let next = lines[j]
                            if next.hasPrefix("- **") || next.hasPrefix("## ") || next.hasPrefix("### ") {
                                break
                            }
                            j += 1
                        }
                        if boldName.lowercased().contains(nameLower) {
                            matches.append(ItemRange(start: i, end: j, boldName: boldName, regionLabel: region.label))
                        }
                        i = j
                        continue
                    }
                }
                i += 1
            }
        }

        if matches.isEmpty {
            // v15p4n (2026-05-23): before falling through to "not found",
            // sweep Done and Parked so we can tell Marin (and through
            // her, Steph) "already done on YYYY-MM-DD — close note: X"
            // instead of the generic "not on the roadmap." Steph: "she
            // shouldn't have just said this one's not on the road map.
            // She should have said it's already marked as done."
            //
            // Done table rows: `| Item Name | YYYY-MM-DD | close note |`
            // Parked entries:   `- **Item Name** — reason`
            let nameLowerLocal = nameLower
            if let doneStart = lines.firstIndex(where: { $0.hasPrefix("## ✅ Done") }) {
                for k in doneStart..<lines.count {
                    let line = lines[k]
                    if !line.hasPrefix("|") { continue }
                    if line.hasPrefix("|---") || line.contains("| Item ") { continue }
                    let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let nonEmpty = cells.filter { !$0.isEmpty }
                    guard nonEmpty.count >= 3 else { continue }
                    let itemName = nonEmpty[0]
                    let closedDate = nonEmpty[1]
                    let closedBy = nonEmpty[2]
                    if itemName.lowercased().contains(nameLowerLocal) {
                        return [
                            "status": "already_done",
                            "item": itemName,
                            "closed_date": closedDate,
                            "close_note": closedBy,
                            "reason": "'\(itemName)' is already in Done — closed \(closedDate) (\(closedBy)). Tell Steph it's already marked done; if he wants to reopen it, use the `restore` operation."
                        ]
                    }
                }
            }
            if let parkedStart = lines.firstIndex(where: { $0.hasPrefix("## 🟡 Parked") }) {
                let parkedEnd: Int = {
                    for k in (parkedStart + 1)..<lines.count {
                        if lines[k].hasPrefix("## ") { return k }
                    }
                    return lines.count
                }()
                for k in parkedStart..<parkedEnd {
                    let line = lines[k]
                    if !line.hasPrefix("- **") { continue }
                    let afterPrefix = line.index(line.startIndex, offsetBy: 4)
                    guard let closeRange = line.range(of: "**", range: afterPrefix..<line.endIndex) else { continue }
                    let itemName = String(line[afterPrefix..<closeRange.lowerBound])
                    let afterClose = line[closeRange.upperBound..<line.endIndex]
                    let parkedReason = afterClose
                        .replacingOccurrences(of: "— ", with: "")
                        .replacingOccurrences(of: "-- ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if itemName.lowercased().contains(nameLowerLocal) {
                        return [
                            "status": "already_parked",
                            "item": itemName,
                            "park_reason": parkedReason,
                            "reason": "'\(itemName)' is already in Parked — reason: \(parkedReason). Tell Steph it's already parked; if he wants to reopen it, use the `restore` operation."
                        ]
                    }
                }
            }
            let regionList = regions.map { $0.label }.joined(separator: ", ")
            // v15p4o (2026-05-23): make the not-found reason directive
            // instead of descriptive. Observed regression — even with
            // the TOOL-ERROR REMEDIATION persona rule, Marin sometimes
            // reads the file silently and then STILL says "Shall I read
            // the file first?" (self-state hallucination, common LLM
            // failure mode). Solution: bake the next-action instruction
            // into the response text so she doesn't have to derive it.
            return [
                "status": "error",
                "reason": "'\(name)' is not on the roadmap (searched: \(regionList), Done, Parked). NEXT ACTION: if you have not already read Leverage/Roadmap.md this session, call read_obsidian_note now and retry update_roadmap_item with the actual bold name from the file. If you ALREADY read the file this session and the item still isn't there, just tell Steph in past tense: \"That one isn't on the roadmap.\" Do NOT say \"I might need to read the file first\" or \"Shall I do that now?\" — those are permission-asking and forbidden by your persona's TOOL-ERROR REMEDIATION rule."
            ]
        }
        if matches.count > 1 {
            return [
                "status": "error",
                "reason": "Multiple items matched '\(name)'. Ask Steph which one.",
                "candidates": matches.map { $0.boldName }
            ]
        }

        let match = matches[0]
        let resolvedName = match.boldName
        // formatter / today already declared above for the restore path.

        // STATUS MOVES — remove from Active, add to Done table or Parked section.
        if ["ship", "done", "shipped", "completed", "keep", "kill", "drop", "retire", "killed"].contains(op) {
            let closedBy: String
            switch op {
            case "keep":
                closedBy = "Steph decided to keep it" + (reason.map { " — \($0)" } ?? "")
            case "kill", "drop", "retire", "killed":
                closedBy = "Killed" + (reason.map { " — \($0)" } ?? "")
            default:
                closedBy = "Shipped" + (reason.map { " — \($0)" } ?? "")
            }
            let newRow = "| \(resolvedName) | \(today) | \(closedBy) |"

            // Remove the item from Active.
            lines.removeSubrange(match.start..<match.end)

            // Insert into the Done table directly under the header row.
            guard let doneStart = lines.firstIndex(where: { $0.hasPrefix("## ✅ Done") }) else {
                return ["status": "error", "reason": "Done section not found"]
            }
            var insertAt: Int?
            for k in (doneStart + 1)..<lines.count {
                if lines[k].hasPrefix("|---") {
                    insertAt = k + 1
                    break
                }
            }
            guard let insertIdx = insertAt else {
                return ["status": "error", "reason": "Done table header not found"]
            }
            lines.insert(newRow, at: insertIdx)
        } else if op == "park" || op == "shelf" {
            // Remove from Active and add as a one-liner to Parked.
            lines.removeSubrange(match.start..<match.end)
            guard let parkedStart = lines.firstIndex(where: { $0.hasPrefix("## 🟡 Parked") }) else {
                return ["status": "error", "reason": "Parked section not found"]
            }
            var insertAt = parkedStart + 1
            while insertAt < lines.count && lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt += 1
            }
            let parkedReason = reason ?? "no reason given"
            let parkedLine = "- **\(resolvedName)** — \(parkedReason)"
            lines.insert(parkedLine, at: insertAt)
        } else if op == "replace_text" {
            // Find/replace within the item's own lines. Caller MUST pass
            // findText. If replaceWith is nil, we delete the find_text
            // (rare but supported). Replaces only the FIRST occurrence
            // within the item to keep the operation predictable.
            guard let find = findText, !find.isEmpty else {
                return ["status": "error", "reason": "replace_text needs find_text"]
            }
            let replacement = replaceWith ?? ""
            var didReplace = false
            for k in match.start..<match.end {
                if lines[k].contains(find) {
                    lines[k] = (lines[k] as NSString).replacingOccurrences(
                        of: find,
                        with: replacement,
                        options: [],
                        range: NSRange(location: 0, length: (lines[k] as NSString).length)
                    )
                    didReplace = true
                    break
                }
            }
            if !didReplace {
                return [
                    "status": "error",
                    "reason": "find_text not found inside '\(resolvedName)'. Read the item first to get the exact text."
                ]
            }
        } else if op == "append_note" {
            // Add a sub-bullet at the end of this item's lines (just
            // before the trailing blank line, if present).
            guard let text = appendText, !text.isEmpty else {
                return ["status": "error", "reason": "append_note needs append_text"]
            }
            let subBullet = "  - \(text)"
            // Find the insertion point: the last non-blank line of the
            // item, then insert AFTER it.
            var insertAt = match.end
            // Walk back to skip trailing blanks.
            while insertAt > match.start && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(subBullet, at: insertAt)
        } else {
            return [
                "status": "error",
                "reason": "Unknown operation '\(operation)'. Valid: ship, park, keep, kill, replace_text, append_note, restore"
            ]
        }

        // Write back atomically.
        let newContent = lines.joined(separator: "\n")
        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return [
                "status": "error",
                "reason": "Failed to write Roadmap.md: \(error.localizedDescription)"
            ]
        }

        return [
            "status": "ok",
            "item": resolvedName,
            "operation": op,
            "date": today
        ]
    }
}
