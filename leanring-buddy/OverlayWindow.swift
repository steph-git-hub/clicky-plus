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
    ///   cyan    → polish hotkey flash (⌃⌥⌘ or voice "polish") — brief
    ///   yellow  → capture-to-inbox mode (Fn+Shift)
    ///   purple  → Deepgram VTT mode (Fn+Ctrl), raw transcript pastes
    ///   orange  → AssemblyAI VTT mode (Fn+Shift+Opt, fallback chord)
    ///   green   → typing mode (Fn+Cmd), Claude response pastes
    ///   red     → Watch mode (Fn+Opt), screen-frame streaming to Gemini
    ///   magenta → Marin (Realtime/Gemini conversation)
    ///   blue    → idle / default
    /// v15p3fq (2026-05-17): red moved off the disabled burst mode and
    /// onto the new Watch mode; AssemblyAI gets orange so it's distinct
    /// from Deepgram purple even though they share the same downstream
    /// paste pipeline.
    /// Polish flash takes precedence because it's a brief 250ms tap-fire
    /// confirmation; the other modes are sustained holds. Order matters
    /// only defensively — the shortcut layer already ensures the
    /// hold-mode flags can't overlap, and the polish-flash flag is also
    /// gated on `pendingPolishCommandTask == nil` at trigger time.
    /// v15f: maps voiceState to the cursor dot's animation mode.
    /// Used only when cursorIndicatorStyle == "cursorDot" — the dot
    /// becomes the universal indicator across idle/listening/processing
    /// states instead of swapping in the waveform/spinner views.
    private var dotModeForVoiceState: CursorPresenceDot.DotMode {
        // v15p3fv (2026-05-17): Watch mode is always "listening" while
        // the hotkey is held — frames are streaming, mic is open. We
        // key off isVideoWatchModeActive directly instead of waiting
        // for isRealtimeModeActive + realtimeSessionState=.listening
        // to propagate through the binding (which can lag the press
        // by a beat).
        // v15p3fw (2026-05-17): during the post-release response phase
        // (isVideoWatchResponseInFlight && !isVideoWatchModeActive),
        // show the processing spinner. The dot stays red the whole
        // time but the animation shifts from "listening halo" to
        // "thinking spinner" so the user knows the model is generating.
        if companionManager.isVideoWatchModeActive {
            return .listening
        }
        if companionManager.isVideoWatchResponseInFlight {
            return .processing
        }
        // v15p3 (2026-05-06): bridge Realtime state into the dot
        // indicator the same way `lineModeForVoiceState` does.
        //
        // v15p3ff (2026-05-17): use STICKY realtimeMarinAudioStarted
        // flag (true from first audio chunk until turn end) instead
        // of instantaneous output level. Spinner shows only during
        // the thinking phase (state .responding, audio not yet
        // started). Once audio starts, dot mode flips to .listening
        // and stays there until turn ends. No oscillation because
        // the flag doesn't flip back mid-turn.
        if companionManager.isRealtimeModeActive
            && !companionManager.isRealtimeSuspendedByOtherMode {
            switch companionManager.realtimeSessionState {
            case .listening:
                return .listening
            case .responding:
                return companionManager.realtimeMarinAudioStarted
                    ? .listening
                    : .processing
            case .connecting:
                return .listening
            case .idle, .errored:
                return .idle
            }
        }
        switch companionManager.voiceState {
        case .listening:
            return .listening
        case .processing:
            return .processing
        case .idle, .responding:
            return .idle
        }
    }

    /// v15p3 (2026-05-06): unified "is the listening visual active"
    /// check. Used by waveform + spinner opacity modifiers so they
    /// react to BOTH the legacy voiceState pipeline (VTT/Polish/etc)
    /// AND the Realtime session state. Previously the waveform/spinner
    /// only reacted to voiceState — invisible across Realtime sessions.
    private var isListeningForIndicator: Bool {
        // v15p3fv (2026-05-17): Watch mode is always listening during
        // the hold. Same reason as dotModeForVoiceState — propagation
        // lag through the realtime state binding can leave the
        // indicator stuck idle for the first ~100ms.
        if companionManager.isVideoWatchModeActive {
            return true
        }
        if companionManager.isRealtimeModeActive
            && !companionManager.isRealtimeSuspendedByOtherMode {
            return companionManager.realtimeSessionState == .listening
        }
        return companionManager.voiceState == .listening
    }

    private var isProcessingForIndicator: Bool {
        // v15p3ff (2026-05-17): spinner shows only during the actual
        // "loading" phase — state .responding AND audio hasn't
        // started yet. Once first audio arrives, sticky flag flips
        // and spinner hides for the rest of the turn. No oscillation.
        if companionManager.isRealtimeModeActive
            && !companionManager.isRealtimeSuspendedByOtherMode {
            switch companionManager.realtimeSessionState {
            case .responding:
                return !companionManager.realtimeMarinAudioStarted
            case .connecting:
                return false
            case .listening, .idle, .errored:
                return false
            }
        }
        return companionManager.voiceState == .processing
    }

    /// v15i: capture the most-recent NON-default tint so the indicator
    /// keeps the active mode color through the processing phase.
    /// Without this, after VTT (purple), release transitions to .processing
    /// and the mode flag (isVoiceToTextModeActive) clears — currentCursorTint
    /// falls back to default blue. With this cache, we keep showing purple
    /// throughout the processing phase too, then back to default blue when
    /// fully idle again.
    @State private var rememberedActiveModeTint: Color = DS.Colors.overlayCursorBlue

    /// The tint to actually use in indicator views — substitutes the
    /// remembered mode tint during processing when no mode flag is set.
    private var indicatorTint: Color {
        if companionManager.voiceState == .processing
            && currentCursorTint == DS.Colors.overlayCursorBlue {
            return rememberedActiveModeTint
        }
        return currentCursorTint
    }

    /// v15g: same idea for edge-line indicators (bottomEdgeLine, sideStrip).
    /// Each indicator is fully self-contained — handles idle, listening
    /// (audio-reactive thickness + opacity), and processing (faster
    /// heartbeat pulse) without falling back to the cursor waveform.
    private var lineModeForVoiceState: EdgeLineIndicator.LineMode {
        // v15p2 (2026-05-03): when Marin owns the mic, derive line
        // mode from HER session state. The legacy voiceState only
        // tracks buddyDictationManager and stays .idle during Marin
        // sessions, which made the indicator a solid pink line with
        // no audio reactivity. This bridges the gap.
        // v15p3ff (2026-05-17): same sticky-flag approach as dot mode.
        // Hide processing visual once audio actually starts; flag
        // doesn't flip back until turn end so no oscillation.
        if companionManager.isRealtimeModeActive
            && !companionManager.isRealtimeSuspendedByOtherMode {
            switch companionManager.realtimeSessionState {
            case .listening:
                return .listening
            case .responding:
                return companionManager.realtimeMarinAudioStarted
                    ? .listening
                    : .processing
            case .connecting:
                return .listening
            case .idle, .errored:
                return .idle
            }
        }
        switch companionManager.voiceState {
        case .listening:
            return .listening
        case .processing:
            return .processing
        case .idle, .responding:
            return .idle
        }
    }

    /// v15p2 (2026-05-03): pick the right audio source for the
    /// indicator's voice-reactive amplitude. When Marin owns the
    /// mic (Realtime active and not suspended-by-other-mode), use
    /// her input RMS. Otherwise fall back to the legacy
    /// buddyDictationManager level used by VTT/Typing/etc.
    private var indicatorAudioPowerLevel: CGFloat {
        // v15p3fv (2026-05-17): Watch mode pipes mic audio through the
        // Gemini manager, which publishes realtimeInputAudioLevel —
        // same source the magenta Marin halo uses. Read it directly
        // so the red watch halo modulates with the user's voice.
        if companionManager.isVideoWatchModeActive {
            return companionManager.realtimeInputAudioLevel
        }
        if companionManager.isRealtimeModeActive
            && !companionManager.isRealtimeSuspendedByOtherMode {
            return companionManager.realtimeInputAudioLevel
        }
        return companionManager.currentAudioPowerLevel
    }

    /// v15g: which non-cursor styles fully replace the waveform/spinner.
    /// When any of these is the selected indicator, the legacy cursor
    /// waveform and spinner views are hidden — the indicator itself
    /// handles all states with its own animation language.
    private var selfContainedStyleActive: Bool {
        cursorIndicatorStyle == "cursorDot"
            || cursorIndicatorStyle == "cursorDotRing"
            || cursorIndicatorStyle == "bottomEdgeLine"
            || cursorIndicatorStyle == "sideStrip"
    }

    private var currentCursorTint: Color {
        if companionManager.isPolishCommandFlashActive
            || companionManager.isPolishHotkeyModifierCaptureModeActive {
            // v15p3gz (2026-05-18): swapped with Deepgram VTT (was cyan).
            // Steph uses VTT more, prefers cyan for the high-frequency
            // mode and purple for the rarer polish flash.
            return DS.Colors.overlayCursorPurple
        }
        // v15p3fv (2026-05-17): Watch mode now wins OVER Marin's magenta.
        // Watch opens a Gemini session, so isRealtimeModeActive ALSO
        // becomes true during a watch hold — without this reorder,
        // magenta would win and the red indicator would never show.
        // v15p3fw (2026-05-17): also cover isVideoWatchResponseInFlight
        // so the indicator stays red THROUGH the post-release response
        // phase (1-2s while Gemini generates the description). Without
        // this, isVideoWatchModeActive flipped false on release but
        // isRealtimeModeActive stayed true (WS alive), so the cursor
        // briefly flashed magenta between release and session close.
        if companionManager.isVideoWatchModeActive
            || companionManager.isVideoWatchResponseInFlight {
            return DS.Colors.overlayCursorRed
        }
        // v15p3bb (2026-05-11): magenta whenever Marin is alive. Steph
        // explicitly wants visual confirmation Marin is listening even
        // when other modes are technically pressed — losing magenta
        // because of the suspended-by-other-mode check left him with
        // no way to tell whether Marin was still active. The other
        // modes (Polish/cyan above, others below) only win on their
        // own active flag — this just means Marin out-prioritizes
        // them when she's alive, except Polish (which is mid-paste
        // visual feedback and rare).
        if companionManager.isRealtimeModeActive {
            return DS.Colors.overlayCursorMagenta
        }
        if companionManager.isCaptureToInboxModeActive {
            return DS.Colors.overlayCursorYellow
        }
        // v15p3fq (2026-05-17): AssemblyAI VTT moved from purple →
        // orange. Steph wanted a visually distinct color from Deepgram
        // (which took purple) so the active provider is obvious at a
        // glance.
        if companionManager.isVoiceToTextModeActive {
            return DS.Colors.overlayCursorOrange
        }
        if companionManager.isTypingModeActive {
            return DS.Colors.overlayCursorGreen
        }
        // v15p3hx (2026-05-19): single VTT hotkey, color follows the
        // selected provider — cyan for Deepgram, orange for AssemblyAI.
        // The active-mode flag is still isVoiceToTextDeepgramModeActive
        // because the hotkey wiring hasn't been renamed.
        if companionManager.isVoiceToTextDeepgramModeActive {
            switch companionManager.selectedVTTProvider {
            case "scribe": return DS.Colors.overlayCursorOrange
            default: return DS.Colors.overlayCursorCyan
            }
        }
        if companionManager.isBurstModeActive || companionManager.isBurstResponseCycleInFlight {
            // v15p3fq (2026-05-17): burst mode is functionally retired
            // (v13t). This branch is kept defensively in case any stale
            // path flips the flag, but uses orange now since red moved
            // to Watch mode. Realistically should never fire.
            return DS.Colors.overlayCursorOrange
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
                    cursorIndicatorStyle == "glow" && presenceVisible
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

            // v15 (2026-05-01): cursor dot — tiny pulsing dot tucked at
            // bottom-right of cursor (+18, +18 from actual cursor).
            // v15f: dot is now the UNIVERSAL indicator across all states
            // when cursorDot is selected — replaces the waveform during
            // listening (dot scales with audio level) and the spinner
            // during processing (dot inside a spinning ring). Tint
            // automatically reflects active mode color via currentCursorTint.
            CursorPresenceDot(
                tint: indicatorTint,
                mode: dotModeForVoiceState,
                audioPowerLevel: indicatorAudioPowerLevel
            )
                .opacity(
                    cursorIndicatorStyle == "cursorDot" && buddyIsVisibleOnThisScreen
                        ? cursorOpacity : 0
                )
                .position(
                    x: cursorPosition.x - 17,
                    y: cursorPosition.y - 7
                )
                .animation(.linear(duration: 0.04), value: cursorPosition)
                .animation(.easeInOut(duration: 0.2), value: companionManager.voiceState)
                .animation(.linear(duration: 0.04), value: cursorPosition)
                .animation(.easeIn(duration: 0.20), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.12), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isTypingModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isBurstModeActive)
                .animation(.easeOut(duration: 0.12), value: companionManager.isCaptureToInboxModeActive)

            // v16qd (2026-06-07): action-confirmation capsule AT THE
            // CURSOR. Steph misses the notch badge ("I need the visual
            // indicator to be where my mouse goes") and spoken acks are
            // out (tone) — so memory saves / ClickUp creates flash a
            // small green labeled capsule beside the pointer for ~2.5s.
            // Label says WHAT happened ("✓ Saved" / "✓ ClickUp task")
            // so the confirmation is never ambiguous. Rendered for every
            // indicator style; rides memorySaveBadge (auto-clears).
            Text(companionManager.memorySaveBadge ?? " ")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.green.opacity(0.92)))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                .opacity(
                    companionManager.memorySaveBadge != nil && isCursorOnThisScreen
                        ? 1 : 0
                )
                .scaleEffect(companionManager.memorySaveBadge != nil ? 1.0 : 0.6)
                .position(
                    x: cursorPosition.x + 12,
                    y: cursorPosition.y - 32
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: companionManager.memorySaveBadge != nil)
                .animation(.linear(duration: 0.04), value: cursorPosition)

            // v15p3z (2026-05-10): cursor dot + sonar ring variant.
            // Same dot as `cursorDot` but the dot itself stays a fixed
            // small size; an expanding faint ring around it (sonar-style)
            // carries the audio-level feedback. Steph asked for an
            // alternative because the standard dot's growth gets too big
            // at peaks. Toggleable via the indicator picker — switching
            // back to "Cursor dot" reverts.
            CursorDotWithSonarRing(
                tint: indicatorTint,
                mode: dotModeForVoiceState,
                audioPowerLevel: indicatorAudioPowerLevel
            )
                .opacity(
                    cursorIndicatorStyle == "cursorDotRing" && buddyIsVisibleOnThisScreen
                        ? cursorOpacity : 0
                )
                .position(
                    x: cursorPosition.x - 17,
                    y: cursorPosition.y - 7
                )
                .animation(.linear(duration: 0.04), value: cursorPosition)
                .animation(.easeInOut(duration: 0.2), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.12), value: companionManager.isVoiceToTextModeActive)

            // v15g: top-edge line — full-screen-width horizontal line.
            // Universal indicator across all voice states — color from
            // currentCursorTint (mode-aware), thickness pulses with audio
            // during listening, faster pulse during processing.
            EdgeLineIndicator(
                orientation: .bottom,
                tint: indicatorTint,
                mode: lineModeForVoiceState,
                audioPowerLevel: indicatorAudioPowerLevel
            )
                .opacity(
                    cursorIndicatorStyle == "bottomEdgeLine" && buddyIsVisibleOnThisScreen
                        ? cursorOpacity : 0
                )
                .animation(.easeIn(duration: 0.20), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.20), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isTypingModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isBurstModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isCaptureToInboxModeActive)

            // v15g: side strip — full-screen-height vertical strip on the
            // right edge. Same universal-indicator pattern as top-edge.
            EdgeLineIndicator(
                orientation: .right,
                tint: indicatorTint,
                mode: lineModeForVoiceState,
                audioPowerLevel: indicatorAudioPowerLevel
            )
                .opacity(
                    cursorIndicatorStyle == "sideStrip" && buddyIsVisibleOnThisScreen
                        ? cursorOpacity : 0
                )
                .animation(.easeIn(duration: 0.20), value: companionManager.voiceState)
                .animation(.easeOut(duration: 0.20), value: companionManager.isVoiceToTextModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isTypingModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isBurstModeActive)
                .animation(.easeOut(duration: 0.20), value: companionManager.isCaptureToInboxModeActive)

            // Waveform — replaces the triangle while listening.
            // Tint encodes the current capture mode:
            //   purple → voice-to-text mode (Fn+Shift), raw transcript pastes
            //   green  → typing mode (Fn+Cmd), Claude response pastes
            //   red    → burst mode (Fn+Shift+Opt), multi-frame capture
            //   blue   → normal push-to-talk voice
            // Order is defensive — the shortcut layer already prevents
            // these flags from overlapping.
            BlueCursorWaveformView(
                audioPowerLevel: indicatorAudioPowerLevel,
                tint: currentCursorTint,
                captureTrigger: companionManager.lastScreenshotCaptureAt
            )
                // v15g: hide waveform when any self-contained indicator
                // style is selected (cursorDot, bottomEdgeLine, sideStrip).
                // Each handles its own listening visual.
                .opacity(
                    buddyIsVisibleOnThisScreen
                        && isListeningForIndicator
                        && !selfContainedStyleActive
                        ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
                .animation(.easeIn(duration: 0.15), value: companionManager.realtimeSessionState)
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
                // v15g: hide spinner when any self-contained indicator
                // style is selected. Each handles its own processing visual.
                .opacity(
                    buddyIsVisibleOnThisScreen
                        && isProcessingForIndicator
                        && !selfContainedStyleActive
                        ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
                .animation(.easeIn(duration: 0.15), value: companionManager.realtimeSessionState)
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
            // v15p3v (2026-05-09): live VTT preview — sits ABOVE the cursor
            // (so it doesn't conflict with the IdeaCapturedToast below).
            // Only shows when there's a partial transcript AND a VTT
            // session is genuinely active (avoids ghost text from prior
            // sessions). Auto-collapses on session end (transcript clears).
            if !companionManager.vttLiveTranscript.isEmpty
                && (companionManager.isVoiceToTextModeActive
                    || companionManager.isVoiceToTextDeepgramModeActive
                    || companionManager.isPolishHotkeyModifierCaptureModeActive)
                && buddyIsVisibleOnThisScreen {
                // v15p3aa (2026-05-10): tint matches the active mode color.
                // v15p3bu (2026-05-13): added Deepgram tint for the
                // A/B test VTT mode.
                // v15p3fq (2026-05-17): tints updated to match the new
                // mode colors — Deepgram purple, AssemblyAI orange,
                // Polish-modifier cyan. The pill always matches the
                // cursor indicator so it's obvious which provider /
                // mode is driving the transcript on screen.
                // v15p3aq (2026-05-11): pinned to the bottom-right of the
                // active screen instead of following the cursor. Steph
                // wanted to try a static position so it doesn't compete
                // for visual space with where he's typing. The pill's
                // .position modifier targets its CENTER, so we offset
                // by half the max width (190) + a small margin.
                // v15p3ar (2026-05-11): pill is now uncapped width/height, so
                // .position (which anchors center) would let it grow off screen.
                // Wrap in a full-screen frame with bottom-trailing alignment
                // so the pill's bottom-right corner stays pinned ~20px from
                // the screen's bottom-right and the content grows up/left.
                LiveVTTPreviewView(
                    transcript: companionManager.vttLiveTranscript,
                    // v15p3fq (2026-05-17): tint resolution updated to
                    // match the new cursor-color mapping. Order matters
                    // because Polish-modifier capture can co-exist with
                    // a VTT mode flag during the engage→polish handoff,
                    // and we want Polish cyan to win in that overlap.
                    // v15p3gz (2026-05-18): polish ↔ Deepgram color
                    // swap. Polish now purple, VTT Deepgram now cyan.
                    tint: companionManager.isPolishHotkeyModifierCaptureModeActive
                        ? DS.Colors.overlayCursorPurple
                        : (companionManager.isVoiceToTextDeepgramModeActive
                            ? DS.Colors.overlayCursorCyan
                            : DS.Colors.overlayCursorOrange)
                )
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .frame(width: screenFrame.width, height: screenFrame.height)
                    .position(x: screenFrame.width / 2, y: screenFrame.height / 2)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                    ))
            }

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
        // v15i: capture the active mode tint while in .listening so the
        // indicator can keep showing that color through .processing
        // (when the underlying mode flag has reset to false).
        // v15p2 hotfix (2026-05-03): always update on .listening entry,
        // including when the active tint is blue (Base PTT). Previously
        // we only stored non-blue tints, which left the cached value
        // stale across mode switches — Base PTT after VTT would inherit
        // VTT's purple on the spinner. Mirroring the live tint each
        // time we enter .listening keeps the spinner accurate.
        .onChange(of: companionManager.voiceState) { newState in
            if newState == .listening {
                rememberedActiveModeTint = currentCursorTint
            }
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

/// v15 (2026-05-01): tiny pulsing dot near the cursor. Universal indicator
/// when cursorIndicatorStyle == "cursorDot" — replaces the waveform during
/// listening (dot scales with audio level) and the spinner during
/// processing (dot inside a slowly-spinning ring).
///
/// State mapping:
///   .idle / .responding → gentle ambient pulse
///   .listening → audio-reactive scale + brighter opacity
///   .processing → static dot inside a spinning dashed ring
///
/// Tint comes from currentCursorTint upstream — automatically picks up
/// the active mode color (purple for VTT, green for typing, cyan for
/// polish, yellow for capture-to-inbox, blue for base PTT).
private struct CursorPresenceDot: View {
    enum DotMode {
        case idle
        case listening
        case processing
    }

    var tint: Color = DS.Colors.overlayCursorBlue
    var mode: DotMode = .idle
    /// 0.0–1.0 audio level. Only used in .listening mode.
    var audioPowerLevel: CGFloat = 0

    private let idleDiameter: CGFloat = 7
    private let baseDiameter: CGFloat = 6
    // v15h: listening max bumped 16 → 26 for more dramatic audio feedback
    private let listeningMaxDiameter: CGFloat = 26

    @State private var processingSpin: Double = 0

    var body: some View {
        // v15p3he (2026-05-18): re-anchor on the dot itself. Same root
        // cause + fix as CursorDotWithSonarRing — overlay alignment on
        // the dot's frame guarantees the processing ring is concentric
        // with the dot by construction, eliminating the off-center halo
        // bug in both indicator styles.
        Circle()
            .fill(tint)
            .frame(width: dotDiameter, height: dotDiameter)
            .opacity(dotOpacity)
            .shadow(color: tint.opacity(0.6), radius: 2)
            .overlay(
                // Processing ring — dashed, slowly spinning.
                Circle()
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    .frame(width: 18, height: 18)
                    .opacity(mode == .processing ? 0.7 : 0)
                    .rotationEffect(.degrees(processingSpin))
            )
            .allowsHitTesting(false)
        .onAppear {
            // v15h: idle is now SOLID (no pulse). Spin animation only used
            // when in .processing state but kept always-on so transitioning
            // into processing has the ring already moving smoothly.
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                processingSpin = 360
            }
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.65), value: dotDiameter)
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private var dotDiameter: CGFloat {
        switch mode {
        case .idle:
            return idleDiameter
        case .listening:
            // v15p3ay (2026-05-11): bumped listening MIN diameter from
            // baseDiameter (6) to baseDiameter+4 (10) so the dot is
            // clearly LARGER than idle (7) at silence — Steph reported
            // listening looked "smaller and dimmer than idle, like she
            // wasn't listening." It still scales up audio-reactively
            // from there.
            let level = max(0, min(1, audioPowerLevel))
            let eased = pow(level, 0.7)
            let listeningMinDiameter: CGFloat = baseDiameter + 4
            return listeningMinDiameter + (listeningMaxDiameter - listeningMinDiameter) * eased
        case .processing:
            return baseDiameter + 1
        }
    }

    private var dotOpacity: Double {
        switch mode {
        case .idle:
            // v15h: solid in idle (no pulse). Steph's call — pulsing is
            // reserved for actual feedback (listening, processing).
            return 0.85
        case .listening:
            // v15p3ay (2026-05-11): bumped silent floor from 0.65 to 0.95
            // so the listening color reads brightly even when nothing
            // is being said. Previously listening at silence was DIMMER
            // than idle (0.65 vs 0.85), so Marin "still listening" after
            // Esc looked like she'd gone idle / blue.
            let level = Double(max(0, min(1, audioPowerLevel)))
            return 0.95 + level * 0.05
        case .processing:
            return 0.85
        }
    }
}

/// v15p3z (2026-05-10): cursor dot + sonar ring. Steph asked for an
/// alternative to the dot-grows-with-volume pattern in CursorPresenceDot
/// because at high audio levels the dot got too big near the cursor.
/// This variant keeps the dot at a stable small size and uses an
/// expanding concentric ring to carry the audio-level signal — like a
/// sonar ping. The ring's radius and opacity both track the audio level:
/// quiet → small bright ring close to dot; loud → large faint ring far
/// from dot. Always returns to the dot when audio drops to zero.
private struct CursorDotWithSonarRing: View {
    // Reuse CursorPresenceDot's enum so callers can pass the same
    // dotModeForVoiceState computed value to both indicator variants
    // without conversion plumbing.
    typealias DotMode = CursorPresenceDot.DotMode

    var tint: Color = DS.Colors.overlayCursorBlue
    var mode: DotMode = .idle
    /// 0.0–1.0 audio level. Only used in .listening mode.
    var audioPowerLevel: CGFloat = 0

    private let dotDiameter: CGFloat = 7
    private let ringMinDiameter: CGFloat = 11
    private let ringMaxDiameter: CGFloat = 36

    // v15p4cq (2026-06-01): SINGLE-DRAW CANVAS. Prior approaches (v15p3bz
    // ZStack+frame, v15p3dg compositingGroup, v15p3he overlay-on-dot) all
    // chased STATIC concentricity — making the ring centered on the dot at
    // rest. But Steph reports the off-center halo is INTERMITTENT, not
    // constant, which rules out a fixed geometry/alignment error. The real
    // cause is a two-layer animation RACE: the dot's .position animates on
    // one curve while the ring's frame animates on another (.spring), so in
    // the window where both interpolate at once — fast cursor move, an audio
    // spike mid-move, or a scale-factor change on the Sceptre — SwiftUI
    // resolves the overlay's center against momentarily mid-flight bounds and
    // the ring drifts a pixel or two off the dot. Subpixel rounding at high
    // pixel density makes it visible.
    //
    // Fix: draw the dot + sonar ring + processing ring in ONE Canvas pass,
    // all from the SAME center point (rect.mid). There is no second view
    // layer, no overlay alignment, and no independent per-layer animation to
    // desync — the three shapes are mathematically incapable of being
    // off-center from each other because they share one CGPoint. The fixed
    // 40x40 canvas frame keeps `.position` placement stable; animation of the
    // ring size/spin is driven by the values feeding the draw, not by
    // animating separate child frames.
    private let canvasSide: CGFloat = 40
    // Processing ring spin period (seconds for a full 360°). Matches the
    // prior .rotationEffect cadence (1.2s/rev).
    private let spinPeriod: Double = 1.2

    var body: some View {
        // v15p4cs (2026-06-01): wrap the Canvas in TimelineView(.animation).
        // A Canvas does NOT continuously redraw from a one-shot
        // withAnimation(repeatForever) value — SwiftUI only re-runs the draw
        // closure when an *input* changes, so the v15p4cq spin animation drew
        // the dashed processing ring once and froze it (Steph: "frozen broken
        // line halo"). TimelineView(.animation) gives the Canvas a real
        // per-frame clock; we derive the spin angle from that clock so the
        // ring rotates smoothly. The single-draw concentricity from v15p4cq is
        // preserved — all shapes still draw from one shared center point.
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Sonar ring — listening only. Drawn first so dot sits on top.
                if sonarOpacity > 0 {
                    let r = sonarDiameter / 2
                    let ringRect = CGRect(
                        x: center.x - r, y: center.y - r,
                        width: sonarDiameter, height: sonarDiameter
                    )
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color(tint.opacity(sonarOpacity)),
                        lineWidth: 1.4
                    )
                }

                // Processing ring — dashed, spinning, concentric by construction.
                if mode == .processing {
                    // Spin angle derived from the timeline clock so the Canvas
                    // actually re-renders each frame.
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (t.truncatingRemainder(dividingBy: spinPeriod) / spinPeriod) * 360.0
                    let pr: CGFloat = 9 // 18pt diameter
                    let procRect = CGRect(
                        x: center.x - pr, y: center.y - pr,
                        width: pr * 2, height: pr * 2
                    )
                    var procCtx = context
                    procCtx.translateBy(x: center.x, y: center.y)
                    procCtx.rotate(by: .degrees(angle))
                    procCtx.translateBy(x: -center.x, y: -center.y)
                    procCtx.stroke(
                        Path(ellipseIn: procRect),
                        with: .color(tint.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5])
                    )
                }

                // Dot — always, same center.
                let dr = dotDiameter / 2
                let dotRect = CGRect(
                    x: center.x - dr, y: center.y - dr,
                    width: dotDiameter, height: dotDiameter
                )
                context.fill(
                    Path(ellipseIn: dotRect),
                    with: .color(tint.opacity(dotOpacity))
                )
            }
        }
        .frame(width: canvasSide, height: canvasSide)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.18, dampingFraction: 0.65), value: sonarDiameter)
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private var sonarDiameter: CGFloat {
        guard mode == .listening else { return ringMinDiameter }
        let level = max(0, min(1, audioPowerLevel))
        let eased = pow(level, 0.7)
        return ringMinDiameter + (ringMaxDiameter - ringMinDiameter) * eased
    }

    private var sonarOpacity: Double {
        guard mode == .listening else { return 0 }
        let level = Double(max(0, min(1, audioPowerLevel)))
        // As the ring expands outward it fades, like a real sonar ping.
        // Min 0.15 so a quiet voice still shows something; max 0.55 so it
        // doesn't compete with the dot for attention.
        return 0.15 + (0.55 - 0.15) * (1 - level * 0.6)
    }

    private var dotOpacity: Double {
        switch mode {
        case .idle:
            return 0.85
        case .listening:
            // Slight dot brighten with audio so there's a subtle secondary
            // signal beyond the ring. Not the primary feedback.
            let level = Double(max(0, min(1, audioPowerLevel)))
            return 0.80 + level * 0.15
        case .processing:
            return 0.85
        }
    }
}

/// v15: full-screen-edge indicator. Spans the full length of one screen
/// edge. Used by both the top-edge line (orientation: .bottom, horizontal,
/// full screen width) and the side-strip indicator (orientation: .right,
/// vertical, full screen height).
///
/// v15g: edge-line is now a UNIVERSAL indicator across all states like
/// the cursor dot. Replaces the waveform during listening (line thickens
/// + brightens with audio level) and the spinner during processing (line
/// pulses faster, like a heartbeat). Tint comes from currentCursorTint
/// upstream so color matches the active mode.
private struct EdgeLineIndicator: View {
    enum Orientation {
        // v15j (2026-05-01): renamed .top → .bottom because Steph's eyes
        // are at the bottom of the screen (text inputs live there). The
        // line renders at the bottom edge; the halo blooms upward.
        case bottom
        case right
    }
    enum LineMode {
        case idle
        case listening
        case processing
    }

    let orientation: Orientation
    var tint: Color = DS.Colors.overlayCursorBlue
    var mode: LineMode = .idle
    /// 0.0–1.0 audio level. Only used in .listening mode.
    var audioPowerLevel: CGFloat = 0

    private let processingPulseDuration: Double = 0.65

    // v15h: idle is SOLID (no pulse). One fixed opacity per state.
    private let idleOpacity: Double = 0.85
    private let processingMinOpacity: Double = 0.55
    private let processingMaxOpacity: Double = 1.0

    // v15i: line is now a TWO-LAYER glow:
    //   - inner solid core (constant thickness, always visible)
    //   - outer gradient halo (expands inward with audio level, fades
    //     to transparent at the far edge — like Claude's listening UI)
    //
    // Idle: just the core (no halo).
    // Listening: core stays consistent + halo extends with audio level.
    // Processing: core does the heartbeat pulse; no halo.
    private let topCoreThickness: CGFloat = 3
    private let sideCoreThickness: CGFloat = 3
    private let haloMaxExtension: CGFloat = 80   // inward extension at peak audio
    private let haloPeakOpacity: Double = 0.55   // alpha at the line edge of the halo

    @State private var processingPulse: Bool = false

    var body: some View {
        ZStack(alignment: orientation == .bottom ? .bottom : .trailing) {
            Color.clear

            // v15l: LOADING SHIMMER — only visible during processing.
            // A brighter highlight slides along the line continuously,
            // giving an obvious "loading is happening" cue distinct from
            // both idle (static) and listening (audio-reactive halo).
            if mode == .processing {
                LineLoadingShimmer(orientation: orientation, tint: tint)
            }

            // OUTER HALO — listening only. Linear gradient from full
            // tint at the line edge to transparent at the far end.
            // Extends inward (top → downward, right → leftward).
            Rectangle()
                .fill(haloGradient)
                .frame(
                    width: orientation == .right ? haloExtension : nil,
                    height: orientation == .bottom ? haloExtension : nil
                )
                .frame(
                    maxWidth: orientation == .bottom ? .infinity : haloExtension,
                    maxHeight: orientation == .right ? .infinity : haloExtension
                )
                .opacity(haloOpacity)
                .allowsHitTesting(false)

            // INNER SOLID CORE — always present in self-contained mode.
            // Idle = static, listening = same constant thickness (the
            // halo provides the audio-reactive feedback), processing =
            // heartbeat opacity pulse on the core itself.
            Rectangle()
                .fill(tint)
                .frame(
                    width: orientation == .right ? sideCoreThickness : nil,
                    height: orientation == .bottom ? topCoreThickness : nil
                )
                .frame(
                    maxWidth: orientation == .bottom ? .infinity : sideCoreThickness,
                    maxHeight: orientation == .right ? .infinity : topCoreThickness
                )
                .opacity(coreOpacity)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.18), value: mode)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: audioPowerLevel)
        .onAppear {
            // v15h: idle is solid — only kick off the processing-state
            // animation. (Idle no longer pulses per Steph's call.)
            withAnimation(
                .easeInOut(duration: processingPulseDuration).repeatForever(autoreverses: true)
            ) {
                processingPulse = true
            }
        }
    }

    /// Halo gradient — full tint at the line edge, transparent at the
    /// far end. Direction depends on orientation.
    private var haloGradient: LinearGradient {
        let stops: [Gradient.Stop] = [
            .init(color: tint.opacity(haloPeakOpacity), location: 0.0),
            .init(color: tint.opacity(0), location: 1.0)
        ]
        switch orientation {
        case .bottom:
            // Halo blooms UPWARD from the bottom edge — full color at
            // the bottom (where the solid core lives), fading to
            // transparent at the top of the halo region.
            return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
        case .right:
            return LinearGradient(stops: stops, startPoint: .trailing, endPoint: .leading)
        }
    }

    /// How far the halo extends inward. Zero in idle/processing,
    /// scales 0..haloMaxExtension with audio level during listening.
    private var haloExtension: CGFloat {
        switch mode {
        case .idle, .processing:
            return 0
        case .listening:
            let level = max(0, min(1, audioPowerLevel))
            // Use a slightly less aggressive easing than core thickness
            // — the halo should grow visibly even at moderate audio levels
            let eased = pow(level, 0.55)
            return haloMaxExtension * eased
        }
    }

    /// Halo opacity multiplier — 0 in idle/processing, audio-reactive
    /// during listening (so the halo fades in/out smoothly with voice).
    private var haloOpacity: Double {
        switch mode {
        case .idle, .processing:
            return 0
        case .listening:
            let level = Double(max(0, min(1, audioPowerLevel)))
            return 0.4 + level * 0.6
        }
    }

    /// Inner core opacity — constant in idle/listening, heartbeat in processing.
    private var coreOpacity: Double {
        switch mode {
        case .idle, .listening:
            return idleOpacity
        case .processing:
            return processingPulse ? processingMaxOpacity : processingMinOpacity
        }
    }
}

/// v15l: a brighter "highlight" segment that slides along an edge-line
/// indicator during processing. Provides the obvious "loading is
/// happening" visual that the prior heartbeat opacity pulse lacked.
/// The shimmer is short relative to the full line and moves left→right
/// (bottom edge) or top→bottom (right edge) on a continuous loop.
private struct LineLoadingShimmer: View {
    let orientation: EdgeLineIndicator.Orientation
    let tint: Color

    /// What fraction of the line length the shimmer spans.
    private let shimmerLengthFraction: CGFloat = 0.28
    /// How long one full traversal takes. Faster = more urgent feeling.
    private let cycleDuration: Double = 1.4
    /// Shimmer thickness — slightly thicker than the core line so it
    /// reads as a brighter "puck" overlay rather than a same-thickness
    /// segment that just travels.
    private let shimmerThickness: CGFloat = 5

    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            let length = orientation == .bottom ? geo.size.width : geo.size.height
            let shimmerLength = max(60, length * shimmerLengthFraction)

            Rectangle()
                .fill(LinearGradient(
                    colors: [
                        tint.opacity(0),
                        tint.opacity(1.0),
                        tint.opacity(0)
                    ],
                    startPoint: orientation == .bottom ? .leading : .top,
                    endPoint: orientation == .bottom ? .trailing : .bottom
                ))
                .frame(
                    width: orientation == .bottom ? shimmerLength : shimmerThickness,
                    height: orientation == .bottom ? shimmerThickness : shimmerLength
                )
                .offset(
                    x: orientation == .bottom ? phase * length : 0,
                    y: orientation == .right ? phase * length : 0
                )
        }
        .frame(
            maxWidth: orientation == .bottom ? .infinity : shimmerThickness,
            maxHeight: orientation == .right ? .infinity : shimmerThickness
        )
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: cycleDuration).repeatForever(autoreverses: false)) {
                // Start off-screen to the leading edge, end off-screen at
                // the trailing edge — gives a clean continuous traverse.
                phase = 1.0
            }
        }
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

/// v15p3v (2026-05-09): live preview overlay for in-flight dictation.
/// Shows the active provider's streaming partial transcript above the
/// cursor during VTT or Polish-modifier capture. Lets Steph see his
/// words landing as he speaks. Distinct from IdeaCapturedToast (yellow,
/// post-capture) — this is mode-tinted, pre-finalize, only shows during
/// active dictation. Empty transcript = view collapses.
/// v15p3aa (2026-05-10): tint is now driven by the active mode.
/// v15p3fq (2026-05-17): tints are Deepgram purple, AssemblyAI orange,
/// Polish-modifier cyan — matching the cursor indicator so the pill
/// rest of the visual language for that mode.
private struct LiveVTTPreviewView: View {
    let transcript: String
    // v15p3gz (2026-05-18): default now cyan to match the Deepgram VTT
    // color swap. Polish-modifier callers pass overlayCursorPurple.
    var tint: Color = DS.Colors.overlayCursorCyan

    // v15p3at (2026-05-11): Steph wants width capped (back to 380) but no
    // line cap — text wraps within the pill, height grows as content adds,
    // anchored to bottom-right. Only vertical expansion.
    var body: some View {
        Text(transcript)
            .font(.system(size: 13, weight: .regular, design: .default))
            .foregroundColor(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 350, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.35), radius: 10, x: 0, y: 3)
            .allowsHitTesting(false)
    }
}

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

    // v15p3 (2026-05-06): screen-change handling for sleep/wake.
    // The cursor-following overlay used to get stuck on the primary screen
    // after the Mac slept and woke with multiple monitors attached. Root
    // cause: BlueCursorView captures its `screenFrame` as an immutable
    // `let` at init, and the per-frame cursor-tracking timer tested
    // `screenFrame.contains(mouseLocation)` against that stale value
    // forever. macOS rebuilds the screen list on wake, but nothing in
    // this app subscribed to the geometry-changed notifications, so
    // the indicator's `isCursorOnThisScreen` check would never go true
    // for the cursor's actual second-monitor position until restart.
    //
    // Fix: subscribe to didChangeScreenParametersNotification (and the
    // workspace didWake notification as a belt-and-suspenders) and tear
    // down + recreate overlay windows on the current screen list. Debounced
    // so a flurry of notifications during display reconfiguration coalesces
    // into one rebuild.
    private weak var lastCompanionManager: CompanionManager?
    private var screenParametersObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var pendingScreenChangeWorkItem: DispatchWorkItem?

    init() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleOverlayRecreate() }
        }
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleOverlayRecreate() }
        }
    }

    deinit {
        if let obs = screenParametersObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    /// Coalesce multiple screen-change / wake notifications into a single
    /// overlay rebuild ~300ms after the last event. macOS often posts a
    /// rapid burst during display reconfiguration; rebuilding on every one
    /// would thrash. Only recreates if the overlay is currently visible —
    /// if it's hidden, the next `showOverlay()` call will pick up fresh
    /// `NSScreen.screens` automatically.
    private func scheduleOverlayRecreate() {
        pendingScreenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.overlayWindows.isEmpty,
                  let companionManager = self.lastCompanionManager else { return }
            self.showOverlay(onScreens: NSScreen.screens, companionManager: companionManager)
        }
        pendingScreenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Remember the manager so we can rebuild on screen-parameter change.
        lastCompanionManager = companionManager

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
