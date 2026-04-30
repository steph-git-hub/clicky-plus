//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Exclude from cross-process window capture. Clicky's own burst /
        // typing-mode screenshots use ScreenCaptureKit, which skips windows
        // with sharingType = .none — so we never accidentally include our
        // own overlay in the screenshots we send to Claude. This alone does
        // NOT help the native Cmd+Shift+4 picker (screencaptureui uses a
        // different capture path); that's handled by OverlayWindowManager's
        // suspend/resume driven by the CGEventTap in GlobalPushToTalk-
        // ShortcutMonitor.
        self.sharingType = .none

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    /// v12u (2026-04-28): Cursor presence indicator style. Reverted to
    /// "triangle" as default after Steph tested the glow and didn't love
    /// it. Glow stays available for future iteration. To try the glow:
    ///   defaults write com.makesomething.leanring-buddy clicky.cursorIndicatorStyle glow
    /// then relaunch. The system cursor itself is never modified —
    /// macOS doesn't allow apps to recolor the global pointer.
    @AppStorage("clicky.cursorIndicatorStyle") private var cursorIndicatorStyle: String = "triangle"

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm clicky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    /// The color used for the waveform + spinner right now. Encodes the
    /// current capture mode so the user has immediate visual feedback
    /// about what kind of interaction they triggered:
    ///   cyan   → polish hotkey flash (⌃⌥⌘ or voice "polish") — brief
    ///   yellow → capture-to-inbox mode (Fn+Opt)
    ///   purple → voice-to-text mode (Fn+Shift), raw transcript pastes
    ///   green  → typing mode (Fn+Cmd), Claude response pastes
    ///   red    → burst mode (Fn+Shift+Opt), multi-frame capture
    ///   blue   → normal push-to-talk voice
    /// Polish flash takes precedence because it's a brief 250ms tap-fire
    /// confirmation; the other modes are sustained holds. Order matters
    /// only defensively — the shortcut layer already ensures the
    /// hold-mode flags can't overlap, and the polish-flash flag is also
    /// gated on `pendingPolishCommandTask == nil` at trigger time.
    private var currentCursorTint: Color {
        if companionManager.isPolishCommandFlashActive
            || companionManager.isPolishHotkeyModifierCaptureModeActive {
            return DS.Colors.overlayCursorCyan
        }
        if companionManager.isCaptureToInboxModeActive {
            return DS.Colors.overlayCursorYellow
        }
        if companionManager.isVoiceToTextModeActive {
            return DS.Colors.overlayCursorPurple
        }
        if companionManager.isTypingModeActive {
            return DS.Colors.overlayCursorGreen
        }
        if companionManager.isBurstModeActive || companionManager.isBurstResponseCycleInFlight {
            // Cover both the capture phase (isBurstModeActive, briefly
            // ~hold duration) AND the processing/spinner phase that follows
            // (isBurstResponseCycleInFlight, until response is delivered).
            // Without the second flag, the spinner falls back to default
            // blue instead of burst red because isBurstModeActive clears
            // ~100ms after release.
            return DS.Colors.overlayCursorRed
        }
        return DS.Colors.overlayCursorBlue
    }

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            // v12t: cursor presence indicator. The triangle and glow share
            // identical visibility/animation rules; only the visual differs.
            // Switching is controlled by the AppStorage flag at the top of
            // BlueCursorView.
            //
            // The triangle (legacy) is a small filled blue arrow that
            // navigates and rotates to face the cursor.
            //
            // The glow (default in v12t) is a soft tinted radial halo
            // around the cursor hotspot — same "Clicky is running" presence
            // signal but far less visually intrusive. It does NOT replace
            // the system cursor (macOS doesn't allow that); it adds a
            // halo underneath the OS-rendered pointer.
            let presenceTint = currentCursorTint
            let presenceVisible = buddyIsVisibleOnThisScreen
                && !companionManager.isVoiceToTextModeActive
                && !companionManager.isTypingModeActive
                && !companionManager.isBurstModeActive
                && !companionManager.isCaptureToInboxModeActive
                && (companionManager.voiceState == .idle || companionManager.voiceState == .responding)

            // Triangle path — only rendered if explicitly opted-in via
            // UserDefaults. The default is the glow.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                // v12u: 12pt (was 16pt) — 25% smaller per Steph's request
                // for a more subtle presence while still keeping the
                // triangle as the cursor indicator.
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 6 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                // Triangle is hidden the MOMENT any capture mode goes
                // active, not when voiceState catches up. The voiceState
                // pipeline is async (Combine → main queue) and has a
                // 0.25s crossfade, which caused the triangle to visibly
                // overlap the waveform during mode startup. Mode flags
                // flip synchronously in the shortcut handlers, so
                // gating on them guarantees a clean handoff.
                .opacity(
                    cursorIndicatorStyle == "triangle" && presenceVisible
                        ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.12), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.08), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeOut(duration: 0.08), value: companionManager.isTypingModeActive)
                .animation(.easeOut(duration: 0.08), value: companionManager.isBurstModeActive)
                .animation(.easeOut(duration: 0.08), value: companionManager.isCaptureToInboxModeActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishCommandFlashActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishHotkeyModifierCaptureModeActive)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // v12t: cursor presence glow — soft tinted halo CENTERED ON
            // THE CURSOR HOTSPOT (unlike the triangle, which is offset
            // +35x/+25y to sit beside the cursor as a "buddy"). Back out
            // that offset so the glow renders directly under the system
            // pointer. Same hide rules as the triangle so listening/
            // processing modes can swap to the waveform/spinner cleanly.
            CursorPresenceGlow(tint: presenceTint)
                .opacity(
                    cursorIndicatorStyle != "triangle" && presenceVisible
                        ? cursorOpacity * 0.85 : 0
                )
                .position(
                    x: cursorPosition.x - 35,
                    y: cursorPosition.y - 25
                )
                .animation(.linear(duration: 0.04), value: cursorPosition)
                .animation(.easeIn(duration: 0.20), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.12), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isTypingModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isBurstModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isCaptureToInboxModeActive)

            // Waveform — replaces the triangle while listening.
            // Tint encodes the current capture mode:
            //   purple → voice-to-text mode (Fn+Shift), raw transcript pastes
            //   green  → typing mode (Fn+Cmd), Claude response pastes
            //   red    → burst mode (Fn+Shift+Opt), multi-frame capture
            //   blue   → normal push-to-talk voice
            // Order is defensive — the shortcut layer already prevents
            // these flags from overlapping.
            BlueCursorWaveformView(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                tint: currentCursorTint,
                captureTrigger: companionManager.lastScreenshotCaptureAt
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isBurstModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isTypingModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isCaptureToInboxModeActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishCommandFlashActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishHotkeyModifierCaptureModeActive)

            // Spinner — shown while the AI is processing (transcription + Claude + waiting for TTS).
            // Same mode-aware tint as the waveform above.
            BlueCursorSpinnerView(
                tint: currentCursorTint
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isBurstModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isTypingModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeInOut(duration: 0.15), value: companionManager.isCaptureToInboxModeActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishCommandFlashActive)
                .animation(.easeInOut(duration: 0.12), value: companionManager.isPolishHotkeyModifierCaptureModeActive)

            // Idea-captured toast — yellow pill with the transcript,
            // shown for ~3s after a capture-to-inbox append lands.
            // Positioned just below the cursor so the visual chain is
            // waveform (at cursor) → toast (below cursor) → fade.
            if let ideaText = companionManager.recentIdeaCaptureText, buddyIsVisibleOnThisScreen {
                IdeaCapturedToast(transcript: ideaText)
                    .position(x: cursorPosition.x, y: cursorPosition.y + 42)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)),
                        removal: .opacity
                    ))
            }

        }
        .animation(.easeInOut(duration: 0.18), value: companionManager.recentIdeaCaptureText)
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    // PATCH: skip intro video if onboarding already completed
                    if !self.companionManager.hasCompletedOnboarding {
                        self.companionManager.setupOnboardingVideo()
                    }
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// v12t: Subtle radial glow around the system cursor.
///
/// Replaces the legacy blue triangle as Clicky's "I'm running" presence
/// indicator. macOS draws the system cursor on top of all overlays at
/// the compositor level, so the glow renders BENEATH the user's actual
/// pointer — adding a soft halo without modifying or replacing the
/// system cursor itself.
///
/// Design:
///   - Radial gradient: tint at center 28% opacity → fully transparent at edge.
///   - 40pt diameter: generously wider than typical cursors, so the glow
///     reads as "around the cursor" rather than "behind a tiny patch."
///   - 6pt blur: softens the edge so there's no visible boundary.
///   - Tints with currentCursorTint, so mode color (idle blue, voice-mode
///     blue, polish-flash cyan, etc.) propagates here just like it does
///     to the audio bars and spinner.
///
/// Tunable via the constants below — adjust if Steph wants subtler/bolder.
private struct CursorPresenceGlow: View {
    var tint: Color = DS.Colors.overlayCursorBlue

    /// Outer reach of the glow. Larger = softer, more "ambient."
    private let diameter: CGFloat = 40
    /// Blur radius applied on top of the gradient. More = softer edge.
    private let blurRadius: CGFloat = 6
    /// Maximum opacity at the glow's center. The radial gradient still
    /// fades from this value to 0, so the actual peak appears slightly
    /// lower in mid-radius.
    private let centerOpacity: Double = 0.28

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: tint.opacity(centerOpacity), location: 0.0),
                        .init(color: tint.opacity(centerOpacity * 0.6), location: 0.45),
                        .init(color: tint.opacity(0), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: blurRadius)
            .allowsHitTesting(false)
    }
}

/// One emanating sonar ring. Rings are stored in an array so rapid-fire
/// captures (multi-frame burst, or future click-to-capture) can stack
/// concurrent rings that fade independently instead of strobing a single
/// flash overlay.
private struct SonarRingState: Identifiable {
    let id = UUID()
    let startTime: Date
}

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
/// Accepts a tint so burst mode can swap blue → red.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    var tint: Color = DS.Colors.overlayCursorBlue
    /// Fires a sonar ring radiating outward from the orb whenever this
    /// date changes — driven by CompanionManager.lastScreenshotCaptureAt
    /// so each screenshot grab has a visible confirmation. v12p (2026-04-28):
    /// replaced the strobing white camera-flash overlay with stacked sonar
    /// rings that read as "ping" rather than "flash" — better for rapid
    /// click-to-capture cadences where the previous flash was too noisy.
    var captureTrigger: Date? = nil

    @State private var sonarRings: [SonarRingState] = []

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    /// Sonar tuning. The ring starts at the orb's outer footprint and expands
    /// to ~4x in 650ms while fading to zero. Stroke (not fill) so it reads
    /// as an outward "ping" rather than a glowing blob.
    private let ringDuration: TimeInterval = 0.65
    private let ringStartDiameter: CGFloat = 16
    private let ringEndDiameter: CGFloat = 64
    private let ringInitialOpacity: Double = 0.75
    private let ringLineWidth: CGFloat = 1.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timelineContext in
            ZStack {
                // Sonar rings — drawn behind the audio bars so they never
                // wash out the waveform. .allowsHitTesting(false) on each
                // ring so they stay click-through.
                ForEach(sonarRings) { ring in
                    sonarRingView(for: ring, now: timelineContext.date)
                }

                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { barIndex in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(tint)
                            .frame(
                                width: 2,
                                height: barHeight(
                                    for: barIndex,
                                    timelineDate: timelineContext.date
                                )
                            )
                    }
                }
            }
            .shadow(color: tint.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
        .onChange(of: captureTrigger) { _, newValue in
            guard newValue != nil else { return }
            let ring = SonarRingState(startTime: Date())
            sonarRings.append(ring)
            // Remove the ring from the active array slightly after the
            // animation completes so the array stays bounded even on
            // long sessions with many rapid captures.
            DispatchQueue.main.asyncAfter(deadline: .now() + ringDuration + 0.1) {
                sonarRings.removeAll { $0.id == ring.id }
            }
        }
    }

    /// Renders one sonar ring at its current animation progress. Ease-out
    /// cubic on the radius so the ring shoots out fast then settles, and
    /// linear opacity so the fade stays predictable.
    @ViewBuilder
    private func sonarRingView(for ring: SonarRingState, now: Date) -> some View {
        let elapsed = now.timeIntervalSince(ring.startTime)
        let progress = max(0, min(elapsed / ringDuration, 1.0))
        let radiusEased = 1 - pow(1 - progress, 3)
        let diameter = ringStartDiameter + (ringEndDiameter - ringStartDiameter) * CGFloat(radiusEased)
        let opacity = ringInitialOpacity * (1 - progress)
        Circle()
            .strokeBorder(tint.opacity(opacity), lineWidth: ringLineWidth)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Idea Captured Toast

/// A small yellow pill that floats below the cursor for ~3 seconds
/// after a capture-to-inbox append, echoing the transcript that
/// just landed in Obsidian/Idea Inbox.md. Non-interactive — doesn't
/// steal focus, can't be clicked through to. Replaces itself if a
/// new capture fires before the dismiss timer elapses.
private struct IdeaCapturedToast: View {
    let transcript: String

    var body: some View {
        Text(transcript)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.black)
            .lineLimit(3)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.overlayCursorYellow)
            )
            .shadow(color: DS.Colors.overlayCursorYellow.opacity(0.5), radius: 8, x: 0, y: 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false
    var tint: Color = DS.Colors.overlayCursorBlue

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        tint.opacity(0.0),
                        tint
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: tint.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    /// Whether the overlay was on-screen before the native macOS screenshot
    /// UI (Cmd+Shift+3/4/5) began a session. Used to restore visibility
    /// after the session ends.
    private var wasVisibleBeforeNativeScreenshot: Bool = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }

    // MARK: - Native screenshot session yield-and-restore

    /// Hide all overlay windows for the duration of a native macOS screenshot
    /// session (Cmd+Shift+3/4/5). Without this, the full-screen overlay ends
    /// up as the topmost window under the cursor, so the window-mode picker
    /// targets Clicky and the resulting screenshot is black (sharingType=
    /// .none strips its contents). Pairs with `resumeAfterNativeScreenshot`.
    func suspendForNativeScreenshot() {
        wasVisibleBeforeNativeScreenshot = overlayWindows.contains(where: { $0.isVisible })
        for window in overlayWindows {
            window.orderOut(nil)
        }
    }

    /// Restore overlay visibility after the native screenshot session ends.
    /// No-op if the overlay was already hidden when the session began.
    func resumeAfterNativeScreenshot() {
        guard wasVisibleBeforeNativeScreenshot else { return }
        wasVisibleBeforeNativeScreenshot = false
        for window in overlayWindows {
            window.orderFrontRegardless()
        }
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
