//
//  NotchMenuView.swift
//  leanring-buddy
//
//  v15p3gm (2026-05-17): NEW. Design surface for the notch's expanded
//  menu, decoupled from CompanionPanelView. The classic menu bar
//  dropdown (CompanionPanelView) is unchanged and keeps working;
//  this file is where we iterate on the notch redesign in isolation.
//
//  Design intent (per Steph's design direction, 2026-05-17):
//    • The notch unfolds DOWNWARD into one continuous black shape —
//      wings at top (notch height), expanded body below, rounded
//      bottom corners. NOT a separate panel; same visual language as
//      the pill above.
//    • Body content is TABS + a card-based dashboard.
//    • Tabs hint at scopes (Home / Sessions / Settings or similar).
//    • Home tab shows cards: active mode, hotkey hints, cursor color,
//      providers — glance-able, not a settings list.
//
//  This file is for VISUAL prototyping. Iterate via SwiftUI #Preview
//  at the bottom. When the design is locked, wire it into
//  NotchPanelManager.toggleExpanded() to replace the current no-op.
//

import SwiftUI

// MARK: - Tabs

/// Top-level pages in the notch's expanded menu. Names + symbols are
/// placeholders that we'll iterate on visually.
enum NotchMenuTab: String, CaseIterable, Identifiable {
    case home
    case sessions
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .sessions: return "waveform"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Root view

/// The expanded notch menu. Renders the continuous-with-notch shape
/// (flat top, rounded bottom) plus tabs + content.
///
/// Width and notch height are passed in so this can preview at the
/// same dimensions used by the real notch panel.
struct NotchMenuView: View {
    /// Width of the expanded body. Should match the visible pill width
    /// when wings are fully out — wider than the hardware notch so the
    /// menu's top edge flows naturally from the wing tips.
    let width: CGFloat
    /// Height of the top wing zone (matches hardware notch height).
    /// Always present — invisible behind the hardware notch center but
    /// visible as wings flanking it.
    let notchHeight: CGFloat

    @State private var selectedTab: NotchMenuTab = .home

    var body: some View {
        VStack(spacing: 0) {
            // Wings zone — same role as the pill above. Always present.
            // Center hidden by camera; wings flank it.
            Color.clear
                .frame(height: notchHeight)

            // Tab strip — pill-style segmented buttons inside the notch
            // body, just below where the wings end.
            tabStrip
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            // Content area — switches based on selected tab.
            tabContent
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .background(menuBackground)
    }

    /// The notch-language background shape — flat top, rounded bottom,
    /// pure black. Same fill as the pill so they read as one shape.
    private var menuBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(NotchMenuTab.allCases) { tab in
                tabButton(tab: tab)
            }
            Spacer()
        }
    }

    private func tabButton(tab: NotchMenuTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(tab.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            homeDashboard
        case .sessions:
            sessionsList
        case .settings:
            settingsList
        }
    }

    // MARK: - Home dashboard (cards)

    /// Card-based dashboard for the Home tab. Glance-able blocks rather
    /// than a settings list.
    private var homeDashboard: some View {
        VStack(spacing: 10) {
            activeModeCard
            cursorColorCard
            hotkeyHintsCard
        }
    }

    private var activeModeCard: some View {
        notchCard(
            title: "Active mode",
            accentColor: .pink
        ) {
            HStack {
                Circle()
                    .fill(Color.pink)
                    .frame(width: 8, height: 8)
                Text("Marin (Gemini)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text("Idle")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var cursorColorCard: some View {
        notchCard(
            title: "Cursor color",
            accentColor: .blue
        ) {
            HStack(spacing: 10) {
                ForEach(["blue", "red", "yellow", "green"], id: \.self) { swatch in
                    Circle()
                        .fill(colorForSwatch(swatch))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(swatch == "blue" ? Color.white : Color.clear, lineWidth: 2)
                        )
                }
                Spacer()
            }
        }
    }

    private var hotkeyHintsCard: some View {
        notchCard(
            title: "Quick reference",
            accentColor: .gray
        ) {
            VStack(alignment: .leading, spacing: 6) {
                hotkeyRow(keys: "⌃⌥", label: "Marin", color: .pink)
                hotkeyRow(keys: "⌃fn", label: "Voice → text", color: .purple)
                hotkeyRow(keys: "⌥fn", label: "Watch", color: .red)
            }
        }
    }

    private func hotkeyRow(keys: String, label: String, color: Color) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.10))
                )
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - Sessions tab (placeholder)

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Marin transcripts and Watch responses will show here.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Settings tab (placeholder)

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model picker, indicator style, sound family, etc.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Card chrome

    /// Standard card shell inside the notch menu. Subtle background
    /// (slight white opacity so it reads as a "card" inside the black
    /// notch surface without competing with the pure-black exterior).
    private func notchCard<Content: View>(
        title: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .default))
                .foregroundColor(.white.opacity(0.45))
                .tracking(0.6)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func colorForSwatch(_ name: String) -> Color {
        switch name {
        case "blue": return Color(red: 0.2, green: 0.5, blue: 1.0)
        case "red": return Color(red: 1.0, green: 0.25, blue: 0.28)
        case "yellow": return Color(red: 0.95, green: 0.78, blue: 0.10)
        case "green": return Color(red: 0.20, green: 0.84, blue: 0.49)
        default: return .gray
        }
    }
}

// MARK: - Previews

#Preview("Notch menu — Home tab") {
    NotchMenuView(width: 360, notchHeight: 38)
        .padding(40)
        .background(
            // Sim the actual screen wallpaper darkness so the menu's
            // black background and the surrounding "screen" both feel
            // realistic in the preview.
            LinearGradient(
                colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
}

#Preview("Notch menu — wider variant") {
    NotchMenuView(width: 420, notchHeight: 38)
        .padding(40)
        .background(Color.gray.opacity(0.3))
}
