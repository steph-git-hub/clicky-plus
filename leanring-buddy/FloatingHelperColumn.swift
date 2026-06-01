//
//  FloatingHelperColumn.swift
//  leanring-buddy
//
//  v15p4u (2026-05-23): floating icon column for Marin's helper sub-
//  agent tasks. Lives top-right of the screen, below the menu bar.
//  Shows up to 5 colored circles (one per active or recently-unread
//  task). Click an icon → expand into a card with title/preview/actions.
//
//  This file is the FUNCTIONAL ship. Visual polish (glow rings, exact
//  card aesthetic per Farza's UI, cursor-to-corner spawn animation,
//  perfected easing) is deferred to a polish session — see
//  project_clicky_helper_ui_polish.md in memory + the Farza reference
//  screenshots in ~/Desktop/Claude Cowork/Clicky+ State/
//  farza-helper-ui-reference/.
//
//  Visual properties (colors, sizes, opacities) are gathered as a
//  single `HelperColumnStyle` struct at the top of this file so the
//  polish session is "tweak these constants" not "rewrite the view."

import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - Visual constants (polish session edits these)

struct HelperColumnStyle {
    static let iconSize: CGFloat = 32
    static let iconSpacing: CGFloat = 14         // a bit more breathing room
    static let columnTopMargin: CGFloat = 36
    static let columnRightMargin: CGFloat = 14
    static let cardWidth: CGFloat = 400          // v15p4aa: was 300, too cramped
    static let cardLeftOffset: CGFloat = 56
    static let cardMaxScrollHeight: CGFloat = 440
    static let panelHeight: CGFloat = 760        // accommodates fully-expanded card + bottom shadow halo
    static let backgroundOpacity: Double = 0.78  // v15p4aa: more translucent
    static let iconBorderGlowOpacity: Double = 0.55
    static let iconEmblemGlowOpacity: Double = 0.85
    static let runningRingThickness: CGFloat = 2.0
    static let cardGlowRadius: CGFloat = 16
    static let cardGlowOpacity: Double = 0.50
    // v15p4am: halo + padding retune. SwiftUI's .blur extends visual
    // reach ~2.5× the radius beyond the source frame, not 1× as I
    // assumed in v15p4al — so the expanded halo was bleeding ~21px
    // past the icon and clipping at panel boundary. Now: smaller blur
    // (3 expanded), modest oversize (10 expanded), and generous
    // 36pt trailing padding. Visual reach ~17px, margin inside panel ~19pt.
    // v15p4ar: switched from .blur() rainbow Circle halo to .shadow()
    // halo. SwiftUI's .blur clips at the host NSWindow boundary even
    // with generous padding (offscreen-render limitation). .shadow()
    // is GPU-rendered and never clips. Trade-off: halo is single-color
    // per task (from rainbow palette) instead of full rainbow — but
    // the rainbow ring stroke + divider keep the iridescent feel.
    static let iconShadowRadiusCollapsed: CGFloat = 6
    static let iconShadowRadiusExpanded: CGFloat = 10
    static let iconShadowOpacityCollapsed: Double = 0.55
    static let iconShadowOpacityExpanded: Double = 0.80
    static let iconRingLineWidth: CGFloat = 2.4    // v15p4bc: thicker so the single-color ring reads punchy

    static let iconColumnTrailingPadding: CGFloat = 16  // v15p4ar: tight, icons flush to right edge; .shadow halo doesn't need huge margin to avoid clipping
    static let animationDuration: Double = 0.18

    // MARK: - Rainbow chrome (v15p4aj, 2026-05-24)
    //
    // Inspired by Google I/O '26 keynote chrome — soft iridescent
    // pastels in an angular gradient for icon rings, linear for card
    // borders. Each task still has its own emblem color for at-a-
    // glance distinction; the rainbow lives ONLY in the border/glow
    // chrome so the UI feels coherent across tasks.

    // v15p4bb (2026-05-25): de-washed palette. Previous "darkened
    // pastels" (v15p4ap) read as muddy against the black chrome.
    // Now: full saturation, high brightness — reads as actual
    // rainbow. Mirrors HelperTaskCategory.rainbowPalette.
    static let rainbowColors: [Color] = [
        Color(red: 1.00, green: 0.42, blue: 0.32),  // vivid coral
        Color(red: 1.00, green: 0.72, blue: 0.18),  // golden amber
        Color(red: 0.35, green: 0.88, blue: 0.45),  // bright mint
        Color(red: 0.20, green: 0.78, blue: 0.98),  // electric sky
        Color(red: 0.45, green: 0.55, blue: 1.00),  // bright periwinkle
        Color(red: 0.78, green: 0.42, blue: 1.00),  // vivid lavender
        Color(red: 1.00, green: 0.42, blue: 0.72),  // hot rose
        Color(red: 1.00, green: 0.42, blue: 0.32),  // back to coral (close the loop)
    ]

    static var rainbowAngular: AngularGradient {
        AngularGradient(gradient: Gradient(colors: rainbowColors), center: .center)
    }

    static var rainbowLinear: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: rainbowColors),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Window manager

/// v15p4ax (2026-05-25): NSPanel subclass that can become key while
/// staying nonactivating. Without this, TextFields in the panel can't
/// receive keyboard input — which is why the follow-up button never
/// fired (it only renders when followUpDraft is non-empty, but the
/// user can't type into the field if the panel isn't key).
final class KeyableHelperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingHelperColumnManager: NSObject {
    static let shared = FloatingHelperColumnManager()

    private var panel: NSPanel?
    private var storeCancellable: AnyCancellable?

    func install() {
        guard panel == nil else { return }
        let p = makePanel()
        panel = p
        positionPanel()
        p.orderFrontRegardless()

        // Reposition on screen change.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Resize panel when active/visible task count changes.
        storeCancellable = HelperTaskStore.shared.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionPanel()
            }
    }

    @objc private func screenChanged() {
        positionPanel()
    }

    private func makePanel() -> NSPanel {
        let p = KeyableHelperPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isMovable = false
        // v15p4ax: only become key when a control that needs keyboard
        // input (TextField) is clicked. Otherwise stays unfocused so
        // it doesn't steal focus from whatever Steph is doing.
        p.becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: FloatingHelperColumnView())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        return p
    }

    private func positionPanel() {
        guard let panel else { return }
        // v15p4aq (2026-05-24): hard-anchor to the built-in display
        // (MacBook screen) instead of following the cursor. The cursor-
        // following behavior was sending the panel to Sceptre when
        // Steph was working there. Built-in is the stable "always
        // there" surface — that's where the menu bar lives, that's
        // where helper tasks should live.
        let builtInScreen: NSScreen? = NSScreen.screens.first { screen in
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return CGDisplayIsBuiltin(id) != 0
            }
            return false
        }
        guard let screen = builtInScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame  // already excludes menu bar
        // v15p4v (2026-05-23): fix off-screen positioning. NSWindow origin
        // is bottom-left in screen coords, so to anchor the TOP of the
        // panel just below the menu bar, origin.y = visible.maxY - height.
        // Width accommodates the icon column + a card that expands LEFT
        // of it. Height sized for 5 icons stacked.
        // v15p4aa: panel sized to fit an expanded card + its glow shadow.
        // Width = icon column + gap + card + safety. Height fixed at
        // 620 (card can be ~480 + header + footer + 14px shadow each
        // side). Transparent regions in the panel pass clicks through
        // because Color.clear has .allowsHitTesting(false).
        let panelWidth: CGFloat = HelperColumnStyle.iconSize + HelperColumnStyle.cardLeftOffset + HelperColumnStyle.cardWidth + 48
        let panelHeight: CGFloat = HelperColumnStyle.panelHeight
        let x = visible.maxX - panelWidth - HelperColumnStyle.columnRightMargin
        let y = visible.maxY - panelHeight
        let target = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        panel.setFrame(target, display: true, animate: false)
    }
}

// MARK: - SwiftUI view

struct FloatingHelperColumnView: View {
    @StateObject private var store = HelperTaskStore.shared
    @State private var expandedId: String? = nil
    @State private var followUpDrafts: [String: String] = [:]

    var body: some View {
        // v15p4bb: collision-avoidant color map for currently-visible
        // tasks. Computed per render so it reacts to floatingSlots
        // changes. Falls back to hash-derived color if a task isn't
        // in the visible set.
        let colorMap = HelperTaskCategory.collisionAvoidantColors(for: store.floatingSlots)

        return GeometryReader { _ in
            ZStack(alignment: .topTrailing) {
                // v15p4aa: hit-testing off so empty panel regions don't
                // eat clicks that should pass through to whatever's under
                // Clicky+ (Cowork window, browser, etc.).
                Color.clear.allowsHitTesting(false)
                // Icon column (top-right)
                VStack(spacing: HelperColumnStyle.iconSpacing) {
                    ForEach(store.floatingSlots) { task in
                        TaskIcon(
                            task: task,
                            assignedColor: colorMap[task.id] ?? task.category.color(for: task.id),
                            isExpanded: expandedId == task.id,
                            onTap: {
                                withAnimation(.easeOut(duration: HelperColumnStyle.animationDuration)) {
                                    if expandedId == task.id {
                                        expandedId = nil
                                    } else {
                                        expandedId = task.id
                                        store.markRead(id: task.id)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.top, 14)
                .padding(.trailing, HelperColumnStyle.iconColumnTrailingPadding)  // v15p4al: 22pt — halo (~12px past icon when expanded) + ~10px margin so screenshots capture cleanly.
                .frame(maxWidth: .infinity, alignment: .topTrailing)

                // Expanded card (positioned LEFT of the icon column)
                if let id = expandedId, let task = store.tasks.first(where: { $0.id == id }) {
                    TaskCard(
                        task: task,
                        assignedColor: colorMap[task.id] ?? task.category.color(for: task.id),
                        followUpDraft: Binding(
                            get: { followUpDrafts[task.id] ?? "" },
                            set: { followUpDrafts[task.id] = $0 }
                        ),
                        onClose: { withAnimation { expandedId = nil } },
                        onDismiss: {
                            withAnimation { expandedId = nil }
                            store.dismiss(id: task.id)
                        },
                        onSubmitFollowUp: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            NSLog("[helper-ui] floating-card follow-up click taskId=\(task.id) trimmedLen=\(trimmed.count)")
                            guard !trimmed.isEmpty else { return }
                            Task {
                                NSLog("[helper-ui] floating-card calling followUp")
                                await MarinHelperSubAgent.shared.followUp(taskId: task.id, userMessage: trimmed)
                                await MainActor.run { followUpDrafts[task.id] = "" }
                            }
                        }
                    )
                    .frame(width: HelperColumnStyle.cardWidth)
                    .padding(.top, 12)
                    // v15p4am: card trailing padding = iconColumnTrailing
                    // + iconSize + 12pt gap, so card sits to the LEFT of
                    // the icon column with no overlap. Before this, icons
                    // landed inside the card's footprint and disappeared
                    // behind it when expanded.
                    .padding(.trailing, HelperColumnStyle.iconColumnTrailingPadding + HelperColumnStyle.iconSize + 12)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        // v15p4bd (2026-05-25): kill AppKit focus rings on all buttons
        // in this panel. v15p4ax made the panel keyable for the
        // follow-up TextField; the trade-off was every clicked button
        // showed a blue focus ring. The TextField has its own visual
        // focus state (caret), so suppressing the chrome ring globally
        // here is safe and removes the ugly blue box around icons.
        .focusEffectDisabled()
    }
}

// MARK: - Icon

private struct TaskIcon: View {
    let task: HelperTask
    let assignedColor: Color
    let isExpanded: Bool
    let onTap: () -> Void

    private var taskColor: Color { assignedColor }

    var body: some View {
        // v15p4bc (2026-05-25): ring is now the per-task assigned color,
        // not the rainbow gradient. Reason: an angular 7-color gradient
        // rendered into a ~32px circle with 1.8pt stroke desaturates the
        // interpolated mid-hues — the ring read as washed-out chrome.
        // Single-color ring at full saturation + thicker stroke gives
        // each task a vibrant, distinct ring matching its halo + emblem.
        // Card border still uses rainbowLinear (large enough to render
        // the gradient cleanly).
        Button(action: onTap) {
            ZStack {
                // Black circle with vibrant per-task stroke ring.
                Circle()
                    .fill(Color.black.opacity(0.88))
                    .frame(width: HelperColumnStyle.iconSize, height: HelperColumnStyle.iconSize)
                    .overlay(
                        Circle().strokeBorder(taskColor, lineWidth: HelperColumnStyle.iconRingLineWidth)
                    )
                    .shadow(
                        color: taskColor.opacity(isExpanded ? HelperColumnStyle.iconShadowOpacityExpanded : HelperColumnStyle.iconShadowOpacityCollapsed),
                        radius: isExpanded ? HelperColumnStyle.iconShadowRadiusExpanded : HelperColumnStyle.iconShadowRadiusCollapsed,
                        x: 0,
                        y: 0
                    )

                // Per-task colored emblem with subtle inner glow.
                Image(systemName: task.category.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(taskColor)
                    .shadow(color: taskColor.opacity(HelperColumnStyle.iconEmblemGlowOpacity), radius: 4, x: 0, y: 0)

                if task.status == .running {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(taskColor, lineWidth: HelperColumnStyle.runningRingThickness + 0.5)
                        .frame(width: HelperColumnStyle.iconSize + 6, height: HelperColumnStyle.iconSize + 6)
                        .rotationEffect(.degrees(task.status == .running ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: task.id)
                }

                if task.status == .completed && !task.isRead && !isExpanded {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .offset(x: HelperColumnStyle.iconSize / 2 - 2, y: -HelperColumnStyle.iconSize / 2 + 2)
                }

                if task.status == .failed || task.status == .abandoned {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                        .offset(x: HelperColumnStyle.iconSize / 2 - 4, y: -HelperColumnStyle.iconSize / 2 + 4)
                }
            }
            .frame(width: HelperColumnStyle.iconSize + 12, height: HelperColumnStyle.iconSize + 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // v15p4bd (2026-05-25): kill the AppKit focus ring. v15p4ax made
        // the panel keyable so the follow-up TextField works, but a
        // side effect is icon buttons now show the blue focus highlight
        // after being clicked. The icon itself is the visual feedback;
        // we don't need a chrome ring on top of it.
        .focusable(false)
        .focusEffectDisabled()
        .help(task.shortTitle)
    }
}

// MARK: - Expanded card

private struct TaskCard: View {
    let task: HelperTask
    let assignedColor: Color
    @Binding var followUpDraft: String
    let onClose: () -> Void
    let onDismiss: () -> Void
    let onSubmitFollowUp: (String) -> Void
    @FocusState private var followUpFocused: Bool
    @State private var showFullTask: Bool = false   // v15p4as: toggle summary ↔ full task

    private var taskColor: Color { assignedColor }
    private var headerText: String {
        if let s = task.summary, !s.isEmpty, !showFullTask {
            return s
        }
        return task.task
    }

    var body: some View {
        VStack(spacing: 0) {
            // v15p4aq: inverted header. No colored background; title text
            // itself takes the rainbow gradient. Divider line below
            // separates header from body. No more 3-line limit — the
            // title grows to whatever height it needs so the full task
            // text is always readable.
            // v15p4as: header shows summary by default with an expand
            // button (info icon) to swap in the full task text. Toggle
            // doesn't affect any other state — just the visible header.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: task.category.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(taskColor)
                    .padding(.top, 2)
                Text(headerText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(taskColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Show expand button only if there's a summary to toggle from
                if let s = task.summary, !s.isEmpty {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { showFullTask.toggle() } }) {
                        Image(systemName: showFullTask ? "chevron.up.circle" : "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(taskColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .help(showFullTask ? "Show summary" : "Show full task")
                }
                Text(statusLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(taskColor.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(taskColor.opacity(0.12)))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Rainbow divider line between header and body
            Rectangle()
                .fill(HelperColumnStyle.rainbowLinear)
                .frame(height: 0.6)
                .opacity(0.55)
                .padding(.horizontal, 0)

            // Body — full result, scrollable for long answers. v15p4z:
            // shows task.result (not the 200-char preview) so the user
            // can read the whole answer + scroll past it.
            VStack(alignment: .leading, spacing: 8) {
                if task.status == .running || task.status == .queued {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.6))
                        .frame(height: 2)
                }

                // v15p4ac: only wrap in ScrollView when content
                // actually overflows. Short answers ("Working on it…",
                // 1-paragraph results) render at natural height so the
                // card hugs its content instead of always reserving
                // ~440px of empty space.
                if fullBody.count > 800 {
                    ScrollView {
                        Text(fullBody)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.88))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: HelperColumnStyle.cardMaxScrollHeight)
                } else {
                    Text(fullBody)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.88))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    if let r = task.result {
                        Button(action: { copyToClipboard(r) }) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(MiniButtonStyle())
                    }
                    // v15p4au: parse "Saved to: <path>" from the result
                    // and offer an Open button that reveals the file in
                    // Finder (or opens it directly if the user prefers).
                    if let savedPath = extractSavedPath() {
                        Button(action: { openInFinder(savedPath) }) {
                            Label("Open file", systemImage: "arrow.up.right.square")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(MiniButtonStyle())
                    }
                    Button(action: onDismiss) {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(MiniButtonStyle())
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(MiniButtonStyle())
                }

                // Follow-up input — only on completed tasks with a result.
                // v15p4z (2026-05-24): mirrors the notch panel's follow-up
                // so Steph can thread either surface.
                if task.status == .completed, task.result != nil {
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
                                    .foregroundColor(taskColor)
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
                }
            }
            .padding(12)
        }
        // Card backgrounds (clipped to card shape)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.62))
            }
        )
        .overlay(
            // Crisp rainbow border on the card edge
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(HelperColumnStyle.rainbowLinear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // v15p4aq: card halo dimensions cut ~in half from v15p4ap
        // (padding -14 → -7, blur 22 → 11). Subtle wash around the
        // card instead of a dominant halo. Opacity slightly bumped
        // since the smaller blur concentrates the color.
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(HelperColumnStyle.rainbowAngular)
                .padding(-7)
                .blur(radius: 11)
                .opacity(0.55)
        )
        .compositingGroup()
        .padding(HelperColumnStyle.cardGlowRadius + 6)
    }

    private var fullBody: String {
        if let r = task.result, !r.isEmpty {
            return r
        }
        if let e = task.errorMessage {
            return "Error: \(e)"
        }
        switch task.status {
        case .queued: return "Queued — waiting to start."
        case .running: return "Working on it…"
        case .abandoned: return "Clicky+ quit before this task finished. Re-run if you still need it."
        default: return ""
        }
    }

    private var statusLabel: String {
        switch task.status {
        case .queued: return "QUEUED"
        case .running: return "RUNNING"
        case .completed: return "READY"
        case .failed: return "FAILED"
        case .abandoned: return "ABANDONED"
        }
    }

    private func sendFollowUp() {
        let trimmed = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitFollowUp(trimmed)
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Parse the helper's result for the canonical "Saved to: <path>"
    /// line. Returns the extracted absolute path or nil. v15p4au.
    private func extractSavedPath() -> String? {
        guard let result = task.result else { return nil }
        // Match a line that starts with "Saved to: " and captures
        // the rest until end of line. The helper system prompt
        // instructs the format explicitly.
        for line in result.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("saved to:") {
                let path = String(trimmed.dropFirst("saved to:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// Reveal the saved file in Finder (selects it within its folder
    /// instead of opening the file itself, so the user can decide what
    /// app to open it with).
    private func openInFinder(_ path: String) {
        let resolved = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: resolved)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Mini button style

private struct MiniButtonStyle: ButtonStyle {
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
