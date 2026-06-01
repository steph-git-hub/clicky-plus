//
//  NotchHelperHistoryPanel.swift
//  leanring-buddy
//
//  v15p4w (2026-05-23): notch-anchored panel that shows the full helper
//  task history when Steph clicks the notch pill. Sibling to the
//  floating top-right icon column, same HelperTaskStore.
//
//  v15p4w-revert: restored as a separate floating panel for the build
//  phase. The chrome-merge "notch expands naturally" version is design-
//  phase work and tracked in project_clicky_helper_ui_polish.md.
//
//  Includes follow-up input on expanded completed tasks — submits a new
//  helper task with the prior task's result as context.

import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - Panel manager (separate floating window — design polish later)

@MainActor
final class NotchHelperHistoryPanel: NSObject {
    static let shared = NotchHelperHistoryPanel()

    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private(set) var isVisible: Bool = false

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { create() }
        guard let panel else { return }
        position()
        panel.orderFrontRegardless()
        isVisible = true
        installClickOutsideMonitor()
    }

    func hide() {
        guard isVisible, let panel else { return }
        panel.orderOut(nil)
        isVisible = false
        removeClickOutsideMonitor()
    }

    private func create() {
        // v15p4ax (2026-05-25): use KeyableHelperPanel so the
        // follow-up TextField can receive keyboard input. Without
        // canBecomeKey, the user can't type and the submit button
        // (conditional on non-empty text) never appears.
        let p = KeyableHelperPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // v15p4ax: only become key when TextField is clicked.
        p.becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: NotchHelperHistoryView())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
    }

    private func position() {
        guard let panel else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 380
        let height: CGFloat = 480
        let x = visible.midX - (width / 2)
        let y = visible.maxY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)
    }

    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

/// SwiftUI view used inside the panel. Includes follow-up input on
/// expanded completed tasks.
struct NotchHelperHistoryView: View {
    @StateObject private var store = HelperTaskStore.shared
    @State private var selectedId: String? = nil
    @State private var followUpDrafts: [String: String] = [:]   // taskId → in-progress follow-up text

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Helper history")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("\(store.tasks.count) total")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.1)

            // List
            if store.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(minHeight: 200)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 32)
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.3))
            Text("No helper tasks yet")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            Text("Ask Marin to research, draft, or grep something.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var taskList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(groupedTasks(), id: \.label) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.label.uppercased())
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                        ForEach(group.items) { task in
                            TaskRow(
                                task: task,
                                isSelected: selectedId == task.id,
                                followUpDraft: Binding(
                                    get: { followUpDrafts[task.id] ?? "" },
                                    set: { followUpDrafts[task.id] = $0 }
                                ),
                                onTap: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if selectedId == task.id {
                                            selectedId = nil
                                        } else {
                                            selectedId = task.id
                                            store.markRead(id: task.id)
                                        }
                                    }
                                },
                                onSubmitFollowUp: { text in
                                    submitFollowUp(parentTask: task, text: text)
                                },
                                onDismiss: {
                                    store.dismiss(id: task.id)
                                    if selectedId == task.id { selectedId = nil }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// Follow up on a task — RESUMES THE SAME AGENT LOOP (v15p4x). The
    /// helper sees the full prior conversation history, including its
    /// own tool calls and answer. Cheaper than spawning a new task
    /// (no repeated file reads) and gives the agent true continuity.
    private func submitFollowUp(parentTask: HelperTask, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[helper-ui] notch-panel follow-up click taskId=\(parentTask.id) trimmedLen=\(trimmed.count)")
        guard !trimmed.isEmpty else { return }
        Task {
            NSLog("[helper-ui] notch-panel calling followUp")
            await MarinHelperSubAgent.shared.followUp(taskId: parentTask.id, userMessage: trimmed)
            await MainActor.run {
                followUpDrafts[parentTask.id] = ""
            }
        }
    }

    private struct Group { let label: String; let items: [HelperTask] }

    private func groupedTasks() -> [Group] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        var running: [HelperTask] = []
        var today: [HelperTask] = []
        var yesterday: [HelperTask] = []
        var earlier: [HelperTask] = []

        for task in store.tasks {
            if task.status == .queued || task.status == .running { running.append(task); continue }
            let ref = task.completedAt ?? task.createdAt
            if ref >= startOfToday { today.append(task) }
            else if ref >= startOfYesterday { yesterday.append(task) }
            else { earlier.append(task) }
        }

        var groups: [Group] = []
        if !running.isEmpty { groups.append(Group(label: "Running", items: running)) }
        if !today.isEmpty { groups.append(Group(label: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(Group(label: "Yesterday", items: yesterday)) }
        if !earlier.isEmpty { groups.append(Group(label: "Earlier", items: earlier)) }
        return groups
    }
}

private struct TaskRow: View {
    let task: HelperTask
    let isSelected: Bool
    @Binding var followUpDraft: String
    let onTap: () -> Void
    let onSubmitFollowUp: (String) -> Void
    let onDismiss: () -> Void
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(task.category.color(for: task.id))
                        .frame(width: 22, height: 22)
                    Image(systemName: task.category.iconName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
                // v15p4ba (2026-05-25): prefer Marin's crisp 3-5 word
                // summary when available; falls back to truncated task
                // text. The full task text shows in expandedDetail
                // when this row is selected.
                Text((task.summary?.isEmpty == false) ? task.summary! : task.shortTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(task.isRead ? 0.7 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                statusBadge
                if task.status == .completed && !task.isRead {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if isSelected {
                expandedDetail
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // v15p4ba (2026-05-25): show the FULL task request at the
            // top of the expanded detail. The row title shows the
            // summary (or truncated task) for scannability; once a row
            // is selected, Steph needs to read the whole request to
            // understand what was asked. Selectable so he can copy it.
            VStack(alignment: .leading, spacing: 2) {
                Text("REQUEST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(task.category.color(for: task.id).opacity(0.85))
                    .tracking(0.5)
                Text(task.task)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 2)

            if let text = expandedBody {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.status == .completed ? "RESULT" : "STATUS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(0.5)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.78))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Action row + follow-up only for completed tasks with results
            if task.status == .completed, task.result != nil {
                HStack(spacing: 6) {
                    Button(action: { copyResult() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(MiniBtn())
                    Button(action: onDismiss) {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(MiniBtn())
                    Spacer()
                }

                // Follow-up input
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    TextField("Follow up…", text: $followUpDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.95))
                        .focused($followUpFocused)
                        .lineLimit(1...4)
                        .onSubmit { sendFollowUp() }
                    if !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: sendFollowUp) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(task.category.color(for: task.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                )
            } else if task.status == .failed || task.status == .abandoned {
                HStack(spacing: 6) {
                    Button(action: onDismiss) {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(MiniBtn())
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch task.status {
            case .queued: return ("QUEUED", .white.opacity(0.4))
            case .running: return ("RUNNING", .blue.opacity(0.7))
            case .completed: return ("DONE", .green.opacity(0.7))
            case .failed: return ("FAILED", .red.opacity(0.7))
            case .abandoned: return ("ABANDONED", .yellow.opacity(0.7))
            }
        }()
        return Text(label)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var expandedBody: String? {
        if let r = task.result, !r.isEmpty { return r }
        if let e = task.errorMessage { return "Error: \(e)" }
        return nil
    }

    private func sendFollowUp() {
        let trimmed = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitFollowUp(trimmed)
    }

    private func copyResult() {
        guard let r = task.result else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r, forType: .string)
    }
}

private struct MiniBtn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(.white.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
    }
}
