//
//  LocalLLMManager.swift
//  Clicky+
//
//  v16pv (2026-06-06): on-device LLM for the repunctuate stage.
//
//  Runs a Rapid-MLX server (qwen3.5-4b, 4-bit MLX) on localhost and
//  routes /repunctuate-equivalent calls to it instead of the Worker's
//  Haiku path. Benchmarked 2026-06-06 on 12 real dictations from the
//  transcript log: 8/12 byte-identical to Haiku, remaining diffs at
//  parity or better (Haiku produced a forbidden em-dash in one; local
//  followed the terminal-punctuation rule Haiku skipped in another).
//  Avg latency 0.69s local vs 1.08s Haiku — plus $0 and fully private.
//
//  ARCHITECTURE — single source of truth for the prompt:
//  The repunctuate system prompt lives ONLY in the Worker
//  (worker/src/index.ts, handleRepunctuate). At launch we fetch it via
//  POST /repunctuate {"promptOnly":true} (both variants: professional
//  and casual-messaging) and cache it in memory. If the fetch fails or
//  the local server is down, callers fall back to the Worker path —
//  exactly the pre-v16pv behavior. No prompt duplication, no drift.
//
//  SERVER LIFECYCLE — Clicky+ owns the process (Steph's call,
//  2026-06-06): spawned on app launch, terminated on app quit. If a
//  healthy server is already listening on our port (e.g. app restart
//  where the old process survived), we adopt it instead of
//  double-spawning. --gpu-memory-utilization 0.75 caps MLX memory so
//  the model (~3 GB working set) can't pressure the system (Rapid-MLX
//  issue #324: unified-memory exhaustion can kernel-panic rather than
//  OOM).
//
//  KILL SWITCH: defaults write com.stephenpierson.clickyplus
//  clicky.localLLM.enabled -bool false   (default: enabled)
//

import Foundation

final class LocalLLMManager {

    static let shared = LocalLLMManager()
    private init() {}

    // MARK: - Config

    /// Defaults kill switch. Enabled unless explicitly set false.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "clicky.localLLM.enabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "clicky.localLLM.enabled")
    }

    /// Uncommon port so we never collide with dev servers on 8000.
    private let port = 8841
    private let modelAlias = "qwen3.5-4b"
    private var serverBinary: String {
        ("~/.rapid-mlx-venv/bin/rapid-mlx" as NSString).expandingTildeInPath
    }
    private var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Mirrors the Worker's casual-messaging app set (v15p3cs). Decides
    /// which cached prompt variant a given dictation uses. Keep in sync
    /// with `casualMessagingApps` in worker/src/index.ts.
    private static let casualMessagingApps: Set<String> = [
        "Messages", "WhatsApp", "Telegram", "Signal",
    ]

    // MARK: - State

    private let stateLock = NSLock()
    private var serverProcess: Process?
    private var serverReady = false
    private var professionalPrompt: String?
    private var casualPrompt: String?

    /// True when both the server is health-checked AND the prompt cache
    /// is populated — i.e. a local repunctuate call can be attempted.
    var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serverReady && professionalPrompt != nil && casualPrompt != nil
    }

    // MARK: - Lifecycle

    /// Call once at app launch. Spawns (or adopts) the server and
    /// fetches the prompt cache. Fully async; never blocks launch.
    /// Silent on failure — local inference simply stays unavailable and
    /// every dictation takes the Worker path as before.
    func startIfEnabled(workerBaseURL: String) {
        guard Self.isEnabled else {
            print("🧠 LocalLLM: disabled via defaults — Worker path only")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: serverBinary) else {
            print("🧠 LocalLLM: binary not found at \(serverBinary) — Worker path only")
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.fetchPromptsIfNeeded(workerBaseURL: workerBaseURL)
            await self.spawnOrAdoptServer()
        }
    }

    /// Call from applicationWillTerminate. Kills the child server.
    /// (If we adopted an external server we leave it alone.)
    func stop() {
        stateLock.lock()
        let process = serverProcess
        serverProcess = nil
        serverReady = false
        stateLock.unlock()
        if let process, process.isRunning {
            process.terminate()
            print("🧠 LocalLLM: server terminated on app quit")
        }
    }

    private func spawnOrAdoptServer() async {
        // Adopt a healthy survivor (app restart) instead of double-spawn.
        if await healthCheck() {
            stateLock.lock(); serverReady = true; stateLock.unlock()
            print("🧠 LocalLLM: adopted already-running server on :\(port)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            "serve", modelAlias,
            "--port", String(port),
            "--gpu-memory-utilization", "0.75",
        ]
        // Quiet child: server logs go to a file we can inspect, not the
        // app's stdout.
        let logPath = ("~/Library/Application Support/Clicky/local-llm-server.log" as NSString)
            .expandingTildeInPath
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: logPath) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        do {
            try process.run()
        } catch {
            print("🧠 LocalLLM: failed to spawn server (\(error)) — Worker path only")
            return
        }
        stateLock.lock(); serverProcess = process; stateLock.unlock()
        print("🧠 LocalLLM: spawned \(modelAlias) server on :\(port) (pid \(process.processIdentifier))")

        // Poll health until the model is loaded (cold start after a
        // reboot can take ~20-30s; model weights are already on disk).
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await healthCheck() {
                stateLock.lock(); serverReady = true; stateLock.unlock()
                print("🧠 LocalLLM: server ready")
                return
            }
            if !process.isRunning {
                print("🧠 LocalLLM: server process exited during warmup — Worker path only (see local-llm-server.log)")
                return
            }
        }
        print("🧠 LocalLLM: server never became healthy — Worker path only")
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return true
    }

    // MARK: - Prompt cache

    /// Fetches both prompt variants from the Worker (single source of
    /// truth). No retry loop — if the network is down at launch the
    /// Worker repunctuate path is down too; next launch refetches.
    private func fetchPromptsIfNeeded(workerBaseURL: String) async {
        stateLock.lock()
        let alreadyCached = professionalPrompt != nil && casualPrompt != nil
        stateLock.unlock()
        guard !alreadyCached else { return }

        async let professional = fetchPrompt(workerBaseURL: workerBaseURL, appName: nil)
        async let casual = fetchPrompt(workerBaseURL: workerBaseURL, appName: "Messages")
        let (pro, cas) = await (professional, casual)
        guard let pro, let cas else {
            print("🧠 LocalLLM: prompt fetch failed — Worker path only")
            return
        }
        stateLock.lock()
        professionalPrompt = pro
        casualPrompt = cas
        stateLock.unlock()
        print("🧠 LocalLLM: prompt cache loaded (\(pro.count) / \(cas.count) chars)")
    }

    private func fetchPrompt(workerBaseURL: String, appName: String?) async -> String? {
        guard let url = URL(string: "\(workerBaseURL)/repunctuate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 10
        var body: [String: Any] = ["promptOnly": true]
        if let appName { body["appName"] = appName }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = parsed["prompt"] as? String, !prompt.isEmpty else {
            return nil
        }
        return prompt
    }

    // MARK: - Inference

    /// Repunctuate `rawText` on the local model. Throws when the local
    /// path is unavailable or misbehaves — the caller falls back to
    /// `repunctuateTextViaWorker` (which itself falls back to raw text).
    func repunctuate(rawText: String, appName: String?) async throws -> String {
        stateLock.lock()
        let ready = serverReady
        let isCasual = Self.casualMessagingApps.contains(appName ?? "")
        let systemPrompt = isCasual ? casualPrompt : professionalPrompt
        stateLock.unlock()

        guard ready, let systemPrompt else {
            throw NSError(
                domain: "ClickyLocalLLMError", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Local LLM not available"]
            )
        }

        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw NSError(
                domain: "ClickyLocalLLMError", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid local LLM URL"]
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Benchmarked well under 2s on real dictations; 4s means
        // something is wrong (model evicted, swap storm) — fall back.
        request.timeoutInterval = 4
        let body: [String: Any] = [
            "model": modelAlias,
            "temperature": 0,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": rawText],
            ],
            // Qwen3.5 hybrid reasoning: thinking would add seconds of
            // latency for zero benefit on a mechanical transform.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ClickyLocalLLMError", code: status,
                userInfo: [NSLocalizedDescriptionKey: "Local LLM returned status \(status)"]
            )
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(
                domain: "ClickyLocalLLMError", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Local LLM response missing content"]
            )
        }

        let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw NSError(
                domain: "ClickyLocalLLMError", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Local LLM returned empty output"]
            )
        }
        return output
    }
}
