//
//  MarinHelperSubAgent.swift
//  leanring-buddy
//
//  v15p4t (2026-05-23): Phase 1 — Marin's local helper sub-agent.
//
//  Marin spawns a Claude Sonnet 4.6 helper with local tools when she
//  hits a hard question: multi-step research, file reads, verbatim
//  search through long content, drafting. The helper runs autonomously,
//  loops through tool calls until it has an answer, and returns it as
//  a string. Marin then reads the answer to Steph.
//
//  Architecture: direct Anthropic API call from the Mac (no Worker).
//  Auth: Anthropic API key in UserDefaults (`clicky.helper.anthropicApiKey`)
//  or env var `ANTHROPIC_API_KEY`. Post-6/15 this will swap to Agent
//  SDK + Max OAuth per Clicky+ Level 4 Spec.
//
//  Tools (Tier 1, this phase):
//    • read_file(path)      — read any text file on disk
//    • list_dir(path)       — directory listing
//    • bash(command)        — run a shell command (read-only by convention;
//                             a regex pre-check rejects obvious writes)
//    • web_search(query)    — Anthropic's native web_search tool
//
//  Tier 2 (write_file, append_to_inbox) and Tier 3 (MCPs) ship later.
//
//  Cost guard: per-day USD spend cap (default $5, configurable via
//  UserDefaults key `clicky.helper.spendCapCentsPerDay`). When today's
//  spend hits the cap, the helper refuses new tasks until midnight
//  local time. Pricing: Sonnet 4.6 = $3/M input, $15/M output (as of
//  2026-05).
//
//  Diag: every invocation is appended to /tmp/clicky_helper_diag.log
//  with timestamp, task, each iteration's tool calls + truncated
//  responses, final answer length, token counts, and cost.
//
//  UX hook: posts `helperStateChangedNotification` when starting/ending
//  so the notch pill (NotchPanelManager) can swap to "Researching"
//  state. Subscriber: CompanionManager.

import Foundation
import AppKit

/// Notification posted when the helper starts or finishes a task.
/// userInfo: ["active": Bool, "taskPreview": String?]
extension Notification.Name {
    static let marinHelperStateChanged = Notification.Name("clicky.marinHelper.stateChanged")
}

actor MarinHelperSubAgent {
    static let shared = MarinHelperSubAgent()

    // MARK: - Config

    private let model = "claude-sonnet-4-6"
    private let maxIterations = 20
    private let perCallTimeoutSeconds: TimeInterval = 60
    private let diagPath = "/tmp/clicky_helper_diag.log"
    private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// v15p4av (2026-05-24): Cloudflare worker base for Tier 3 MCP tools.
    /// Shares the same worker as Marin (Fireflies, Slack, Gmail, Calendar).
    private let workerBaseURL = "https://clicky-proxy.sapierso.workers.dev"

    // Pricing for Sonnet 4.6, USD per token. Update if Anthropic changes.
    private let inputCostPerToken: Double = 3.0 / 1_000_000.0
    private let outputCostPerToken: Double = 15.0 / 1_000_000.0

    // UserDefaults keys.
    private let apiKeyDefaultsKey = "clicky.helper.anthropicApiKey"
    private let spendCapCentsKey = "clicky.helper.spendCapCentsPerDay"
    private let spendCentsTodayKey = "clicky.helper.spendCentsToday"
    private let spendDateKey = "clicky.helper.spendDate"

    // MARK: - Public entry point

    /// Submit a fresh task. Returns taskId immediately; work runs detached.
    /// `summary`: short 3-5 word title for the card header. Card defaults
    /// to showing this; user expands to see the full task text. v15p4as.
    nonisolated func submit(task: String, context: String? = nil, category: HelperTaskCategory = .generic, summary: String? = nil) async -> String {
        var newTask = HelperTask(task: task, context: context, category: category)
        newTask.summary = summary
        let taskId = newTask.id
        await MainActor.run {
            HelperTaskStore.shared.add(newTask)
        }
        postStateChange(active: true, taskPreview: String(task.prefix(80)))
        Task.detached { [weak self] in
            await self?.runDetached(taskId: taskId, isFollowUp: false, followUpUserMessage: nil)
        }
        return taskId
    }

    /// Follow up on an existing completed task — RESUMES THE SAME AGENT
    /// LOOP with the prior conversation history. The agent sees the
    /// original task, its prior tool calls, its prior answer, and the
    /// new user message. Result accumulates into a multi-turn thread.
    /// v15p4x (2026-05-23).
    nonisolated func followUp(taskId: String, userMessage: String) async {
        // v15p4aw: diag logging on every step so we can see exactly
        // where the follow-up button is failing (or not failing).
        diagNonisolated("followUp ENTRY taskId=\(taskId) msg=\(String(userMessage.prefix(80)))")
        let preflightStatus: String? = await MainActor.run {
            HelperTaskStore.shared.tasks.first(where: { $0.id == taskId })?.status.rawValue
        }
        diagNonisolated("followUp preflight status=\(preflightStatus ?? "TASK_NOT_FOUND")")
        let prepared: Bool = await MainActor.run {
            HelperTaskStore.shared.prepareFollowUp(id: taskId, userMessage: userMessage) != nil
        }
        guard prepared else {
            diagNonisolated("followUp BAILED prepareFollowUp returned nil — status was \(preflightStatus ?? "?") (need .completed)")
            return
        }
        diagNonisolated("followUp DETACHING runDetached for taskId=\(taskId)")
        postStateChange(active: true, taskPreview: String(userMessage.prefix(80)))
        Task.detached { [weak self] in
            await self?.runDetached(taskId: taskId, isFollowUp: true, followUpUserMessage: userMessage)
        }
    }

    /// Diag from nonisolated context. Writes to the same log file as
    /// the actor-isolated diag(). v15p4aw.
    private nonisolated func diagNonisolated(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [helper] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/clicky_helper_diag.log"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Shared run loop for both initial submit and follow-up. Reads the
    /// task's current state from HelperTaskStore, runs the agent until
    /// end_turn / failure / max iterations, persists the updated
    /// messages array + accumulated result on success.
    private func runDetached(taskId: String, isFollowUp: Bool, followUpUserMessage: String?) async {
        guard let initial = await MainActor.run(body: { HelperTaskStore.shared.tasks.first(where: { $0.id == taskId }) }) else {
            postStateChange(active: false, taskPreview: nil)
            return
        }

        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else {
            await MainActor.run { HelperTaskStore.shared.markFailed(id: taskId, error: HelperError.missingAPIKey.localizedDescription) }
            postStateChange(active: false, taskPreview: nil)
            return
        }
        do { try checkSpendCap() } catch {
            await MainActor.run { HelperTaskStore.shared.markFailed(id: taskId, error: error.localizedDescription) }
            postStateChange(active: false, taskPreview: nil)
            return
        }

        await MainActor.run { HelperTaskStore.shared.markRunning(id: taskId) }
        let started = Date()
        let priorResult = initial.result  // captured before we overwrite

        // Assemble starting messages. For initial run, fresh user
        // message. For follow-up, load the stored conversation (the
        // store has already appended the new user turn).
        var messages: [[String: Any]]
        if isFollowUp {
            messages = initial.loadMessages()
            diag("--- BEGIN id=\(taskId) FOLLOW-UP turn=\(initial.turnCount) msgs=\(messages.count)")
        } else {
            messages = [
                ["role": "user", "content": buildUserMessage(task: initial.task, context: initial.context)]
            ]
            diag("--- BEGIN id=\(taskId) cat=\(initial.category.rawValue) task=\(String(initial.task.prefix(200)))")
            if let ctx = initial.context, !ctx.isEmpty {
                diag("    context=\(String(ctx.prefix(200)))")
            }
        }

        var totalInputTokens = 0
        var totalOutputTokens = 0

        // v15p4ay (2026-05-25): loop guard. Track consecutive read-only
        // tool calls. After explorationCap reads without a commit
        // (write_file / copy_to_clipboard / append_to_inbox /
        // update_roadmap_item / end_turn), inject a forced-commit
        // tool_result that tells the model to stop exploring. Real
        // failure 2026-05-25T21:46: helper burned 19 of 20 iters
        // grepping clicky-plus source on a draft-Slack task.
        let explorationCap = 8
        let readOnlyToolNames: Set<String> = [
            "read_file", "list_dir", "bash", "web_search",
            "search_meetings", "read_meeting_summary", "read_meeting_transcript", "list_recent_meetings",
            "search_slack", "read_slack_thread", "list_unread_slack",
            "search_gmail", "read_email_thread",
            "list_calendar_events", "find_next_event"
        ]
        let commitToolNames: Set<String> = [
            "write_file", "copy_to_clipboard", "append_to_inbox", "update_roadmap_item"
        ]
        var consecutiveReadOnly = 0

        for iteration in 1...maxIterations {
            do {
                let response = try await callAnthropic(apiKey: apiKey, messages: messages)
                totalInputTokens += response.inputTokens
                totalOutputTokens += response.outputTokens
                diag("id=\(taskId) iter=\(iteration) stop=\(response.stopReason) inTok=\(response.inputTokens) outTok=\(response.outputTokens)")

                if response.stopReason == "end_turn" {
                    let answer = extractText(from: response.contentBlocks)
                    // Append the assistant turn to messages so the stored
                    // history is complete (next follow-up sees it).
                    messages.append([
                        "role": "assistant",
                        "content": response.contentBlocks
                    ])
                    let elapsed = Date().timeIntervalSince(started)
                    let cost = Double(totalInputTokens) * inputCostPerToken + Double(totalOutputTokens) * outputCostPerToken
                    recordSpend(usd: cost)
                    diag("--- END id=\(taskId) iters=\(iteration) elapsed=\(String(format: "%.1f", elapsed))s tok_in=\(totalInputTokens) tok_out=\(totalOutputTokens) cost=$\(String(format: "%.4f", cost)) answer_len=\(answer.count)")

                    // Build the result string. For initial runs, just the
                    // answer. For follow-ups, prior result + a divider +
                    // the follow-up Q + new answer, so the thread reads
                    // top-to-bottom.
                    let finalResult: String
                    if isFollowUp, let prior = priorResult {
                        let q = followUpUserMessage ?? "(follow-up)"
                        finalResult = "\(prior)\n\n──── follow-up ────\n\n> \(q)\n\n\(answer)"
                    } else {
                        finalResult = answer
                    }

                    await MainActor.run {
                        HelperTaskStore.shared.markCompleted(
                            id: taskId,
                            result: finalResult,
                            messages: messages,
                            inputTokens: totalInputTokens,
                            outputTokens: totalOutputTokens,
                            costUSD: cost
                        )
                    }
                    postStateChange(active: false, taskPreview: nil)
                    return
                }

                if response.stopReason == "tool_use" {
                    messages.append([
                        "role": "assistant",
                        "content": response.contentBlocks
                    ])
                    var toolResults: [[String: Any]] = []
                    var sawCommitToolThisTurn = false
                    var sawReadOnlyToolThisTurn = false
                    for block in response.contentBlocks {
                        guard let type = block["type"] as? String, type == "tool_use",
                              let id = block["id"] as? String,
                              let name = block["name"] as? String else { continue }
                        let input = (block["input"] as? [String: Any]) ?? [:]
                        let resultText = await executeTool(name: name, input: input)
                        diag("  id=\(taskId) tool=\(name) input=\(truncate(input, max: 200)) result=\(truncate(resultText, max: 300))")
                        toolResults.append([
                            "type": "tool_result",
                            "tool_use_id": id,
                            "content": resultText
                        ])
                        if commitToolNames.contains(name) { sawCommitToolThisTurn = true }
                        if readOnlyToolNames.contains(name) { sawReadOnlyToolThisTurn = true }
                    }

                    // Update consecutive read-only counter.
                    if sawCommitToolThisTurn {
                        consecutiveReadOnly = 0
                    } else if sawReadOnlyToolThisTurn {
                        consecutiveReadOnly += 1
                    }

                    // Inject forced-commit nudge if we've exceeded the cap.
                    if consecutiveReadOnly >= explorationCap {
                        let nudge = "[helper-runtime] You have called \(consecutiveReadOnly) read-only tools without producing output. STOP exploring. In your next turn you MUST either (a) end the conversation with a written answer based on what you already have, or (b) call write_file / copy_to_clipboard / append_to_inbox to deliver the result. No more bash / grep / search / read_file. If you don't have enough information yet, say so concisely and end the turn."
                        toolResults.append([
                            "type": "text",
                            "text": nudge
                        ])
                        diag("  id=\(taskId) [loop-guard] INJECTED commit-nudge after \(consecutiveReadOnly) read-only calls")
                        // Reset so we don't spam the nudge every turn.
                        consecutiveReadOnly = 0
                    }

                    messages.append(["role": "user", "content": toolResults])
                    continue
                }

                await MainActor.run {
                    HelperTaskStore.shared.markFailed(id: taskId, error: "Unexpected stop_reason: \(response.stopReason)")
                }
                postStateChange(active: false, taskPreview: nil)
                return
            } catch {
                await MainActor.run {
                    HelperTaskStore.shared.markFailed(id: taskId, error: error.localizedDescription)
                }
                postStateChange(active: false, taskPreview: nil)
                return
            }
        }

        await MainActor.run {
            HelperTaskStore.shared.markFailed(id: taskId, error: HelperError.exceededMaxIterations.localizedDescription)
        }
        postStateChange(active: false, taskPreview: nil)
    }

    // MARK: - Anthropic API call

    private struct APIResponse {
        let stopReason: String
        let contentBlocks: [[String: Any]]
        let inputTokens: Int
        let outputTokens: Int
    }

    private func callAnthropic(apiKey: String, messages: [[String: Any]]) async throws -> APIResponse {
        var req = URLRequest(url: anthropicURL)
        req.httpMethod = "POST"
        req.timeoutInterval = perCallTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": HelperSystemPrompt.body,
            "messages": messages,
            "tools": toolDefinitions
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw HelperError.apiStatus(http.statusCode, String(body.prefix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stop = json["stop_reason"] as? String,
              let content = json["content"] as? [[String: Any]] else {
            throw HelperError.malformedResponse
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inTok = (usage["input_tokens"] as? Int) ?? 0
        let outTok = (usage["output_tokens"] as? Int) ?? 0
        return APIResponse(stopReason: stop, contentBlocks: content, inputTokens: inTok, outputTokens: outTok)
    }

    // MARK: - Tool definitions (Tier 1)

    private var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "read_file",
                "description": "Read the full contents of a text file on Steph's Mac. Use for code, notes, Obsidian markdown, transcripts, config files. Paths MUST start with ~/ — never hardcode /Users/<name>/. Scoped to home directory and below.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute file path."]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "list_dir",
                "description": "List entries in a directory. Returns names + file/dir type. Use to discover files before reading.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute directory path."]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "bash",
                "description": "Run a shell command. Read-only by convention — do NOT use to modify files (writes via `>`, `>>`, `rm`, `mv` are rejected). Good for: grep, awk, sed (read), find, wc, head, tail, cat, ls -la, git log/diff/show, jq.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The shell command to run."]
                    ],
                    "required": ["command"]
                ]
            ],
            [
                "name": "web_search",
                "type": "web_search_20250305",
                "max_uses": 5
            ],
            // v15p4af (2026-05-24): Tier 2 — drafting & publishing.
            [
                "name": "write_file",
                "description": "Write or append a UTF-8 text file. CRITICAL: paths MUST start with ~/ — never hardcode /Users/<name>/. If you write a hardcoded user path, the runtime auto-corrects it, but you should use ~/ to avoid the round-trip. DEFAULT DESTINATION (use unless Steph explicitly names a path): ~/Desktop/Claude Cowork/Obsidian/Steph Vault/Helper Outputs/<YYYY-MM-DD> <kebab-slug>.md — pick a descriptive 30-60 char slug from the task content. Steph deliberately doesn't track where files go; Helper Outputs lives inside his Obsidian vault so files show up automatically in his sidebar + indexer. Scoped paths if explicitly directed elsewhere: ~/Desktop/Claude Cowork/, ~/clicky-plus/, /tmp/. Anything outside is rejected. 1MB max per write.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute file path. Parent directories are created if missing."],
                        "content": ["type": "string", "description": "Full text content of the file."],
                        "mode": [
                            "type": "string",
                            "enum": ["write", "append"],
                            "description": "write = overwrite or create new (default). append = add content to the end of an existing file (creates if missing)."
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ],
            [
                "name": "copy_to_clipboard",
                "description": "Copy the given text to Steph's macOS clipboard so he can paste it directly into Slack, Gmail, iMessage, or any other app. Use this whenever the task is 'draft a reply' / 'draft a Slack message' / 'draft an email' — write the polished text to the clipboard so Steph can ⌘V into the conversation. PAIR THIS with write_file so the draft is also archived in Helper Outputs (clipboard is volatile; the file is the record). After calling, end your response with a short note like 'Drafted reply copied to clipboard — paste into <#channel-or-recipient>. Archived at: <path>'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "Text to place on the clipboard. Should be the final, ready-to-send version — no preamble, no markdown frontmatter, no surrounding quotes."]
                    ],
                    "required": ["content"]
                ]
            ],
            [
                "name": "append_to_inbox",
                "description": "Append a timestamped checkbox bullet to Steph's Obsidian Idea Inbox (~/Desktop/Claude Cowork/Obsidian/Steph Vault/Inbox/Idea Inbox.md). Use when you generate a note worth capturing that isn't directly a task. Format: '- [ ] <note> — *captured <ISO timestamp> via helper*'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string", "description": "The note text. Keep it under 200 chars; longer ideas should go in write_file as their own doc."]
                    ],
                    "required": ["note"]
                ]
            ],
            // v15p4av (2026-05-24): Tier 3 — cross-tool MCPs via worker.
            [
                "name": "search_meetings",
                "description": "Search Steph's Fireflies meetings by keyword. Returns matching meetings with id, title, date, attendees. Use for any 'what did we discuss', 'who said X', 'action items from Y meeting' question. PRO TIP: start with the most distinctive keyword; if zero results, broaden (e.g. 'retail 247' → '247' → 'retail').",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "keyword": ["type": "string", "description": "Search keyword (single word or phrase)."],
                        "from_date": ["type": "string", "description": "Optional ISO date filter, e.g. 2026-05-01."],
                        "to_date": ["type": "string", "description": "Optional ISO date filter, e.g. 2026-05-24."],
                        "limit": ["type": "integer", "description": "Max meetings (default 10)."]
                    ],
                    "required": ["keyword"]
                ]
            ],
            [
                "name": "read_meeting_summary",
                "description": "Fetch the auto-generated summary + action items for a specific Fireflies meeting. CHEAP — try this BEFORE read_meeting_transcript. The summary usually covers what was discussed at a high level.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "meeting_id": ["type": "string", "description": "Fireflies meeting ID (ULID format, starts with '01')."]
                    ],
                    "required": ["meeting_id"]
                ]
            ],
            [
                "name": "read_meeting_transcript",
                "description": "Fetch the verbatim transcript of a Fireflies meeting. EXPENSIVE — always pass `search_within` to grep for a keyword rather than pulling the full transcript. A 60-min meeting is thousands of sentences.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "meeting_id": ["type": "string", "description": "Fireflies meeting ID (ULID, starts with '01')."],
                        "search_within": ["type": "string", "description": "Required: keyword to grep within the transcript. Returns matching lines with context."],
                        "context_sentences": ["type": "integer", "description": "Sentences of context around each match (default 2)."]
                    ],
                    "required": ["meeting_id", "search_within"]
                ]
            ],
            [
                "name": "list_recent_meetings",
                "description": "List Steph's most recent Fireflies meetings. Use when search_meetings returns nothing and you need to find a meeting by date/counterparty instead of keyword.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max meetings to return (default 10, max 30)."]
                    ]
                ]
            ],
            [
                "name": "search_slack",
                "description": "Search Steph's Slack (Glamnetic workspace). Returns matching messages with channel, user, ts, text. Use for 'what did X say in Slack', 'find the message about Y', etc.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Slack search query. Supports Slack search operators like 'from:@user' or 'in:#channel'."],
                        "max_results": ["type": "integer", "description": "Max messages (default 10)."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "read_slack_thread",
                "description": "Fetch a Slack thread's replies given its channel_id + thread_ts (returned by search_slack).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "channel_id": ["type": "string"],
                        "thread_ts": ["type": "string"],
                        "max_replies": ["type": "integer", "description": "Default 20."]
                    ],
                    "required": ["channel_id", "thread_ts"]
                ]
            ],
            [
                "name": "list_unread_slack",
                "description": "List Steph's unread Slack channels + DMs with recent message previews. Use for 'what's in my Slack inbox' / 'catch me up on Slack'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "types": ["type": "string", "description": "Optional filter: 'channels', 'dms', or 'all' (default)."],
                        "max_channels": ["type": "integer", "description": "Max channels to scan (default 20)."],
                        "messages_per_channel": ["type": "integer", "description": "Recent messages per channel (default 3)."]
                    ]
                ]
            ],
            [
                "name": "search_gmail",
                "description": "Search Steph's Gmail. Returns matching threads with subject, sender, snippet, thread_id. Supports Gmail search operators like 'from:', 'subject:', 'has:attachment'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Gmail search query."],
                        "max_results": ["type": "integer", "description": "Max threads (default 10)."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "read_email_thread",
                "description": "Read full content of a Gmail thread by its thread_id (returned by search_gmail).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "thread_id": ["type": "string"]
                    ],
                    "required": ["thread_id"]
                ]
            ],
            [
                "name": "list_calendar_events",
                "description": "List Steph's upcoming calendar events. Use for 'what's on my calendar', 'am I free Tuesday', 'when's my next meeting with X'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "time_range": ["type": "string", "description": "today / tomorrow / this_week / next_week / next_7_days (default) / next_30_days"],
                        "query": ["type": "string", "description": "Optional event-title filter."],
                        "max_results": ["type": "integer", "description": "Default 15."]
                    ]
                ]
            ],
            [
                "name": "find_next_event",
                "description": "Fetch the very next upcoming calendar event on Steph's primary calendar. Use for 'what's next on my schedule'.",
                "input_schema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "update_roadmap_item",
                "description": "Modify an item in Steph's Leverage Roadmap.md. STEP 1 (REQUIRED unless you already read the Roadmap in this session): call read_file on ~/Desktop/Claude Cowork/Obsidian/Steph Vault/Leverage/Roadmap.md FIRST to get the exact bold item name. STEP 2: call this tool with the exact bold name (or clear substring) plus the operation (ship/park/keep/kill/replace_text/append_note/restore). Returns status + resolved item name.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "item_name": ["type": "string", "description": "Bold name of the item (or a clear substring). Fuzzy-matched against open sections (Active + Inbox Sweep)."],
                        "operation": [
                            "type": "string",
                            "enum": ["ship", "park", "keep", "kill", "replace_text", "append_note", "restore"],
                            "description": "ship: move to Done dated today. park: move to Parked (provide reason). keep: Done as 'kept'. kill: Done as killed (provide reason). replace_text: find/replace within the item body. append_note: add a sub-bullet. restore: bring back from Done/Parked."
                        ],
                        "reason": ["type": "string", "description": "Short reason. Required for park and kill; optional for ship and keep."],
                        "find_text": ["type": "string", "description": "For replace_text only: exact substring within the item to find."],
                        "replace_with": ["type": "string", "description": "For replace_text only: replacement substring. Empty deletes find_text."],
                        "append_text": ["type": "string", "description": "For append_note only: the sub-bullet body."]
                    ],
                    "required": ["item_name", "operation"]
                ]
            ]
        ]
    }

    // MARK: - Tool execution

    private func executeTool(name: String, input: [String: Any]) async -> String {
        switch name {
        case "read_file":
            return execReadFile(path: input["path"] as? String ?? "")
        case "list_dir":
            return execListDir(path: input["path"] as? String ?? "")
        case "bash":
            return await execBash(command: input["command"] as? String ?? "")
        case "write_file":
            return execWriteFile(
                path: input["path"] as? String ?? "",
                content: input["content"] as? String ?? "",
                mode: (input["mode"] as? String) ?? "write"
            )
        case "append_to_inbox":
            return Self.appendToIdeaInbox(note: input["note"] as? String ?? "")
        case "copy_to_clipboard":
            return Self.execCopyToClipboard(content: input["content"] as? String ?? "")
        case "update_roadmap_item":
            return await execUpdateRoadmapItem(input: input)
        // v15p4av: Tier 3 cross-tool MCPs via the Cloudflare worker.
        case "search_meetings":
            var body: [String: Any] = ["keyword": input["keyword"] as? String ?? ""]
            if let from = input["from_date"] as? String, !from.isEmpty { body["from_date"] = from }
            if let to = input["to_date"] as? String, !to.isEmpty { body["to_date"] = to }
            if let lim = input["limit"] as? Int { body["limit"] = lim }
            return await callWorker(path: "/fireflies/search", body: body)
        case "read_meeting_summary":
            return await callWorker(path: "/fireflies/read-summary", body: ["meeting_id": input["meeting_id"] as? String ?? ""])
        case "read_meeting_transcript":
            var body: [String: Any] = ["meeting_id": input["meeting_id"] as? String ?? ""]
            if let kw = input["search_within"] as? String, !kw.isEmpty { body["search_within"] = kw }
            if let ctx = input["context_sentences"] as? Int { body["context_sentences"] = ctx }
            return await callWorker(path: "/fireflies/read-transcript", body: body)
        case "list_recent_meetings":
            var body: [String: Any] = [:]
            if let lim = input["limit"] as? Int { body["limit"] = lim }
            return await callWorker(path: "/fireflies/list-recent", body: body)
        case "search_slack":
            var body: [String: Any] = ["query": input["query"] as? String ?? ""]
            if let mr = input["max_results"] as? Int { body["max_results"] = mr }
            return await callWorker(path: "/slack/search", body: body)
        case "read_slack_thread":
            var body: [String: Any] = [
                "channel_id": input["channel_id"] as? String ?? "",
                "thread_ts": input["thread_ts"] as? String ?? ""
            ]
            if let mr = input["max_replies"] as? Int { body["max_replies"] = mr }
            return await callWorker(path: "/slack/read-thread", body: body)
        case "list_unread_slack":
            var body: [String: Any] = [:]
            if let t = input["types"] as? String, !t.isEmpty { body["types"] = t }
            if let mc = input["max_channels"] as? Int { body["max_channels"] = mc }
            if let mpc = input["messages_per_channel"] as? Int { body["messages_per_channel"] = mpc }
            return await callWorker(path: "/slack/unread-inbox", body: body)
        case "search_gmail":
            var body: [String: Any] = ["query": input["query"] as? String ?? ""]
            if let mr = input["max_results"] as? Int { body["max_results"] = mr }
            return await callWorker(path: "/gmail/search", body: body)
        case "read_email_thread":
            return await callWorker(path: "/gmail/read-thread", body: ["thread_id": input["thread_id"] as? String ?? ""])
        case "list_calendar_events":
            var body: [String: Any] = [
                "time_range": (input["time_range"] as? String) ?? "next_7_days"
            ]
            if let q = input["query"] as? String, !q.isEmpty { body["query"] = q }
            if let mr = input["max_results"] as? Int { body["max_results"] = mr }
            return await callWorker(path: "/calendar/list-events", body: body)
        case "find_next_event":
            return await callWorker(path: "/calendar/find-next", body: [:])
        default:
            // web_search is handled server-side by Anthropic; we shouldn't
            // see it here. Anything else is unknown.
            return "ERROR: unknown tool '\(name)'"
        }
    }

    /// Normalize a path string by auto-correcting hallucinated user
    /// directories. The helper has a habit of inventing usernames
    /// (e.g. /Users/steph/) instead of using the real one. We detect
    /// /Users/<wrong>/ paths and rewrite them to /Users/<real>/.
    /// v15p4as (2026-05-24).
    private static func normalizeUserPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let realHome = NSString("~").expandingTildeInPath  // /Users/stephenpierson
        if expanded.hasPrefix("/Users/") && !expanded.hasPrefix(realHome + "/") && expanded != realHome {
            // Rewrite /Users/<wrong>/rest → /Users/<real>/rest
            let afterUsers = String(expanded.dropFirst("/Users/".count))
            if let nextSlash = afterUsers.firstIndex(of: "/") {
                let rest = String(afterUsers[afterUsers.index(after: nextSlash)...])
                return realHome + "/" + rest
            }
        }
        return expanded
    }

    private func execReadFile(path: String) -> String {
        let home = NSString("~").expandingTildeInPath
        let resolved = Self.normalizeUserPath(path)
        guard resolved.hasPrefix(home) || resolved.hasPrefix("/tmp") else {
            return "ERROR: path outside home directory: \(resolved)"
        }
        do {
            let content = try String(contentsOfFile: resolved, encoding: .utf8)
            // Cap at 80KB to avoid blowing the context window.
            if content.count > 80_000 {
                return String(content.prefix(80_000)) + "\n\n[...truncated, file has \(content.count) total chars]"
            }
            return content
        } catch {
            return "ERROR reading \(resolved): \(error.localizedDescription)"
        }
    }

    private func execListDir(path: String) -> String {
        let resolved = Self.normalizeUserPath(path)
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: resolved)
            let labeled = entries.sorted().map { name -> String in
                var isDir: ObjCBool = false
                let full = (resolved as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                return isDir.boolValue ? "\(name)/" : name
            }
            return labeled.joined(separator: "\n")
        } catch {
            return "ERROR listing \(resolved): \(error.localizedDescription)"
        }
    }

    private func execBash(command: String) async -> String {
        // Reject obvious writes. Belt-and-suspenders with the system prompt's
        // "read-only by convention" guidance.
        let forbidden = ["rm ", "rm\\", "mv ", "cp ", " > ", " >> ", "tee ", "chmod ", "chown ", "dd ", "mkfs", "sudo "]
        let lower = command.lowercased()
        for pattern in forbidden {
            if lower.contains(pattern) {
                return "ERROR: bash write/destructive operator detected ('\(pattern.trimmingCharacters(in: .whitespaces))'). Use a read-only command. For writes, ask Steph to add write_file in Phase 2."
            }
        }
        return await withCheckedContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", command]
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr
            task.terminationHandler = { _ in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                var combined = out
                if !err.isEmpty { combined += "\n[stderr]\n\(err)" }
                if combined.count > 40_000 {
                    combined = String(combined.prefix(40_000)) + "\n\n[...truncated, output had \(combined.count) total chars]"
                }
                cont.resume(returning: combined.isEmpty ? "(no output)" : combined)
            }
            do { try task.run() } catch {
                cont.resume(returning: "ERROR launching bash: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Tier 3 cross-tool MCPs (v15p4av, 2026-05-24)
    //
    // Helper routes through the Cloudflare worker for tools that need
    // cloud-side credentials (Fireflies, Slack, Gmail, Calendar). Same
    // worker Marin uses — no separate auth surface.

    /// HTTP POST to the Cloudflare worker. Returns either the JSON-
    /// encoded response (truncated to 8KB for helper context budget)
    /// or a structured error string.
    private func callWorker(path: String, body: [String: Any]) async -> String {
        guard let url = URL(string: workerBaseURL + path) else {
            return "ERROR: bad worker URL for \(path)"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return "ERROR: could not encode worker body: \(error.localizedDescription)"
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                return "ERROR: worker \(path) returned \(http.statusCode): \(String(body.prefix(300)))"
            }
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            if text.count > 8000 {
                return String(text.prefix(8000)) + "\n\n[...truncated, response had \(text.count) total chars]"
            }
            return text
        } catch {
            return "ERROR calling worker \(path): \(error.localizedDescription)"
        }
    }

    // MARK: - Tier 2 write tools (v15p4af)

    /// Allowed roots for write_file. Anything outside these is rejected.
    private static let writeAllowedRoots: [String] = [
        NSString("~/Desktop/Claude Cowork").expandingTildeInPath,
        NSString("~/clicky-plus").expandingTildeInPath,
        "/tmp"
    ]

    /// v15p4aj (2026-05-24): canonical save destination lives INSIDE
    /// the Obsidian vault so files show up in Steph's Obsidian sidebar
    /// + indexer automatically. Single flat folder, files named
    /// `<YYYY-MM-DD> <kebab-slug>.md`. Easy to scan chronologically,
    /// easy to grep by name, no nested folders to dig through.
    static let helperOutputsDir: String = NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Helper Outputs").expandingTildeInPath

    /// Ensure the Helper Outputs directory exists. Called once at agent
    /// init so the directory is ready before the first write attempt.
    static func ensureHelperOutputsDirectory() {
        try? FileManager.default.createDirectory(
            atPath: helperOutputsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Maximum bytes per write_file call. Guards against runaway writes.
    private static let writeMaxBytes: Int = 1_000_000

    private func execWriteFile(path: String, content: String, mode: String) -> String {
        let resolved = Self.normalizeUserPath(path)
        guard Self.writeAllowedRoots.contains(where: { resolved.hasPrefix($0) }) else {
            return "ERROR: writes are scoped to ~/Desktop/Claude Cowork/, ~/clicky-plus/, and /tmp/. Refused path: \(resolved)"
        }
        let bytes = content.utf8.count
        if bytes > Self.writeMaxBytes {
            return "ERROR: content too large (\(bytes) bytes, limit \(Self.writeMaxBytes)). Split into multiple files or trim."
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return "ERROR creating parent dir \(parentDir): \(error.localizedDescription)"
            }
        }
        let normalizedMode = mode.lowercased()
        if normalizedMode == "append" && FileManager.default.fileExists(atPath: resolved) {
            do {
                let existing = try String(contentsOfFile: resolved, encoding: .utf8)
                let joiner = existing.hasSuffix("\n") ? "" : "\n"
                let newContent = existing + joiner + content
                try newContent.write(toFile: resolved, atomically: true, encoding: .utf8)
                return "OK: appended \(bytes) bytes to \(resolved) (file now \(newContent.utf8.count) bytes)"
            } catch {
                return "ERROR appending to \(resolved): \(error.localizedDescription)"
            }
        }
        // write (default) or append-on-missing-file: just write content.
        do {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            return "OK: wrote \(bytes) bytes to \(resolved)"
        } catch {
            return "ERROR writing \(resolved): \(error.localizedDescription)"
        }
    }

    /// v15p4as: extracted as static so Marin can call it directly too
    /// (she gets her own append_to_inbox tool — no need to delegate
    /// short idea-captures to the helper).
    static func appendToIdeaInbox(note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ERROR: append_to_inbox requires non-empty 'note'"
        }
        let inboxPath = NSString("~/Desktop/Claude Cowork/Obsidian/Steph Vault/Inbox/Idea Inbox.md").expandingTildeInPath
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "- [ ] \(trimmed) — *captured \(ts) via helper*\n"
        let parentDir = (inboxPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
        if FileManager.default.fileExists(atPath: inboxPath) {
            do {
                let existing = try String(contentsOfFile: inboxPath, encoding: .utf8)
                let joiner = existing.hasSuffix("\n") ? "" : "\n"
                let updated = existing + joiner + entry
                try updated.write(toFile: inboxPath, atomically: true, encoding: .utf8)
                return "OK: appended to Idea Inbox"
            } catch {
                return "ERROR appending to inbox: \(error.localizedDescription)"
            }
        } else {
            do {
                let header = "# Idea Inbox\n\n"
                try (header + entry).write(toFile: inboxPath, atomically: true, encoding: .utf8)
                return "OK: created Idea Inbox with first entry"
            } catch {
                return "ERROR creating inbox: \(error.localizedDescription)"
            }
        }
    }

    /// v15p4ax (2026-05-25): place text on the macOS clipboard so
    /// Steph can ⌘V it into Slack, Mail, iMessage, etc. Static so
    /// it can be called outside the actor isolation context.
    static func execCopyToClipboard(content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ERROR: copy_to_clipboard requires non-empty 'content'"
        }
        // NSPasteboard.general is safe from any thread for simple
        // string writes. clearContents() must precede setString.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
        let charCount = trimmed.count
        let preview = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return "OK: copied \(charCount) chars to clipboard. Preview: \(preview)"
    }

    private func execUpdateRoadmapItem(input: [String: Any]) async -> String {
        let itemName = (input["item_name"] as? String) ?? ""
        let operation = (input["operation"] as? String) ?? ""
        let reason = input["reason"] as? String
        let findText = input["find_text"] as? String
        let replaceWith = input["replace_with"] as? String
        let appendText = input["append_text"] as? String
        guard !itemName.isEmpty, !operation.isEmpty else {
            return "ERROR: update_roadmap_item requires non-empty item_name and operation"
        }
        let result: [String: Any] = await MainActor.run {
            MarinResearchTools.updateLeverageRoadmapItem(
                name: itemName,
                operation: operation,
                reason: reason,
                findText: findText,
                replaceWith: replaceWith,
                appendText: appendText
            )
        }
        // Serialize the result dict to a readable string for the helper's
        // next turn. Compact JSON keeps tokens low.
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(result)"
    }

    // MARK: - Cost cap

    private func checkSpendCap() throws {
        let defaults = UserDefaults.standard
        let capCents = defaults.object(forKey: spendCapCentsKey) as? Int ?? 500  // default $5/day
        rolloverIfNewDay()
        let spentCents = defaults.integer(forKey: spendCentsTodayKey)
        if spentCents >= capCents {
            throw HelperError.spendCapReached(spentCents: spentCents, capCents: capCents)
        }
    }

    private func recordSpend(usd: Double) {
        rolloverIfNewDay()
        let defaults = UserDefaults.standard
        let priorCents = defaults.integer(forKey: spendCentsTodayKey)
        let addCents = Int((usd * 100).rounded())
        defaults.set(priorCents + addCents, forKey: spendCentsTodayKey)
    }

    private func rolloverIfNewDay() {
        let defaults = UserDefaults.standard
        let today = ISO8601DateFormatter.dateOnly.string(from: Date())
        if defaults.string(forKey: spendDateKey) != today {
            defaults.set(0, forKey: spendCentsTodayKey)
            defaults.set(today, forKey: spendDateKey)
        }
    }

    // MARK: - Helpers

    private func resolveAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return UserDefaults.standard.string(forKey: apiKeyDefaultsKey)
    }

    private func buildUserMessage(task: String, context: String?) -> String {
        var s = "Task: \(task)"
        if let ctx = context, !ctx.isEmpty {
            s += "\n\nContext from Marin:\n\(ctx)"
        }
        return s
    }

    private func extractText(from blocks: [[String: Any]]) -> String {
        var parts: [String] = []
        for block in blocks {
            if (block["type"] as? String) == "text", let text = block["text"] as? String {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ obj: Any, max: Int) -> String {
        let s = "\(obj)"
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private func diag(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [helper] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: diagPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: diagPath))
            }
        }
    }

    private nonisolated func postStateChange(active: Bool, taskPreview: String?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .marinHelperStateChanged,
                object: nil,
                userInfo: [
                    "active": active,
                    "taskPreview": taskPreview ?? ""
                ]
            )
        }
    }
}

// MARK: - Errors

enum HelperError: Error, LocalizedError {
    case missingAPIKey
    case spendCapReached(spentCents: Int, capCents: Int)
    case apiStatus(Int, String)
    case malformedResponse
    case unexpectedStopReason(String)
    case exceededMaxIterations

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key missing. Set UserDefaults key 'clicky.helper.anthropicApiKey' or env var ANTHROPIC_API_KEY."
        case .spendCapReached(let spent, let cap):
            return "Daily spend cap reached: $\(Double(spent)/100.0) of $\(Double(cap)/100.0). Resets at midnight local time. Ask Steph if you need to raise the cap."
        case .apiStatus(let code, let body):
            return "Anthropic API returned \(code): \(body)"
        case .malformedResponse:
            return "Anthropic response could not be parsed."
        case .unexpectedStopReason(let r):
            return "Unexpected stop_reason '\(r)'."
        case .exceededMaxIterations:
            return "Helper exceeded max iterations (20). Likely stuck in a tool-call loop."
        }
    }
}

// MARK: - Date formatter

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
