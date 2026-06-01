//
//  SoundPreviewWindow.swift
//  leanring-buddy
//
//  v15p3db (2026-05-15): floating preview window for Clicky+ sound
//  families. Shows a matrix — one row per family (built-in or custom-
//  sample), one column per ClickySoundID. Clicking any cell previews
//  that exact (family, moment) combination without affecting the
//  user's active family selection.
//
//  Opened from the panel's "Preview all sounds" button. Lives in its
//  own NSWindow so the user can click around the matrix without
//  dismissing the menu-bar panel.
//

import AppKit
import SwiftUI

@MainActor
final class SoundPreviewWindowManager: NSObject {
    static let shared = SoundPreviewWindowManager()

    private var window: NSWindow?

    private override init() { super.init() }

    /// Show the preview window. If already visible, brings it forward.
    func showPreviewWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let contentView = SoundPreviewMatrixView { [weak self] in
            self?.closePreviewWindow()
        }
        let hosting = NSHostingView(rootView: contentView)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Clicky+ sound preview"
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePreviewWindow() {
        window?.close()
    }
}

extension SoundPreviewWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Drop the reference so the next open creates a fresh window
        // with fresh state (e.g., new sample families after a Reload).
        window = nil
    }
}

// MARK: - Matrix view

/// Display metadata for each ClickySoundID — short label for the
/// column header, longer label for the cell tooltip, and an SF Symbol
/// to give each column visual identity at a glance.
private struct MomentColumn: Identifiable {
    let id: ClickySoundID
    let shortLabel: String
    let fullLabel: String
    let symbol: String
}

private let momentColumns: [MomentColumn] = [
    .init(id: .vttStart,       shortLabel: "Start",   fullLabel: "VTT start",        symbol: "mic"),
    .init(id: .vttSuccess,     shortLabel: "Success", fullLabel: "VTT success",      symbol: "checkmark"),
    .init(id: .vttError,       shortLabel: "Error",   fullLabel: "VTT error",        symbol: "exclamationmark.triangle"),
    .init(id: .marinEngage,    shortLabel: "Engage",  fullLabel: "Marin engage",     symbol: "sparkles"),
    .init(id: .marinDisengage, shortLabel: "Off",     fullLabel: "Marin disengage",  symbol: "arrow.uturn.backward"),
    .init(id: .polishStart,    shortLabel: "Polish",  fullLabel: "Polish start",     symbol: "wand.and.stars"),
    .init(id: .polishDone,     shortLabel: "Done",    fullLabel: "Polish done",      symbol: "checkmark.seal"),
    .init(id: .visionCapture,  shortLabel: "Vision",  fullLabel: "Vision capture",   symbol: "camera"),
    .init(id: .genericError,   shortLabel: "Fail",    fullLabel: "Generic error",    symbol: "xmark.circle"),
]

private struct SoundPreviewMatrixView: View {
    let onClose: () -> Void

    // Observe the engine so the list updates if the user reloads
    // samples while the window is open.
    @ObservedObject private var engine = ClickySoundEngine.shared

    private let nameColumnWidth: CGFloat = 150
    private let cellWidth: CGFloat = 42
    private let cellHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Sticky column headers
            HStack(spacing: 4) {
                Text("Family")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: nameColumnWidth, alignment: .leading)
                ForEach(momentColumns) { col in
                    VStack(spacing: 2) {
                        Image(systemName: col.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(col.shortLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: cellWidth, height: 38)
                    .help(col.fullLabel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.08))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(engine.allFamilies.enumerated()), id: \.offset) { index, family in
                        familyRow(family: family, isAlternate: index.isMultiple(of: 2))
                    }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 400)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sound preview")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(engine.allFamilies.count) families × \(momentColumns.count) moments. Click any cell to preview.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Reload samples") {
                ClickySoundEngine.shared.reloadCustomSampleFamilies()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func familyRow(family: ActiveSoundFamily, isAlternate: Bool) -> some View {
        let isActive = family == engine.activeFamily
        HStack(spacing: 4) {
            // v15p3dc (2026-05-15): tap the name to set as active family
            // — but DO NOT auto-play any sound. The auto-play was
            // doubling up with the cell buttons and contributing to the
            // "many sounds" complaint. The dot indicator + bold text
            // give visual confirmation; the user clicks a cell when they
            // want to hear something.
            Button {
                engine.activeFamily = family
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "circle.inset.filled" : "circle")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.5))
                    Text(family.displayName)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: nameColumnWidth, alignment: .leading)
            .help("Set \(family.displayName) as active family")

            ForEach(momentColumns) { col in
                Button {
                    engine.preview(family: family, id: col.id)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary.opacity(0.7))
                        .frame(width: cellWidth - 6, height: cellHeight - 6)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.gray.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.gray.opacity(0.20), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: cellWidth, height: cellHeight)
                .help("Preview \(col.fullLabel) for \(family.displayName)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .background(isAlternate ? Color.gray.opacity(0.04) : Color.clear)
    }
}
