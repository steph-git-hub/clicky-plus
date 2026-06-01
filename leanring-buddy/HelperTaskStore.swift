//
//  HelperTaskStore.swift
//  leanring-buddy
//
//  v15p4u (2026-05-23): @MainActor ObservableObject holding all
//  HelperTask state. Single source of truth; both the floating icon
//  column and the notch-expanded task-list panel subscribe to this.
//
//  Persistence: JSON file at
//    ~/Desktop/Claude Cowork/Clicky+ State/helper-tasks.json
//  That location is inside Steph's Cowork folder, which every Cowork
//  project has access to by default — so a Cowork session can read
//  helper history for debugging or context without extra plumbing.
//
//  On launch: load persisted tasks. Any task with status .running gets
//  promoted to .abandoned (we can't resume HTTP requests across app
//  restarts). Tasks older than 7 days are pruned to keep the file lean.

import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class HelperTaskStore: ObservableObject {
    static let shared = HelperTaskStore()

    @Published private(set) var tasks: [HelperTask] = []

    private let persistenceURL: URL = {
        let cowork = NSString("~/Desktop/Claude Cowork/Clicky+ State").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: cowork, withIntermediateDirectories: true)
        return URL(fileURLWithPath: cowork).appendingPathComponent("helper-tasks.json")
    }()

    private let pruneOlderThanDays: Int = 7

    private init() {
        load()
    }

    // MARK: - Public API

    /// Add a new task. Returns the task (pre-run, status = .queued).
    func add(_ task: HelperTask) {
        tasks.insert(task, at: 0)
        persist()
    }

    /// Mark task as started.
    func markRunning(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = .running
        tasks[idx].startedAt = Date()
        persist()
    }

    /// Mark task as completed with a final result.
    /// v15p4x: also persists the full conversation history so follow-ups
    /// can resume the same agent loop.
    func markCompleted(id: String, result: String, messages: [[String: Any]]?, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = .completed
        tasks[idx].result = result
        tasks[idx].completedAt = Date()
        tasks[idx].inputTokens += inputTokens
        tasks[idx].outputTokens += outputTokens
        tasks[idx].costUSD += costUSD
        tasks[idx].isRead = false
        if let messages, let data = HelperTask.encodeMessages(messages) {
            tasks[idx].messagesJSON = data
        }
        persist()
        playCompletionCue()
    }

    /// Prepare a follow-up turn: appends `userMessage` to the task's
    /// stored message history, increments turnCount, sets status back
    /// to .queued so the floating column's spinner re-engages, and
    /// returns the full updated messages array for the agent loop.
    /// Returns nil if the task can't be followed up (missing, not in
    /// completed state).
    func prepareFollowUp(id: String, userMessage: String) -> [[String: Any]]? {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        guard tasks[idx].status == .completed else { return nil }
        var msgs = tasks[idx].loadMessages()
        msgs.append(["role": "user", "content": userMessage])
        tasks[idx].messagesJSON = HelperTask.encodeMessages(msgs)
        tasks[idx].turnCount += 1
        tasks[idx].status = .queued
        tasks[idx].isRead = false
        persist()
        return msgs
    }

    /// Play the audio cue when a task completes, if the user has them
    /// enabled. v15p4u: placeholder uses "Tink" — polish session swaps
    /// for a proper Clicky-themed cue tied into the sound-effects picker
    /// (project_clicky_sound_effects_may14).
    static let audioCueDefaultsKey = "clicky.helper.audioCueEnabled"
    private func playCompletionCue() {
        // Default to ON if the key has never been set.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.audioCueDefaultsKey) == nil {
            defaults.set(true, forKey: Self.audioCueDefaultsKey)
        }
        guard defaults.bool(forKey: Self.audioCueDefaultsKey) else { return }
        NSSound(named: "Tink")?.play()
    }

    /// Mark task as failed with an error message.
    func markFailed(id: String, error: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = .failed
        tasks[idx].errorMessage = error
        tasks[idx].completedAt = Date()
        tasks[idx].isRead = false
        persist()
    }

    /// Mark a task as read (when the user opens its card / expanded view).
    func markRead(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }), !tasks[idx].isRead else { return }
        tasks[idx].isRead = true
        persist()
    }

    /// Dismiss a task FROM THE FLOATING COLUMN ONLY. The task stays in
    /// HelperTaskStore.tasks so the notch history still shows it.
    /// History is sacred — we never actually delete tasks from the
    /// store via the UI. v15p4ai (2026-05-24).
    func dismiss(id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].dismissedFromColumn = true
        persist()
    }

    /// Clear all dismissed/completed/failed/abandoned tasks. Running ones stay.
    func clearAllResolved() {
        tasks.removeAll(where: { $0.status != .queued && $0.status != .running })
        persist()
    }

    // MARK: - Computed views

    /// Tasks currently active (queued or running). Capped at 5 for the
    /// floating column; the rest spill into the notch panel.
    var activeTasks: [HelperTask] {
        tasks.filter { $0.status == .queued || $0.status == .running }
    }

    /// Recently completed tasks (any status that isn't queued/running),
    /// most recent first.
    var resolvedTasks: [HelperTask] {
        tasks.filter { $0.status != .queued && $0.status != .running }
    }

    /// Count of completed tasks the user hasn't opened yet.
    var unreadCount: Int {
        tasks.filter { $0.status == .completed && !$0.isRead }.count
    }

    /// Floating-column slots: active + any task created in the last
    /// hour, EXCLUDING those the user has explicitly dismissed from
    /// the column. Dismiss only hides from the column — the notch
    /// history still shows everything. v15p4ai (2026-05-24).
    var floatingSlots: [HelperTask] {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let recent = tasks.filter { task in
            if task.dismissedFromColumn { return false }
            // Active tasks always show
            if task.status == .queued || task.status == .running { return true }
            // Recent finished tasks (completed/failed/abandoned within 1hr) show
            let referenceDate = task.completedAt ?? task.createdAt
            return referenceDate >= oneHourAgo
        }
        return Array(recent.prefix(5))
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("[helper-store] persist failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([HelperTask].self, from: data)

            // Promote any "running" tasks to "abandoned" — they were
            // mid-flight when Clicky+ quit and can't be resumed.
            for i in loaded.indices where loaded[i].status == .running || loaded[i].status == .queued {
                loaded[i].status = .abandoned
                loaded[i].errorMessage = "Clicky+ quit before this task finished. Re-run if you still need it."
                loaded[i].completedAt = Date()
            }

            // Prune anything older than N days.
            let cutoff = Date().addingTimeInterval(-Double(pruneOlderThanDays) * 86_400)
            loaded.removeAll { $0.createdAt < cutoff }

            tasks = loaded
            persist()
        } catch {
            NSLog("[helper-store] load failed: \(error)")
        }
    }
}
