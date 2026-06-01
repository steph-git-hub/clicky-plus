//
//  NotchPanelManager.swift
//  leanring-buddy
//
//  v15p3fz (2026-05-17): NEW. Notch-style command center.
//  v15p3ga (2026-05-17): Ship 2 — context-aware pill. The pill is no
//  longer static three dots; it reacts to CompanionManager state in
//  Dynamic-Island fashion. Resting state shows a Clicky brand mark.
//  Active states (Marin / VTT / Watch / etc.) show a mode-tinted dot
//  plus a live label or partial transcript that streams as the user
//  speaks. The pill grows/shrinks to fit its content.
//
//  Opt-in via the `clicky.useNotch` UserDefault. Default off.
//

import AppKit
import Combine
import SwiftUI

/// Same KeyablePanel pattern used by MenuBarPanelManager so SwiftUI text
/// fields inside the expanded panel can receive focus despite the
/// non-activating style.
private class NotchKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Bubbles the SwiftUI pill's rendered size up to AppKit so the NSPanel
/// can be resized to match. Without this the panel stays at its initial
/// fixed size and the pill's animated growth either gets clipped or
/// floats inside a wider invisible click area.
private struct NotchPillSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

@MainActor
final class NotchPanelManager: NSObject {
    private var pillPanel: NSPanel?
    private var expandedPanel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager

    // Resting pill geometry — wings only (no drop-down tab).
    // v15p3ge (2026-05-17): the pill is now TWO zones — a top strip
    // at notch height (always present, forms the wings flanking the
    // camera hardware) and a drop-down tab below (only present when
    // there's content). Resting width is generously wider than the
    // hardware notch so the wings are immediately visible.
    private let restingPillWidth: CGFloat = 320
    /// v15p3gh (2026-05-17): the pill panel is now a FIXED large size
    /// so SwiftUI content can grow freely (long transcripts, hover
    /// states, etc.) without ever exceeding the panel bounds. The
    /// SwiftUI pill inside renders at its intrinsic size, centered
    /// horizontally and anchored to the top edge. Trade-off: clicks
    /// in transparent areas around the pill are captured by the panel
    /// rather than passing through to the menu bar — acceptable since
    /// the menu bar in those regions is usually just empty space.
    private let pillPanelFixedWidth: CGFloat = 800
    private let pillPanelFixedHeight: CGFloat = 140
    /// Resting height = the actual notch height. Detected from
    /// safeAreaInsets.top of the notched screen at runtime; falls back
    /// to a sensible default if no notch is present.
    private var notchHeight: CGFloat {
        let h = resolveTargetScreen()?.safeAreaInsets.top ?? 0
        return h > 0 ? h : 32
    }
    /// Active state can grow up to this width to accommodate a live
    /// transcript snippet. Beyond this we let the transcript truncate
    /// rather than pushing the pill off-center.
    private let maxPillWidth: CGFloat = 320
    /// Vertical distance from the bottom of the menu bar to the top of
    /// the pill. Keeps the pill visually anchored to the menu bar without
    /// touching it.
    private let pillTopMargin: CGFloat = 4

    // Expanded panel geometry. Width matches the existing CompanionPanelView
    // layout (320pt). Height is content-driven via fittingSize.
    private let expandedWidth: CGFloat = 320
    /// Vertical gap between the pill and the expanded panel below it.
    /// v15p3gf (2026-05-17): tightened from 6pt to 0pt so the expanded
    /// menu reads as connected to the notch rather than floating below
    /// it. Steph reported the prior gap felt disconnected.
    private let expandedTopGap: CGFloat = 0

    private(set) var isExpanded: Bool = false
    /// Latest SwiftUI-reported size for the pill. Tracked so we can
    /// resize the NSPanel to match (with a sensible floor) whenever
    /// CompanionManager state changes the pill's content.
    private var lastReportedPillSize: CGSize = .zero

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createPillPanel()
        showPill()

        // Mirror MenuBarPanelManager's dismiss-panel notification handling
        // so the global Esc + cancel flows that already exist keep working
        // when notch mode is on.
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.collapseExpanded()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Pill panel (always-visible)

    private func createPillPanel() {
        // Wrapper view binds the SwiftUI pill to CompanionManager state
        // and reports its rendered size back via PreferenceKey. The
        // NSPanel resizes to match whenever the size changes.
        let wrapper = NotchPillHostView(
            companionManager: companionManager,
            notchHeight: notchHeight,
            restingWidth: restingPillWidth,
            onTap: { [weak self] in self?.toggleExpanded() },
            onSizeChange: { [weak self] size in
                Task { @MainActor in
                    self?.handlePillSizeChange(size)
                }
            }
        )

        // v15p3gh (2026-05-17): NSPanel is now a FIXED large size. The
        // SwiftUI pill inside renders at its intrinsic size, centered
        // horizontally and anchored to the top of the panel. This
        // eliminates the panel-resize / SwiftUI-content race condition
        // that was clipping long transcripts and hover-grown content.
        let hostingView = NSHostingView(rootView: wrapper)
        hostingView.frame = NSRect(x: 0, y: 0, width: pillPanelFixedWidth, height: pillPanelFixedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillPanelFixedWidth, height: pillPanelFixedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // v15p3gd (2026-05-17): bumped panel level from .statusBar (25)
        // to .popUpMenu (101) so it reliably renders OVER the menu bar
        // when the pill overlays the notch area. At .statusBar the
        // menu bar's background can sometimes paint on top, hiding
        // the pill's wings.
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Hidden from screen captures — same convention as the cursor
        // overlay so the pill never leaks into Zoom/QuickTime recordings.
        panel.sharingType = .none
        // Ignore clicks in transparent regions outside the visible
        // capsule. The SwiftUI gesture handler captures clicks on the
        // capsule itself; this keeps wide-pill background areas
        // click-through so the user can interact with apps beneath.
        // (Disabled for now — easier to land clicks on the pill if the
        //  whole panel area is hit-testable. Revisit if it bites.)
        // panel.ignoresMouseEvents = false

        panel.contentView = hostingView
        pillPanel = panel
        positionPillAtTopCenter(panelWidth: pillPanelFixedWidth)
    }

    /// Returns the screen the pill should live on. Prefers a notched
    /// MacBook display (the one with safeAreaInsets.top > 0) over
    /// whichever screen happens to have focus, because the whole point
    /// of notch mode is to anchor to the hardware notch. If no notched
    /// screen is connected (external monitor only, non-notched Mac),
    /// falls back to NSScreen.main.
    /// v15p3gc (2026-05-17): added after Steph's pill appeared on his
    /// Sceptre external display instead of the MBP's notched screen.
    private func resolveTargetScreen() -> NSScreen? {
        let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        return notched ?? NSScreen.main
    }

    /// v15p3gd (2026-05-17): Pill positioning rewritten to extend the
    /// hardware notch HORIZONTALLY rather than dropping down BELOW it.
    /// The pill is positioned at the very top of the screen, in the
    /// menu bar zone, centered horizontally, wider than the notch. The
    /// hardware notch covers the middle of the pill; the visible left
    /// and right wings flank it, creating one continuous black shape.
    /// Steph's reference (Farza's video) puts the indicator in the
    /// menu bar zone level with the notch — at-rest the wings are
    /// short, when active they extend further outward.
    ///
    /// Tradeoff: the pill overlays menu items in its bounds. For
    /// frontmost apps with few menu items (Cowork, browsers in
    /// fullscreen) this is invisible. For apps with crowded menus the
    /// pill covers items in its lane — acceptable for v1, can be
    /// refined later by positioning to the side of the notch instead
    /// of overlaying it.
    private func positionPillAtTopCenter(panelWidth: CGFloat) {
        guard let pillPanel else { return }
        guard let screen = resolveTargetScreen() else { return }
        // v15p3gh (2026-05-17): panel is fixed size — position uses
        // pillPanelFixedWidth/Height directly. The SwiftUI pill inside
        // is centered horizontally and anchored to the top.
        let x = (screen.frame.midX - pillPanelFixedWidth / 2).rounded()
        let y = (screen.frame.maxY - pillPanelFixedHeight).rounded()
        pillPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// v15p3gh (2026-05-17): the panel no longer resizes with content.
    /// This callback still receives SwiftUI's reported pill size so we
    /// can track the visible pill bounds for positioning the expanded
    /// menu directly under it (see positionExpandedBelowPill). Panel
    /// stays at its fixed size (pillPanelFixedWidth × pillPanelFixedHeight).
    private func handlePillSizeChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastReportedPillSize = size
        // If the expanded menu is open, reposition it to follow the
        // pill's new visible bottom — necessary when content changes
        // grow the pill vertically while the menu is showing.
        if isExpanded {
            positionExpandedBelowPill()
        }
    }

    func showPill() {
        positionPillAtTopCenter(panelWidth: pillPanel?.frame.width ?? restingPillWidth)
        pillPanel?.orderFront(nil)
    }

    func hidePill() {
        collapseExpanded()
        pillPanel?.orderOut(nil)
    }

    // MARK: - Expanded panel (shown on click)

    private func toggleExpanded() {
        // v15p4w-revert (2026-05-23): notch click toggles the helper
        // task history panel as a separate floating window. The
        // chrome-merge "expand naturally from the notch" treatment is
        // design-phase work — tracked in project_clicky_helper_ui_polish.md.
        NotchHelperHistoryPanel.shared.toggle()
    }

    private func showExpanded() {
        if expandedPanel == nil {
            createExpandedPanel()
        }
        positionExpandedBelowPill()
        expandedPanel?.makeKeyAndOrderFront(nil)
        expandedPanel?.orderFrontRegardless()
        isExpanded = true
        installClickOutsideMonitor()
    }

    private func collapseExpanded() {
        guard isExpanded else { return }
        expandedPanel?.orderOut(nil)
        isExpanded = false
        removeClickOutsideMonitor()
    }

    private func createExpandedPanel() {
        // v15p3gl (2026-05-17): pass useNotchChrome:true so the panel's
        // OWN background draws as flat-top-rounded-bottom in pure black —
        // matching the pill's black exactly. No external wrappers needed;
        // the chrome decision lives inside CompanionPanelView.
        let content = CompanionPanelView(
            companionManager: companionManager,
            useNotchChrome: true
        )
        .frame(width: expandedWidth)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: expandedWidth, height: 600)
        // v15p3gi (2026-05-17): autoresize so the content tracks the
        // panel's actual size (which is set dynamically via fittingSize)
        // instead of being stuck at the initial 600pt placeholder.
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = NotchKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: expandedWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .none

        panel.contentView = hostingView
        expandedPanel = panel
    }

    private func positionExpandedBelowPill() {
        guard let expandedPanel, let pillPanel else { return }
        guard let screen = resolveTargetScreen() else { return }

        let fittingSize = expandedPanel.contentView?.fittingSize
            ?? CGSize(width: expandedWidth, height: 600)
        let actualHeight = fittingSize.height

        // v15p3gi (2026-05-17): hard-position the menu at notchHeight
        // below screen top, regardless of pill state. The previous
        // approach of computing position from lastReportedPillSize was
        // creating a notch-height gap because the PreferenceKey either
        // wasn't firing in time or was reporting an unexpected value.
        // Hard-positioning guarantees no gap.
        let menuTopY = screen.frame.maxY - notchHeight
        let x = (pillPanel.frame.midX - expandedWidth / 2).rounded()
        let y = (menuTopY - actualHeight - expandedTopGap).rounded()

        expandedPanel.setFrame(
            NSRect(x: x, y: y, width: expandedWidth, height: actualHeight),
            display: true
        )
    }

    // MARK: - Click-outside dismissal

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let clickLocation = NSEvent.mouseLocation
                if let panel = self.expandedPanel, panel.frame.contains(clickLocation) {
                    return
                }
                if let pill = self.pillPanel, pill.frame.contains(clickLocation) {
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.isExpanded else { return }
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }
                self.collapseExpanded()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - Host wrapper

/// Outer SwiftUI wrapper that observes CompanionManager state and pipes
/// rendered-size changes back to AppKit via the onSizeChange closure.
/// Separated from NotchPillView so the size reporting is centralized
/// and the view itself doesn't need to know about NSPanel resizing.
private struct NotchPillHostView: View {
    @ObservedObject var companionManager: CompanionManager
    let notchHeight: CGFloat
    let restingWidth: CGFloat
    let onTap: () -> Void
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        NotchPillView(
            companionManager: companionManager,
            notchHeight: notchHeight,
            restingWidth: restingWidth,
            onTap: onTap
        )
        // v15p3gl (2026-05-17): removed .fixedSize() — it was locking
        // the pill to a size determined at first layout, preventing
        // vertical growth when multi-line transcripts arrived. The
        // pill's internal VStack now has its own minWidth/maxWidth
        // frame constraints to keep the pill bounded; height grows
        // naturally with content.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: NotchPillSizePreferenceKey.self,
                        value: proxy.size
                    )
            }
        )
        .onPreferenceChange(NotchPillSizePreferenceKey.self) { size in
            onSizeChange(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Pill content

/// The visual pill itself — Capsule with content that morphs based on
/// CompanionManager state. Treated as a Dynamic-Island-style chrome:
/// the resting state is a quiet brand mark; active states broadcast a
/// colored dot + a short label or live partial transcript so Steph can
/// glance at the top of his screen and see what Clicky is doing.
private struct NotchPillView: View {
    @ObservedObject var companionManager: CompanionManager
    let notchHeight: CGFloat
    let restingWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    /// v15p3hk (2026-05-19): width of the invisible camera-area gap
    /// between the wings. The MacBook notch cutout is roughly 200pt
    /// wide; we leave a bit of slop on either side so content never
    /// gets clipped by the camera mask.
    fileprivate static let cameraGapWidth: CGFloat = 200

    /// v15p3hr (2026-05-19): wing slot width is now COMPUTED per state
    /// based on the longest content (label or indicator) so the pill
    /// stays compact at idle and grows with active content. Both wings
    /// always get the SAME slot width — that's what keeps the cameraGap
    /// centered on the camera. See `wingSlotWidth(for:)`.
    fileprivate static let wingHorizontalPadding: CGFloat = 12
    fileprivate static let indicatorMaxWidth: CGFloat = 20

    /// Measure the natural rendered width of a status label at the
    /// wing font (size 12, medium weight). Returns 0 for nil.
    fileprivate static func labelWidth(_ label: String?) -> CGFloat {
        guard let label, !label.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let measured = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured)
    }

    /// The wing slot width for a given state. Both wings get this same
    /// width so the layout is symmetric and the cameraGap stays
    /// centered on the camera. Wing slot = larger of (label width,
    /// indicator width) + padding.
    fileprivate static func wingSlotWidth(for state: PillStateView) -> CGFloat {
        let labelW: CGFloat
        if let label = state.statusLabel {
            labelW = labelWidth(label)
        } else {
            labelW = 14   // sparkle SF Symbol approx width
        }
        let contentMax = max(labelW, indicatorMaxWidth)
        return contentMax + wingHorizontalPadding
    }

    /// Total pill width for a state: 2 wings + cameraGap, with growth
    /// up to 500pt when a transcript is present and its single-line
    /// rendering would exceed the wing-based base width.
    fileprivate static func pillWidth(for state: PillStateView) -> CGFloat {
        let wingW = wingSlotWidth(for: state)
        let basePillWidth = 2 * wingW + cameraGapWidth
        guard let transcript = state.transcript, !transcript.isEmpty else {
            return basePillWidth
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let singleLine = ceil((transcript as NSString).size(withAttributes: [.font: font]).width)
        let transcriptPillWidth = min(singleLine + 24, 500)
        return max(basePillWidth, transcriptPillWidth)
    }

    /// Vertical height of the drop-down tab when active. Added below
    /// the notch line; content (indicator + label) lives in this zone.
    private let tabHeight: CGFloat = 26

    var body: some View {
        let state = derivedState()
        let wingSlot = Self.wingSlotWidth(for: state)
        let pillW = Self.pillWidth(for: state)

        VStack(spacing: 0) {
            // Zone 1 — flush WINGS at notch height. Both wings get the
            // SAME slot width (wingSlot), computed per state, so the
            // cameraGap stays centered on the hardware camera while
            // the pill stays as compact as possible at idle.
            HStack(spacing: 0) {
                // Left wing slot — content right-aligned, padding on
                // the right pushes it slightly away from the camera.
                Group {
                    if let label = state.statusLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(.trailing, 6)
                .frame(width: wingSlot, alignment: .trailing)

                Color.clear.frame(width: Self.cameraGapWidth)

                Group {
                    if state.kind == .processing {
                        ProcessingRing(tint: state.tint)
                            .frame(width: 14, height: 14)
                    } else if state.showsWaveform {
                        NotchWaveformBars(
                            tint: state.tint,
                            audioPowerLevel: micLevel()
                        )
                        .frame(width: 18, height: 14)
                    } else if state.kind == .live {
                        statusDot(state: state)
                    } else {
                        NotchWaveformBars(
                            tint: DS.Colors.overlayCursorBlue.opacity(0.55),
                            audioPowerLevel: 0
                        )
                        .frame(width: 18, height: 14)
                    }
                }
                .padding(.trailing, 6)
                .frame(width: wingSlot, alignment: .trailing)
            }
            .frame(height: notchHeight)

            // Zone 2 — drop-down ONLY when a live transcript exists.
            // v15p3hn (2026-05-19): removed `.fixedSize(horizontal: false,
            // vertical: true)` which was forcing Text to render at its
            // single-line ideal width and overflow the maxWidth bound.
            // Now Text wraps naturally inside maxWidth: 476, and the
            // pill background grows with it. Padding outside the frame
            // brings total drop-down width to ≤500.
            // v15p3hq (2026-05-19): drop-down Text fills the pill's
            // explicit width minus padding, wraps to up to 4 lines.
            // No more fixedSize gymnastics — the outer pill has an
            // explicit width, so Text just gets a finite proposal
            // and wraps cleanly. Vertical height is whatever the
            // wrapped content needs; VStack reflows the background.
            if let transcript = state.transcript {
                Text(transcript)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        // v15p3hr (2026-05-19): pill width computed per state by
        // pillWidth(for:). Compact at idle (sparkle ≈ 14pt slot →
        // pill ≈ 240pt). Grows with longer status labels and grows
        // again when a transcript is present (up to 500pt cap before
        // wrapping kicks in).
        .frame(width: pillW)
        .background(pillBackground)
        // v15p3gg (2026-05-17): scale removed entirely. Hover scale
        // was causing the pill to grow past the hosting view bounds
        // (clipped at the edges, looked like "shadow corners going
        // straight down"). Press scale was creating a perceived gap
        // at the top. Cursor change to pointing-hand is sufficient
        // hover affordance; the pill content (label + indicator) is
        // already visually responsive without scale.
        // v15p3gb (2026-05-17): tightened transitions per the
        // Farza-pattern target (~100ms feel). Spring keeps a hint of
        // bounce without overshooting.
        // v15p3gj (2026-05-17): only animate on state.id changes (mode
        // changes — Marin → VTT → Watch etc., infrequent). The previous
        // .animation(value: state.label) was re-triggering the spring
        // on every transcript word update, so the pill's height was
        // perpetually mid-animation and lagging behind multi-line text
        // — line 2 kept getting clipped. Text content changes now
        // re-render instantly without re-springing the size.
        .animation(.spring(response: 0.18, dampingFraction: 0.85), value: state.id)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.06), value: isPressed)
        .contentShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    onTap()
                }
        )
    }

    /// The pill's deep-black background. Top edge FLAT (flush with
    /// screen top / notch top), bottom edge rounded (continues notch's
    /// organic curve).
    /// v15p3gf (2026-05-17): shadow removed. The previous offset-y:4
    /// shadow cast straight-down dark streaks at the pill's vertical
    /// edges where the wings met the hardware notch — Steph reported
    /// these as "shadow at corners going down on both sides."
    private var pillBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 10,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
    }

    /// The colored mode indicator. Pulses while the mode is "live"
    /// (listening, watching, etc.), spins during processing, and stays
    /// quiet at rest.
    @ViewBuilder
    private func statusDot(state: PillStateView) -> some View {
        ZStack {
            // Halo / pulse — only visible during live states. Uses a
            // larger faded circle behind the dot for a soft glow.
            if state.kind == .live {
                Circle()
                    .fill(state.tint.opacity(0.5))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isHovered ? 1.0 : 0.85)
                    .blur(radius: 3)
                    .opacity(0.7)
            }
            // Spinner ring for processing states (Watch generating,
            // polish in flight, etc.).
            if state.kind == .processing {
                ProcessingRing(tint: state.tint)
                    .frame(width: 14, height: 14)
            }
            // Main solid dot.
            Circle()
                .fill(state.tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.4), value: state.kind)
    }

    // MARK: - Derived state

    /// Snapshot of what the pill should display right now based on
    /// CompanionManager flags. Keeping this in a single function makes
    /// the priority order obvious and easy to tune — the first match
    /// wins, so put the higher-priority modes earlier.
    private func derivedState() -> PillStateView {
        // v15p3gb (2026-05-17): labels are present-tense action verbs
        // matching the Farza-pattern verbal style — "Speaking",
        // "Listening", "Reading screen" — short and active rather than
        // wordy ("Marin listening", "Watching screen").

        // v15p3hk (2026-05-19): each branch returns statusLabel +
        // optional transcript. transcript drops the pill down; status
        // alone keeps it flush.

        // 1. Watch mode (highest — single hotkey, dominates screen).
        if companionManager.isVideoWatchModeActive {
            return PillStateView(
                id: "watch.listening",
                tint: DS.Colors.overlayCursorRed,
                kind: .live,
                statusLabel: "Reading screen",
                transcript: nil,
                showsWaveform: true
            )
        }
        if companionManager.isVideoWatchResponseInFlight {
            return PillStateView(
                id: "watch.processing",
                tint: DS.Colors.overlayCursorRed,
                kind: .processing,
                statusLabel: "Thinking",
                transcript: nil,
                showsWaveform: false
            )
        }

        // v15p4as (2026-05-24): removed the dedicated "Researching"
        // pill state for helper-active. Steph's feedback: helper
        // running is signaled by the spinner around the icon bubble
        // in the top-right column — Marin's notch can stay in
        // Listening (with waveform) so it's clear she's still
        // available. The notch taking over with Researching made it
        // look like she was unavailable.

        // 2. Marin Realtime / Gemini (magenta). Live transcript only
        // appears in the pill when the toggle is on — default off.
        if companionManager.isRealtimeModeActive {
            let assistantText = companionManager.realtimeAssistantTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userText = companionManager.realtimeUserTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let marinTranscriptInPill = UserDefaults.standard.bool(forKey: "clicky.notch.marinTranscriptInPill")

            // v15p3ho (2026-05-19): tail-truncate Marin transcripts the
            // same way VTT does, so as Marin keeps speaking the last
            // line in the pill stays current rather than the FIRST 3
            // lines freezing and the latest words running off-bottom.
            let assistantTail = assistantText.count > 300
                ? "…" + String(assistantText.suffix(300))
                : assistantText
            let userTail = userText.count > 300
                ? "…" + String(userText.suffix(300))
                : userText
            if !assistantText.isEmpty {
                return PillStateView(
                    id: "marin.speaking",
                    tint: DS.Colors.overlayCursorMagenta,
                    kind: .live,
                    statusLabel: "Speaking",
                    transcript: marinTranscriptInPill ? assistantTail : nil,
                    showsWaveform: true
                )
            }
            if !userText.isEmpty {
                return PillStateView(
                    id: "marin.listening",
                    tint: DS.Colors.overlayCursorMagenta,
                    kind: .live,
                    statusLabel: "Listening",
                    transcript: marinTranscriptInPill ? userTail : nil,
                    showsWaveform: true
                )
            }
            return PillStateView(
                id: "marin.idle",
                tint: DS.Colors.overlayCursorMagenta,
                kind: .live,
                statusLabel: "Listening",
                transcript: nil,
                showsWaveform: true
            )
        }

        // 3. Voice-to-text modes (Deepgram cyan / AssemblyAI orange).
        // VTT live transcript ALWAYS drops down — the whole point of
        // the live preview is to see your words as they land.
        // v15p3ho (2026-05-19): status label changed from "Listening" →
        // "Typing" per Steph — VTT literally types-via-voice so the
        // verb matches the action. Transcript tail-limited to the
        // most recent ~300 chars so the visible 4 lines stay current
        // as user speaks; older words drop off and SwiftUI's
        // .truncationMode(.head) puts "…" at the leading edge.
        let vttPartial = companionManager.vttLiveTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let vttPartialTail = vttPartial.count > 300
            ? "…" + String(vttPartial.suffix(300))
            : vttPartial
        // v15p3hs (2026-05-19): VTT transcript drop-down in the notch
        // is now behind a toggle, default OFF — Steph keeps the live
        // preview pill near the cursor, so duplicating it in the
        // notch is noise. Toggle on in the panel if you want it.
        let vttTranscriptInPill = UserDefaults.standard.bool(forKey: "clicky.notch.vttTranscriptInPill")
        let vttTranscriptForPill: String? = vttTranscriptInPill && !vttPartialTail.isEmpty ? vttPartialTail : nil
        if companionManager.isVoiceToTextDeepgramModeActive {
            // v15p3hx (2026-05-19): tint follows the selected VTT
            // provider — cyan Deepgram or orange AssemblyAI.
            let vttTint: Color = {
                switch companionManager.selectedVTTProvider {
                case "assemblyai": return DS.Colors.overlayCursorOrange
                default: return DS.Colors.overlayCursorCyan
                }
            }()
            return PillStateView(
                id: "vtt.\(companionManager.selectedVTTProvider)",
                tint: vttTint,
                kind: .live,
                statusLabel: "Typing",
                transcript: vttTranscriptForPill,
                showsWaveform: true
            )
        }
        if companionManager.isVoiceToTextModeActive {
            return PillStateView(
                id: "vtt.assemblyai",
                tint: DS.Colors.overlayCursorOrange,
                kind: .live,
                statusLabel: "Typing",
                transcript: vttTranscriptForPill,
                showsWaveform: true
            )
        }

        // 4. Typing mode (green) — speak, AI drafts a reply, paste it.
        // v15p3hp (2026-05-19): renamed "Typing" → "Drafting" to
        // distinguish from VTT (also "Typing"). VTT = voice-to-text
        // dictation; Drafting = speak a request and AI drafts a
        // response that gets pasted.
        if companionManager.isTypingModeActive {
            return PillStateView(
                id: "typing",
                tint: DS.Colors.overlayCursorGreen,
                kind: .live,
                statusLabel: "Drafting",
                transcript: nil,
                showsWaveform: true
            )
        }

        // 5. Capture-to-inbox (yellow).
        if companionManager.isCaptureToInboxModeActive {
            return PillStateView(
                id: "capture.inbox",
                tint: DS.Colors.overlayCursorYellow,
                kind: .live,
                statusLabel: "Capturing",
                transcript: nil,
                showsWaveform: false
            )
        }

        // 6. Polish flash (purple, brief).
        if companionManager.isPolishCommandFlashActive
            || companionManager.isPolishHotkeyModifierCaptureModeActive {
            return PillStateView(
                id: "polish",
                tint: DS.Colors.overlayCursorPurple,
                kind: .live,
                statusLabel: "Polishing",
                transcript: nil,
                showsWaveform: false
            )
        }

        // Idle — sparkle + idle bars, no label, no transcript.
        return PillStateView(
            id: "idle",
            tint: DS.Colors.overlayCursorBlue,
            kind: .quiet,
            statusLabel: nil,
            transcript: nil,
            showsWaveform: false
        )
    }

    /// Returns the appropriate mic level for the current state. Marin
    /// modes use the Realtime/Gemini input level; everything else uses
    /// Buddy's dictation manager level.
    private func micLevel() -> CGFloat {
        if companionManager.isRealtimeModeActive {
            return companionManager.realtimeInputAudioLevel
        }
        return companionManager.currentAudioPowerLevel
    }

    /// Trims a long transcript to a tail-snippet that reads naturally
    /// when truncated. Keeps the most recent words (which are usually
    /// what the user wants to glance at) instead of the start.
    private func tail(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        let start = text.index(text.endIndex, offsetBy: -max)
        return "…" + text[start...].trimmingCharacters(in: .whitespaces)
    }
}

/// Compact snapshot of what the pill should display. SwiftUI uses `id`
/// for `.animation(value:)` so each distinct state change can trigger
/// a single spring transition.
/// v15p3hk (2026-05-19): label split into two roles:
///  - `statusLabel`: short status word ("Listening" / "Speaking" /
///    "Typing" / "Polishing" / "Capturing") rendered flush in the
///    left wing at notch height. Always one line.
///  - `transcript`: optional live transcript text that drops down
///    BELOW the notch line in its own zone. Wraps to up to 4 lines,
///    head-truncated with leading "…" when longer.
private struct PillStateView: Equatable {
    enum Kind: Equatable { case quiet, live, processing }
    let id: String
    let tint: Color
    let kind: Kind
    let statusLabel: String?
    let transcript: String?
    /// True when the pill should show an audio-reactive waveform
    /// (Marin, VTT, Watch listening) instead of a static dot. Quiet
    /// modes like Typing / Capture / Polish get the dot.
    let showsWaveform: Bool
}

// MARK: - Waveform bars

/// Tiny audio-reactive bar group rendered inside the pill during
/// listening / speaking states. Three vertical bars whose heights are
/// driven by the mic level (or a gentle idle pulse when the mic is
/// quiet). Each bar has a slightly offset phase so the group reads as
/// a waveform, not a synced-up trio.
/// v15p3gb (2026-05-17): replaces the static colored dot in active
/// audio modes per Steph's Farza-pattern reference: "small, animated
/// waveform that pulses in response to audio."
private struct NotchWaveformBars: View {
    let tint: Color
    let audioPowerLevel: CGFloat

    @State private var idlePhase: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            bar(phaseOffset: 0.0)
            bar(phaseOffset: 0.6)
            bar(phaseOffset: 1.2)
        }
        .onAppear {
            // Continuous idle phase so silent windows still get a
            // gentle breathing animation rather than a static line.
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                idlePhase = .pi * 2
            }
        }
    }

    private func bar(phaseOffset: Double) -> some View {
        let level = max(audioPowerLevel, 0)
        // Add a small idle component so the bars never go fully flat —
        // gives the pill a "breathing" feel between user utterances.
        let idle = (sin(idlePhase + phaseOffset) + 1) / 2 * 0.18
        let combined = min(max(level * 1.6 + CGFloat(idle), 0.18), 1.0)
        let height = 4 + combined * 10  // 4pt min, ~14pt max
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(tint)
            .frame(width: 3, height: height)
            .animation(.easeOut(duration: 0.12), value: audioPowerLevel)
    }
}

// MARK: - Processing ring

/// Small circular spinner used inside the status dot when the pill is
/// in a processing state (Watch generating, polish in flight, etc.).
/// SwiftUI-native rotation so the animation pauses cleanly when the
/// view disappears.
private struct ProcessingRing: View {
    let tint: Color

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                tint,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
