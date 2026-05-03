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
}
