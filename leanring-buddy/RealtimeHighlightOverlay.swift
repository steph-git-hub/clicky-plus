//
//  RealtimeHighlightOverlay.swift
//  leanring-buddy / Clicky+
//
//  Created 2026-05-02 (v15p2 Chunk 2). On-screen highlight overlay
//  used by Realtime mode's `highlight_element` tool to point at UI
//  elements while Marin walks the user through unfamiliar apps.
//
//  Implementation note: this used SwiftUI initially but rendering
//  was unreliable for absolute-positioned content over a fullscreen
//  transparent window — the @State + .position pattern wasn't
//  consistently triggering. Rewritten with a plain AppKit NSView
//  that draws a magenta border in draw(_:) — predictable, simple,
//  no view-identity weirdness.
//
//  Architecture:
//    • Borderless transparent NSWindow at .screenSaver level covering
//      the screen containing the target rect.
//    • Custom HighlightContentView (NSView subclass) draws a magenta
//      rounded rectangle border + soft glow + label at a target rect
//      in window-local AppKit coords (bottom-left origin).
//    • Animation via CABasicAnimation on the layer for the pulse
//      effect; NSView's flip uses default isFlipped = false so we
//      can keep AppKit coordinates throughout.
//

import AppKit

/// MainActor-isolated because NSWindow + NSView rendering must happen
/// on the main thread.
@MainActor
final class RealtimeHighlightOverlayManager {
    private var window: NSWindow?
    private var contentView: HighlightContentView?
    private var hideWorkItem: DispatchWorkItem?

    /// Show a highlight at the given screen-coordinate rect for the
    /// specified dwell time, then auto-hide.
    func show(
        screenRect: CGRect,
        label: String,
        dwellSeconds: Double = 4.0
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        // Pick the screen with the largest intersection with the
        // target rect. If no screen overlaps, give up — caller
        // shouldn't have asked us to draw off-screen.
        guard let targetScreen = pickTargetScreen(for: screenRect) else {
            return
        }

        // Convert global-screen rect → window-local rect by subtracting
        // the screen origin. AppKit window-local coords have origin
        // at the bottom-left of the window's content area.
        let localRectInWindow = CGRect(
            x: screenRect.origin.x - targetScreen.frame.origin.x,
            y: screenRect.origin.y - targetScreen.frame.origin.y,
            width: screenRect.width,
            height: screenRect.height
        )

        // Build (or refresh) the overlay window covering the screen.
        let overlayWindow = ensureWindow(on: targetScreen)
        let view = ensureContentView(in: overlayWindow)
        view.update(highlightRect: localRectInWindow, label: label)

        overlayWindow.orderFrontRegardless()

        // Schedule auto-hide after dwell.
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + dwellSeconds,
            execute: workItem
        )
    }

    /// Hide and tear down the overlay window. Idempotent.
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        contentView?.stopAnimation()
        window?.orderOut(nil)
        window = nil
        contentView = nil
    }

    // MARK: - Setup helpers

    private func pickTargetScreen(for rect: CGRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(rect)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        return bestScreen
    }

    private func ensureWindow(on screen: NSScreen) -> NSWindow {
        if let existing = window, existing.screen === screen {
            return existing
        }
        window?.orderOut(nil)
        let newWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.level = .screenSaver
        newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newWindow.ignoresMouseEvents = true
        newWindow.hasShadow = false
        newWindow.setFrame(screen.frame, display: true)
        window = newWindow
        return newWindow
    }

    private func ensureContentView(in window: NSWindow) -> HighlightContentView {
        if let existing = contentView, existing.window === window {
            return existing
        }
        let view = HighlightContentView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        contentView = view
        return view
    }
}

// MARK: - Custom NSView that draws the magenta highlight

private final class HighlightContentView: NSView {
    private var highlightRect: CGRect = .zero
    private var label: String = ""
    private var pulseLayer: CALayer?

    /// AppKit's default. We draw using AppKit coordinates throughout
    /// (bottom-left origin, y up) so window-local rects pass straight
    /// into bezierPath without flipping.
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func update(highlightRect: CGRect, label: String) {
        self.highlightRect = highlightRect
        self.label = label
        self.needsDisplay = true
        startPulseAnimation()
    }

    func stopAnimation() {
        layer?.sublayers?.removeAll { $0 === pulseLayer }
        pulseLayer = nil
    }

    private func startPulseAnimation() {
        // Remove any prior pulse layer.
        stopAnimation()

        // Add a glow-ish CALayer that we can pulse via opacity
        // animation. Sized to match the highlight rect, padded a
        // bit for the soft outer halo.
        let glow = CALayer()
        let pad: CGFloat = 8
        let glowRect = highlightRect.insetBy(dx: -pad, dy: -pad)
        glow.frame = glowRect
        glow.cornerRadius = 12
        glow.borderWidth = 5
        glow.borderColor = NSColor(srgbRed: 1.0, green: 0.247, blue: 0.71, alpha: 1.0).cgColor
        glow.backgroundColor = NSColor.clear.cgColor
        glow.shadowColor = NSColor(srgbRed: 1.0, green: 0.247, blue: 0.71, alpha: 1.0).cgColor
        glow.shadowOpacity = 0.85
        glow.shadowRadius = 14
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.6
        pulse.toValue = 1.0
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .greatestFiniteMagnitude
        glow.add(pulse, forKey: "pulse")
        pulseLayer = glow
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlightRect.width > 1, highlightRect.height > 1 else { return }

        // Inner crisp magenta rounded rectangle border.
        let innerPath = NSBezierPath(
            roundedRect: highlightRect,
            xRadius: 8,
            yRadius: 8
        )
        innerPath.lineWidth = 3
        NSColor(srgbRed: 1.0, green: 0.247, blue: 0.71, alpha: 1.0).setStroke()
        innerPath.stroke()

        // Optional label above the rect (or below if too close to top
        // of screen). 28pt of vertical padding.
        guard !label.isEmpty else { return }

        let padding: CGFloat = 28
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let truncatedLabel = label.count > 80 ? String(label.prefix(77)) + "…" : label
        let labelString = NSAttributedString(string: truncatedLabel, attributes: attrs)
        let labelSize = labelString.size()

        // Background pill for readability.
        let labelPadX: CGFloat = 10
        let labelPadY: CGFloat = 5
        let pillSize = CGSize(
            width: labelSize.width + labelPadX * 2,
            height: labelSize.height + labelPadY * 2
        )

        // Default: above the highlight. If we'd run off the top of
        // the window, place below instead.
        var pillOrigin = CGPoint(
            x: highlightRect.midX - pillSize.width / 2,
            y: highlightRect.maxY + 6
        )
        if pillOrigin.y + pillSize.height > bounds.maxY - 4 {
            pillOrigin.y = highlightRect.minY - pillSize.height - 6
        }
        // Clamp horizontally so the pill stays on-screen.
        pillOrigin.x = max(4, min(bounds.maxX - pillSize.width - 4, pillOrigin.x))

        let pillRect = CGRect(origin: pillOrigin, size: pillSize)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        NSColor(srgbRed: 0.85, green: 0.18, blue: 0.55, alpha: 1.0).setFill()
        pillPath.fill()

        let labelOrigin = CGPoint(
            x: pillOrigin.x + labelPadX,
            y: pillOrigin.y + labelPadY
        )
        labelString.draw(at: labelOrigin)
    }
}
