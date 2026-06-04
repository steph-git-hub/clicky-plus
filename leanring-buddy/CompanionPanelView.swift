//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    /// v15p3gl (2026-05-17): when true, swap the rounded panel chrome
    /// for a flat-top-rounded-bottom shape filled with pure black, so
    /// the panel visually merges with the notch's pill above. Default
    /// false preserves the classic menu-bar dropdown look.
    var useNotchChrome: Bool = false
    // v15p3de (2026-05-15): observe the sound engine so the family
    // dropdown label, the selection checkmark, and the active-state
    // styling stay in sync when activeFamily/isEnabled/allFamilies
    // change. Without this, picking a new family from the dropdown
    // would update the singleton but the label would stay on the
    // previously-shown family until the panel re-rendered for some
    // other reason.
    @ObservedObject private var soundEngine = ClickySoundEngine.shared
    @State private var emailInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                // v15p3ht (2026-05-19): tabbed layout. Tab bar at top,
                // then the selected tab's content. Quit lives in the
                // footer below the divider so it's always reachable.
                Spacer().frame(height: 8)

                tabBar
                    .padding(.horizontal, 16)

                Spacer().frame(height: 10)

                Group {
                    switch selectedTab {
                    case .modes:
                        modesTabContent
                    case .audio:
                        audioTabContent
                    case .display:
                        displayTabContent
                    case .modifiers:
                        // v15p4d (2026-05-22): Modifiers tab grew past
                        // screen height once each row started rendering
                        // all three text lines inline. Bounded scroll
                        // wrapper here; other tabs render natural-size
                        // so they don't get empty space below content.
                        ScrollView(.vertical, showsIndicators: true) {
                            modifiersTabContent
                        }
                        .frame(maxHeight: 500)
                    }
                }
                .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Sound effects (v15p3cu, 2026-05-14)
    //
    // Two rows: an on/off toggle plus a family picker that lets Steph
    // hot-swap between the 4 pre-rendered sound families (tactile snap,
    // drum, mouth click, plucked string) without restarting the app.
    // Both rows bind to ClickySoundEngine.shared, which persists the
    // choice via UserDefaults so it survives relaunch.

    /// On/off toggle for all interface sounds. Mirrors the visual style
    /// of `showClickyCursorToggleRow` below for consistency.
    private var soundEnabledToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Sound effects")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { ClickySoundEngine.shared.isEnabled },
                set: { newValue in
                    ClickySoundEngine.shared.isEnabled = newValue
                    // Audible confirmation when turning on so the user
                    // knows the toggle did something. (Skipped on off
                    // because play() is a no-op when disabled.)
                    if newValue {
                        ClickySoundEngine.shared.play(.polishDone)
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    /// Family picker — dropdown that lists built-in synth families AND
    /// any user-supplied sample families discovered in the Clicky
    /// sounds folder. Switching plays the Marin-engage sound so the user
    /// hears their pick immediately.
    ///
    /// v15p3cx (2026-05-15): switched from a 4-segment control to a
    /// dropdown so the list can scale to N families as the user drops
    /// in more sample files.
    private var soundFamilyPickerRow: some View {
        HStack {
            Text("Sound family")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Menu {
                ForEach(ClickySoundEngine.shared.allFamilies, id: \.self) { family in
                    Button(action: {
                        DispatchQueue.main.async {
                            ClickySoundEngine.shared.activeFamily = family
                            // Audible preview of the just-selected family.
                            ClickySoundEngine.shared.play(.marinEngage)
                        }
                    }) {
                        let isSelected = ClickySoundEngine.shared.activeFamily == family
                        if isSelected {
                            Label(family.displayName, systemImage: "checkmark")
                        } else {
                            Text(family.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // v15p3da (2026-05-15): cap the menu label width and
                    // truncate so a long sample name doesn't push the
                    // "Sound family" left-label off-screen. Caller still
                    // sees the full name when they open the dropdown.
                    Text(ClickySoundEngine.shared.activeFamily.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: 170, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 4)
    }

    /// Row exposing the sound preview matrix window. Opens a separate
    /// floating window where the user can audition any (family, moment)
    /// combination — particularly useful after dropping in new samples
    /// to feel how each one maps across all 9 events.
    /// v15p3db (2026-05-15).
    private var soundPreviewMatrixRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.grid.3x2")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            Text("Sound preview")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Button(action: {
                SoundPreviewWindowManager.shared.showPreviewWindow()
            }) {
                Text("Open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// Row exposing the custom sounds folder + reload button. Only shown
    /// when sound effects are enabled — paired with the family picker
    /// so the workflow is "drop file in folder → reload → pick family"
    /// without ever leaving the panel.
    private var soundCustomFolderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            Text("Custom sounds folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Button(action: {
                ClickySoundEngine.shared.revealCustomSoundsFolderInFinder()
            }) {
                Text("Show")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Button(action: {
                DispatchQueue.main.async {
                    ClickySoundEngine.shared.reloadCustomSampleFamilies()
                    // Tiny audible confirmation
                    ClickySoundEngine.shared.play(.polishDone)
                }
            }) {
                Text("Reload")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Marin provider picker
    //
    // v15p3di (2026-05-16): runtime switch between OpenAI Realtime and
    // Gemini 3.1 Flash Live. Persisted via @AppStorage so the choice
    // survives relaunch. Default stays OpenAI so behavior is unchanged
    // for anyone who hasn't picked Gemini.

    private var marinProviderPickerRow: some View {
        HStack {
            Text("Marin")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                marinProviderButton(label: "Gemini", providerID: "gemini")
                marinProviderButton(label: "OpenAI", providerID: "openai")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func marinProviderButton(label: String, providerID: String) -> some View {
        let isSelected = companionManager.marinProvider == providerID
        return Button(action: {
            let chosen = providerID
            DispatchQueue.main.async {
                UserDefaults.standard.set(chosen, forKey: "marin.provider")
            }
        }) {
            Text(label)
                // v15p3hu (2026-05-19): font size 12 → 11 to match
                // modelOptionButton (Sonnet/Opus). Marin and Claude
                // pickers now use identical sizing.
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            // v15p3x (2026-05-10): defer one runloop tick. Same rationale
            // as the indicator picker — the captured `companionManager`
            // (a @MainActor class) is held as @StateObject upstream; if
            // the panel re-hosts mid-click the old instance frees and
            // the action crashes accessing it. Hopping a tick lets the
            // gesture machinery unwind first.
            let chosen = modelID
            DispatchQueue.main.async {
                companionManager.setSelectedModel(chosen)
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        // v15p3ht (2026-05-19): footer now contains ONLY the Quit
        // button. The setting rows that used to live here are split
        // across the tabs above (Audio + Display).
        quitButtonRow
    }

    // v15p3ht (2026-05-19): rows extracted from the old footerSection
    // so they can be slotted into the appropriate tabs.
    private var useNotchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notch mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(useNotch
                     ? "Top-of-screen pill. Restart to disable."
                     : "Replace menu-bar icon with a pill. Restart to enable.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $useNotch)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private var speedReadAICompressRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speed-read AI compress")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(speedReadAICompress
                     ? "Compresses with Haiku before reading. Adds ~2-4s."
                     : "Double-tap Shift reads raw text. Toggle on to compress first.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $speedReadAICompress)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private var marinVolumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Marin volume")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text("\(Int(marinVolume * 100))%")
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Slider(
                    value: Binding(
                        get: { Double(marinVolume) },
                        set: { newValue in
                            marinVolume = Float(newValue)
                            MarinVolumeStore.setVolume(Float(newValue))
                        }
                    ),
                    in: 0.0...1.0
                )
                .controlSize(.mini)
                .tint(DS.Colors.accent)
            }
        }
    }

    private var marinTranscriptInPillRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Marin transcript in notch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(marinTranscriptInPill
                     ? "Live transcript drops down under the notch."
                     : "Off — only \"Listening\" / \"Speaking\" shows.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $marinTranscriptInPill)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private var vttTranscriptInPillRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("VTT preview in notch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(vttTranscriptInPill
                     ? "Live transcript drops down under the notch."
                     : "Off — cursor-side pill still shows the preview.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $vttTranscriptInPill)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    // v15p3ht (2026-05-19): Tab bar — segmented control at the top
    // of the main content area. Persists selection to UserDefaults
    // via selectedTabRaw.
    private var tabBar: some View {
        // v15p3y (2026-05-21): added Modifiers tab — reference for the
        // polish modifier vocabulary as it grows.
        HStack(spacing: 0) {
            tabBarButton(tab: .modes, label: "Modes")
            tabBarButton(tab: .audio, label: "Audio")
            tabBarButton(tab: .display, label: "Display")
            tabBarButton(tab: .modifiers, label: "Modifiers")
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 0.5)
        }
    }

    private func tabBarButton(tab: PanelTab, label: String) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            selectedTabRaw = tab.rawValue
        }) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                Rectangle()
                    .fill(isSelected ? DS.Colors.overlayCursorCyan : Color.clear)
                    .frame(height: 2)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var modesTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            marinProviderPickerRow
            vttProviderPickerRow
            modelPickerRow
            hotkeyReferenceSection
                .padding(.top, 4)
            if companionManager.isRealtimeModeActive {
                marinLiveTranscriptSection
                    .padding(.top, 4)
            }
        }
    }

    // v15p3hx (2026-05-19): VTT provider picker — Deepgram / AssemblyAI
    // / Parakeet. Single Fn+Ctrl hotkey dispatches to the active
    // selection. Parakeet is a stub until WhisperKit is wired in.
    private var vttProviderPickerRow: some View {
        HStack {
            Text("VTT")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                vttProviderButton(label: "Deepgram", providerID: "deepgram")
                vttProviderButton(label: "Scribe v2", providerID: "scribe")
                vttProviderButton(label: "Parakeet", providerID: "parakeet")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func vttProviderButton(label: String, providerID: String) -> some View {
        let isSelected = companionManager.selectedVTTProvider == providerID
        return Button(action: {
            let chosen = providerID
            DispatchQueue.main.async {
                UserDefaults.standard.set(chosen, forKey: "clicky.vtt.provider")
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var audioTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            marinVolumeRow
            soundEnabledToggleRow
            if ClickySoundEngine.shared.isEnabled {
                soundFamilyPickerRow
                soundCustomFolderRow
                soundPreviewMatrixRow
            }
        }
    }

    @ViewBuilder
    private var displayTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            useNotchRow
            indicatorStylePickerSection
            marinTranscriptInPillRow
            vttTranscriptInPillRow
            speedReadAICompressRow
        }
    }

    // MARK: - Modifiers Tab (v15p3y, 2026-05-21)
    // Reference card for the polish modifier vocabulary. Spoken while
    // holding the polish hotkey (Ctrl+Opt). The modifier becomes
    // "Additional style guidance" passed to the polish prompt — or, for
    // listed mode-switch modifiers, swaps the polish prompt entirely.

    @ViewBuilder
    private var modifiersTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            modifiersHeaderRow

            modifiersSectionHeader(
                title: "Polish modes",
                subtitle: "Ctrl+Opt + say one of these to switch how the polish handles the text."
            )
            modifierEntryRow(
                phrase: "toggle polish",
                summary: "Coherence-first restructure",
                detail: "Same prompt as VTT toggle. Restructures clause boundaries, fixes fragments, replaces pronouns with referents. Preserves words within bounds of making sense. Paragraph order untouched."
            )
            modifierEntryRow(
                phrase: "full polish",
                summary: "Substantive editor pass",
                detail: "Deeper than toggle polish. Tightens redundancy, sharpens weak word choice, allows paragraph reorder, consolidates repeated points, varies sentence rhythm. Voice + meaning preserved. Use when text needs to read polished, not just clean."
            )
            modifierEntryRow(
                phrase: "format response",
                summary: "Match the structure on screen",
                detail: "Screenshot-driven reformatter. Bullets-to-bullets, numbered-to-numbered, prose-to-prose. Light polish + structural match to what you're replying to."
            )
            modifierEntryRow(
                phrase: "sharpen prompt",
                summary: "Sharpen brain-dump into a Claude prompt (coming soon)",
                detail: "Designed 2026-05-20. Brain-dump → tightened, well-formed Claude prompt → paste into chat input → fire. Two-word phrase chosen deliberately (reserves bare \"sharpen\" for future modifiers). Not yet wired in the worker — entry shown here as a placeholder so the menu stays complete."
            )

            modifiersSectionHeader(
                title: "Polish edit guidance",
                subtitle: "Any other spoken phrase becomes edit guidance for the polish — overrides preservation rules."
            )
            modifierEntryRow(
                phrase: "free-text instruction",
                summary: "Spelling fixes, edits, rewrites",
                detail: "Any spoken instruction — \"make this shorter\", \"change Lukas to Kevin\", \"Sider should be S-I-D-E-R\", \"one paragraph\". The modifier wins over default preservation."
            )

            modifiersSectionHeader(
                title: "Voice commands (other modes)",
                subtitle: "Not polish modifiers — special commands recognized in their own mode."
            )
            modifierEntryRow(
                phrase: "dictate last",
                summary: "Replay Marin's last response",
                detail: "Spoken in Drafting mode (Fn+Cmd). Pastes Marin's most recent response from her conversation history. Useful for capturing what she just said in voice as typed text."
            )
        }
    }

    private func modifiersSectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modifiersHeaderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Polish modifiers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold Ctrl+Opt + speak a phrase before the polish hotkey fires. Listed phrases below switch polish mode; anything else is treated as edit guidance.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // v15p4f (2026-05-22): SwiftUI .help() never fires reliably on this
    // panel — even with acceptsMouseMovedEvents = true. Switching to a
    // custom hover-driven popover via onHover + a delay timer. Each row
    // owns its own hover state via the extracted ModifierEntryRowView.
    private func modifierEntryRow(phrase: String, summary: String, detail: String) -> some View {
        ModifierEntryRowView(phrase: phrase, summary: summary, detail: detail)
    }

    private var quitButtonRow: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()
        }
    }

    // MARK: - Visual Helpers

    @ViewBuilder
    private var panelBackground: some View {
        if useNotchChrome {
            // v15p3gl (2026-05-17): notch mode chrome. Flat top so the
            // panel visually flows from the pill's bottom; rounded
            // bottom corners to match the pill's bottom curve language.
            // Pure black to match the pill's fill exactly.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background)
                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
        }
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

    // MARK: - Hotkey Reference

    /// Compact, read-only reference panel listing every Clicky+ hotkey, its mode
    /// name, and the per-mode overlay color. V1 is reference-only — rebinding is
    /// deferred to a later pass. Rows follow the existing row style (13pt label,
    /// tertiary metadata) and the modifier capsules reuse the subtle-fill pattern
    /// from the model picker.
    private var hotkeyReferenceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hotkeys")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.bottom, 6)

            // v15p3ht (2026-05-19): two-column layout — Hold on left,
            // Toggle on right. Modes without a toggle show "—".
            HStack {
                Text("Hold")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                Text("Toggle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 4) {
                hotkeyRowDual(holdKeys: ["⌃", "⌥"], toggleKeys: ["⌥", "⌥"], label: "Marin", color: DS.Colors.overlayCursorMagenta)
                hotkeyRowDual(holdKeys: ["⌥", "fn"], toggleKeys: nil, label: "Watch", color: DS.Colors.overlayCursorRed)
                // v15p3hx (2026-05-19): single VTT hotkey — provider
                // (Deepgram / AssemblyAI / Parakeet) picked in Modes tab.
                hotkeyRowDual(holdKeys: ["⌃", "fn"], toggleKeys: ["⌃", "⌃"], label: "VTT", color: vttIndicatorColor)
                hotkeyRowDual(holdKeys: ["⌘", "fn"], toggleKeys: ["⌘", "⌘"], label: "Drafting", color: DS.Colors.overlayCursorGreen)
                hotkeyRowDual(holdKeys: ["⇧", "fn"], toggleKeys: nil, label: "Capture", color: DS.Colors.overlayCursorYellow)
                hotkeyRowDual(holdKeys: ["⇧", "⌃"], toggleKeys: nil, label: "Polish (tap or hold)", color: DS.Colors.overlayCursorPurple)
            }
        }
    }

    /// v15p3ht (2026-05-19): two-key hotkey row. Hold chord on the
    /// left, optional toggle (double-tap) chord on the right. Modes
    /// without a toggle render "—" on the right.
    private func hotkeyRowDual(
        holdKeys: [String],
        toggleKeys: [String]?,
        label: String,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            keyChipGroup(keys: holdKeys)
                .frame(width: 56, alignment: .leading)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            if let toggleKeys {
                keyChipGroup(keys: toggleKeys)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.4))
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
    }

    private func keyChipGroup(keys: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
        }
    }

    // MARK: - Marin live transcripts (v15p2, 2026-05-03)
    //
    // Scrollable conversation log surfaced in the panel while Marin
    // is in a session. Each completed turn is appended as a (You,
    // Marin) pair; the in-flight turn streams live below them. Log
    // resets on cold session start. Auto-scrolls to bottom as new
    // text arrives so Steph never has to chase the cursor.
    //
    // Visible only when isRealtimeModeActive — when the session ends
    // the section disappears so the panel doesn't bloat. When
    // suspended by another mode, a "paused" tag appears in the
    // header.

    private var marinLiveTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if companionManager.isRealtimeSuspendedByOtherMode {
                    Text("paused")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DS.Colors.borderSubtle.opacity(0.5))
                        )
                }
            }
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(companionManager.realtimeCompletedTurns) { turn in
                            if !turn.user.isEmpty {
                                transcriptRow(
                                    label: "You",
                                    text: turn.user,
                                    accent: DS.Colors.overlayCursorBlue
                                )
                            }
                            if !turn.assistant.isEmpty {
                                transcriptRow(
                                    label: "Marin",
                                    text: turn.assistant,
                                    accent: DS.Colors.overlayCursorMagenta
                                )
                            }
                        }
                        // In-flight turn — only show rows that have
                        // content yet, with a placeholder until the
                        // first chars arrive.
                        let liveUser = companionManager.realtimeUserTranscript
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let liveAssistant = companionManager.realtimeAssistantTranscript
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !liveUser.isEmpty {
                            transcriptRow(
                                label: "You",
                                text: liveUser,
                                accent: DS.Colors.overlayCursorBlue
                            )
                        }
                        if !liveAssistant.isEmpty {
                            transcriptRow(
                                label: "Marin",
                                text: liveAssistant,
                                accent: DS.Colors.overlayCursorMagenta
                            )
                        }
                        // Idle placeholder when nothing's happening yet
                        if companionManager.realtimeCompletedTurns.isEmpty
                            && liveUser.isEmpty
                            && liveAssistant.isEmpty {
                            Text("Listening… speak to Marin and your conversation will appear here.")
                                .font(.system(size: 11, weight: .regular).italic())
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(DS.Colors.borderSubtle.opacity(0.2))
                                )
                        }
                        // Bottom anchor for auto-scroll.
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                }
                .frame(maxHeight: 280)
                .onChange(of: companionManager.realtimeAssistantTranscript) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: companionManager.realtimeUserTranscript) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: companionManager.realtimeCompletedTurns.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func transcriptRow(
        label: String,
        text: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(DS.Colors.borderSubtle.opacity(0.2))
        )
    }

    // MARK: - Indicator Style Picker (v15b 2026-05-01)
    //
    // A small picker in the panel that lets Steph swap between cursor/edge
    // indicator styles without dropping to Terminal. Backed by the same
    // @AppStorage flag as OverlayWindow.swift, so the switch is reactive
    // (no relaunch needed).
    @AppStorage("clicky.cursorIndicatorStyle") private var cursorIndicatorStyle: String = "triangle"

    /// v15p3fz (2026-05-17): notch mode opt-in. When true, the app
    /// shows a small dark pill at the top-center of the screen instead
    /// of the menu-bar icon. Click the pill to expand into the same
    /// CompanionPanelView content. Default off so existing users see
    /// no change until they explicitly opt in. Requires app restart
    /// to apply (Ship 1 — hot-swap comes later).
    @AppStorage("clicky.useNotch") private var useNotch: Bool = false

    /// v15p3gt (2026-05-18): speed-read AI compression toggle. When
    /// true, double-tap Shift routes the captured text through Haiku
    /// to strip filler before RSVP playback. Adds ~2-4s latency but
    /// roughly halves the word count, so for verbose AI digests it's
    /// a net speed-up. Default off so first-time use has no surprise
    /// latency; flip on when you want it.
    @AppStorage("clicky.speedRead.aiCompress") private var speedReadAICompress: Bool = false

    // v15p3hs (2026-05-19): notch transcript toggles. Both default off
    // so the notch stays compact. Steph keeps the cursor-side VTT
    // preview pill, so the notch one would be redundant; Marin's
    // transcript can flood the notch with words, so it's opt-in.
    @AppStorage("clicky.notch.marinTranscriptInPill") private var marinTranscriptInPill: Bool = false
    @AppStorage("clicky.notch.vttTranscriptInPill") private var vttTranscriptInPill: Bool = false

    // v15p3hs (2026-05-19): Marin output volume. Stored as Float to
    // map 1:1 to AVAudioPlayerNode.volume. The @State + Binding pattern
    // routes writes through MarinVolumeStore.setVolume so the active
    // session applies the change mid-turn via notification.
    @State private var marinVolume: Float = MarinVolumeStore.volume

    // v15p3ht (2026-05-19): panel tabs. Three sections — Modes (model
    // pickers + hotkey reference), Audio (volume + sound effects),
    // Display (notch + indicator + transcript toggles). Persisted so
    // the user lands back on whatever they were last on.
    fileprivate enum PanelTab: String { case modes, audio, display, modifiers }
    @AppStorage("clicky.panel.selectedTab") private var selectedTabRaw: String = PanelTab.modes.rawValue
    private var selectedTab: PanelTab {
        get { PanelTab(rawValue: selectedTabRaw) ?? .modes }
    }

    private struct IndicatorStyleOption: Identifiable {
        let id: String
        let label: String
        let hint: String
    }

    private static let indicatorStyleOptions: [IndicatorStyleOption] = [
        .init(id: "triangle", label: "Triangle", hint: "Classic — small blue triangle by cursor"),
        .init(id: "cursorDot", label: "Cursor dot", hint: "Tiny pulsing dot near cursor"),
        .init(id: "cursorDotRing", label: "Cursor dot + ring", hint: "Small fixed dot with a sonar-style ring that expands with your voice"),
        .init(id: "bottomEdgeLine", label: "Bottom-edge line", hint: "Horizontal line at the bottom of the screen"),
        .init(id: "sideStrip", label: "Side strip", hint: "Vertical strip on right edge, pulses"),
    ]

    // v15p3hu (2026-05-19): indicator picker is now a Menu dropdown
    // (matches soundFamilyPickerRow), not a radio list. Saves vertical
    // space on the Display tab.
    private var indicatorStylePickerSection: some View {
        HStack {
            Text("Indicator")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Menu {
                ForEach(Self.indicatorStyleOptions) { option in
                    Button {
                        let chosen = option.id
                        DispatchQueue.main.async {
                            cursorIndicatorStyle = chosen
                        }
                    } label: {
                        let isSelected = cursorIndicatorStyle == option.id
                        if isSelected {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentIndicatorStyleLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var currentIndicatorStyleLabel: String {
        Self.indicatorStyleOptions.first(where: { $0.id == cursorIndicatorStyle })?.label
            ?? "Triangle"
    }

    // v15p3hx (2026-05-19): VTT row color follows the active provider —
    // cyan for Deepgram, orange for AssemblyAI.
    private var vttIndicatorColor: Color {
        switch companionManager.selectedVTTProvider {
        case "scribe": return DS.Colors.overlayCursorOrange
        default: return DS.Colors.overlayCursorCyan
        }
    }

    private func hotkeyRow(keys: [String], label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    hotkeyCapsule(key)
                }
            }
            .frame(width: 92, alignment: .leading)

            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.45), radius: 3)
        }
        .padding(.vertical, 3)
    }

    private func hotkeyCapsule(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

}

// MARK: - ModifierEntryRowView (v15p4f, 2026-05-22)
// Hover-driven popover for the Modifiers tab. SwiftUI's .help() didn't
// fire on the non-activating panel even with acceptsMouseMovedEvents.
// This implementation uses onHover + a 350ms delay timer to drive a
// .popover() — gives us a tooltip-equivalent UX with full control.

private struct ModifierEntryRowView: View {
    let phrase: String
    let summary: String
    let detail: String

    @State private var showPopover = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\"\(phrase)\"")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 0)
            }
            Text(summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000) // 350ms delay
                    if !Task.isCancelled {
                        showPopover = true
                    }
                }
            } else {
                showPopover = false
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(10)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
