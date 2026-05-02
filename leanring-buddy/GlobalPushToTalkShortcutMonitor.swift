//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the screenshot-burst shortcut (Fn+Shift+Opt).
    /// Kept as its own stream so existing push-to-talk subscribers do not
    /// receive burst events and vice versa.
    let burstTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the typing-mode shortcut (Fn + Cmd).
    /// Typing mode takes a single screenshot + short voice command, sends
    /// them to Claude, and pastes the response into whatever field has
    /// focus. Having its own publisher keeps the three shortcut paths
    /// (normal PTT, burst, typing) independent.
    let typingTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the voice-to-text shortcut (Fn + Shift).
    /// Voice-to-text is pure transcription — no Claude, no TTS — the
    /// transcript is pasted directly into the focused field. Kept on
    /// its own publisher so a key event can never toggle multiple modes.
    let voiceToTextTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the capture-to-inbox shortcut (Fn + Shift, v15p2).
    /// Capture-to-inbox is pure transcription that appends directly to the
    /// user's Obsidian Idea Inbox — no paste, no Claude, no TTS. Kept on
    /// its own publisher for the same independence guarantees as the rest.
    let captureToInboxTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the Realtime conversation shortcut (Fn + Opt, v15p2).
    /// Holds Fn+Opt → opens an OpenAI Realtime API WebSocket session for live
    /// speech-to-speech. Audio is streamed bidirectionally rather than
    /// transcribed-then-acted-on like the other modes.
    let realtimeTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Separate publisher for the polish hotkey (⌃⌥⌘ tap). Unlike the
    /// other 5 modes, polish is NOT a hold — subscribers should only
    /// react to `.pressed` transitions and ignore `.released`. Polish
    /// reads the focused field's existing text via AX, sends it to the
    /// Worker's /voice-command route, and pastes the cleaned result back.
    let polishHotkeyTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Fires when the user double-taps the Control modifier alone (no chord).
    /// CompanionManager treats this as "engage VTT lock." Used to start a
    /// no-hold dictation session.
    let controlDoubleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires when the user double-taps the Command modifier alone (no chord).
    let commandDoubleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires when the user double-taps the Option modifier alone (no chord).
    /// v12s (2026-04-28): used to engage hands-free base voice mode with
    /// click-to-capture. Option chosen because it doesn't override click
    /// behavior in macOS the way Cmd/Ctrl do.
    let optionDoubleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires on a single confirmed tap of Control alone (no chord). CompanionManager
    /// treats this as "disengage VTT lock if active" — a quick way to end a
    /// no-hold dictation session without moving fingers to Esc. Confirmed
    /// means: <180ms press, no chord during the press, and no second tap
    /// arrived within the 300ms double-tap window.
    let controlSingleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires on a single confirmed tap of Command alone. Mirrors control.
    let commandSingleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires on a single confirmed tap of Option alone. Used to disengage
    /// hands-free voice-mode toggle (v12s).
    let optionSingleTapPublisher = PassthroughSubject<Void, Never>()
    /// Fires on Escape key press. CompanionManager uses this to unlock
    /// any active double-tap-toggled dictation session.
    let escapeKeyPublisher = PassthroughSubject<Void, Never>()

    /// Publisher for the native macOS screenshot session (Cmd+Shift+3/4/5).
    /// Emits `true` when a screenshot shortcut is pressed — subscribers should
    /// hide any full-screen overlays immediately so macOS's window-mode picker
    /// (Cmd+Shift+4 → space) can target the real window under the cursor.
    /// Emits `false` when the session ends (Esc, user clicks to take the shot,
    /// or a 30-second safety timeout). Delivered synchronously on the main
    /// thread — do not add `.receive(on:)` when subscribing, the overlay must
    /// be hidden before `screencaptureui` snapshots the window list.
    let nativeScreenshotSessionPublisher = PassthroughSubject<Bool, Never>()
    @Published private(set) var isNativeScreenshotSessionActive: Bool = false
    private var nativeScreenshotTimeoutTask: DispatchWorkItem?

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    /// Parallel state for the burst shortcut. Mirrors the tracking semantics
    /// of `isShortcutCurrentlyPressed` but lives independently.
    @Published private(set) var isBurstShortcutCurrentlyPressed = false
    /// Parallel state for the typing-mode shortcut. Same tracking semantics
    /// as the other two, kept separate so a single key event cannot
    /// accidentally toggle more than one mode at a time.
    @Published private(set) var isTypingShortcutCurrentlyPressed = false
    /// Parallel state for the voice-to-text shortcut (Fn + Shift). Same
    /// independence guarantees as the other three — a single key event
    /// cannot toggle more than one mode.
    @Published private(set) var isVoiceToTextShortcutCurrentlyPressed = false
    /// Parallel state for the capture-to-inbox shortcut (Fn + Shift, v15p2).
    @Published private(set) var isCaptureToInboxShortcutCurrentlyPressed = false
    /// Parallel state for the Realtime conversation shortcut (Fn + Opt, v15p2).
    @Published private(set) var isRealtimeShortcutCurrentlyPressed = false
    /// Parallel state for the polish hotkey (⌃⌥⌘). Tracked the same way
    /// as the other modes so press/release transitions debounce correctly,
    /// even though only `.pressed` is acted upon downstream.
    @Published private(set) var isPolishHotkeyShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        // `.leftMouseUp` is observed so we can detect when the user takes
        // a native screenshot via Cmd+Shift+4/5 and click — that click's
        // mouse-up ends the screenshot session so the overlay can restore.
        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        isBurstShortcutCurrentlyPressed = false
        isTypingShortcutCurrentlyPressed = false
        isVoiceToTextShortcutCurrentlyPressed = false
        isCaptureToInboxShortcutCurrentlyPressed = false
        isPolishHotkeyShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Native screenshot shortcut (Cmd+Shift+3/4/5) detection is handled
        // first so the overlay yield fires synchronously on the same run-loop
        // tick as the keyDown — before macOS's screencaptureui snapshots the
        // window list for its window-mode picker.
        handleNativeScreenshotSession(eventType: eventType, event: event)

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        // Burst shortcut (Fn + Ctrl + Opt) is detected in parallel. It only
        // cares about flagsChanged events and never conflicts with the
        // normal push-to-talk above because shortcutTransition already
        // rejects events that include .function.
        let burstTransition = BuddyPushToTalkShortcut.burstTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasBurstPreviouslyPressed: isBurstShortcutCurrentlyPressed
        )

        switch burstTransition {
        case .none:
            break
        case .pressed:
            isBurstShortcutCurrentlyPressed = true
            burstTransitionPublisher.send(.pressed)
        case .released:
            isBurstShortcutCurrentlyPressed = false
            burstTransitionPublisher.send(.released)
        }

        // Typing shortcut (Fn + Cmd) is detected in parallel. Its
        // transition function forbids .shift/.option/.control, so it
        // will not double-fire with burst (Fn+Shift+Opt) or the normal
        // PTT shortcut. Only flagsChanged events produce transitions.
        let typingTransition = BuddyPushToTalkShortcut.typingTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasTypingPreviouslyPressed: isTypingShortcutCurrentlyPressed
        )

        switch typingTransition {
        case .none:
            break
        case .pressed:
            isTypingShortcutCurrentlyPressed = true
            typingTransitionPublisher.send(.pressed)
        case .released:
            isTypingShortcutCurrentlyPressed = false
            typingTransitionPublisher.send(.released)
        }

        // Voice-to-text shortcut (Fn + Shift) is detected in parallel.
        // Its transition function forbids .option/.command/.control,
        // so it can't double-fire with burst (shift+opt+fn), typing
        // (cmd+fn), or normal PTT. Only flagsChanged events produce
        // transitions.
        let voiceToTextTransition = BuddyPushToTalkShortcut.voiceToTextTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasVoiceToTextPreviouslyPressed: isVoiceToTextShortcutCurrentlyPressed
        )

        switch voiceToTextTransition {
        case .none:
            break
        case .pressed:
            isVoiceToTextShortcutCurrentlyPressed = true
            voiceToTextTransitionPublisher.send(.pressed)
        case .released:
            isVoiceToTextShortcutCurrentlyPressed = false
            voiceToTextTransitionPublisher.send(.released)
        }

        // Capture-to-inbox shortcut (Fn + Shift, v15p2) is detected in
        // parallel. Its transition function forbids .option/.command/
        // .control, so it can't double-fire with VTT (fn+ctrl), burst
        // (fn+shift+opt), typing (cmd+fn), Realtime (fn+opt), or
        // normal PTT (ctrl+opt).
        let captureToInboxTransition = BuddyPushToTalkShortcut.captureToInboxTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasCaptureToInboxPreviouslyPressed: isCaptureToInboxShortcutCurrentlyPressed
        )

        switch captureToInboxTransition {
        case .none:
            break
        case .pressed:
            isCaptureToInboxShortcutCurrentlyPressed = true
            captureToInboxTransitionPublisher.send(.pressed)
        case .released:
            isCaptureToInboxShortcutCurrentlyPressed = false
            captureToInboxTransitionPublisher.send(.released)
        }

        // Realtime conversation shortcut (Fn + Opt, v15p2) is detected
        // in parallel. Its transition function forbids .shift/.command/
        // .control, so it can't double-fire with VTT (fn+ctrl),
        // capture-to-inbox (fn+shift), burst (fn+shift+opt), typing
        // (cmd+fn), or normal PTT (ctrl+opt).
        let realtimeTransition = BuddyPushToTalkShortcut.realtimeTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasRealtimePreviouslyPressed: isRealtimeShortcutCurrentlyPressed
        )

        switch realtimeTransition {
        case .none:
            break
        case .pressed:
            isRealtimeShortcutCurrentlyPressed = true
            realtimeTransitionPublisher.send(.pressed)
        case .released:
            isRealtimeShortcutCurrentlyPressed = false
            realtimeTransitionPublisher.send(.released)
        }

        // Polish hotkey (⌃⌥⌘) is detected in parallel. Its transition
        // function forbids .function and .shift, so it cannot
        // double-fire with any of the four Fn-using modes or with
        // normal PTT. The downstream subscriber acts on .pressed only
        // (polish is a tap, not a hold), but we still emit .released
        // so the press-tracking state stays consistent.
        let polishHotkeyTransition = BuddyPushToTalkShortcut.polishHotkeyTransition(
            eventType: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasPolishHotkeyPreviouslyPressed: isPolishHotkeyShortcutCurrentlyPressed
        )

        switch polishHotkeyTransition {
        case .none:
            break
        case .pressed:
            isPolishHotkeyShortcutCurrentlyPressed = true
            polishHotkeyTransitionPublisher.send(.pressed)
        case .released:
            isPolishHotkeyShortcutCurrentlyPressed = false
            polishHotkeyTransitionPublisher.send(.released)
        }

        // Modifier tap detection (single + double, with chord filter) for
        // the Ctrl, Cmd, and Opt toggles. Independent of the hold-shortcuts
        // above. v12s added Opt for hands-free base voice mode.
        ctrlTapState.processFlagsChangedEvent(eventType: eventType, event: event)
        cmdTapState.processFlagsChangedEvent(eventType: eventType, event: event)
        optTapState.processFlagsChangedEvent(eventType: eventType, event: event)

        // Non-modifier keyDown means a chord is happening. Reset all
        // tap trackers so e.g. ⌘+C doesn't look like a single Cmd tap.
        if eventType == .keyDown {
            ctrlTapState.notifyNonModifierKeyDown()
            cmdTapState.notifyNonModifierKeyDown()
            optTapState.notifyNonModifierKeyDown()

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == Self.escapeKeyCode {
                escapeKeyPublisher.send()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier tap detection (single + double, chord-filtered)
    //
    // Detects single and double taps of Ctrl-alone and Cmd-alone, with a
    // strict chord filter so workflows like ⌘+C / ⌃+C don't false-trigger.
    //
    // Behavior:
    //   - Press modifier alone, release within 180ms → tap candidate
    //   - If a second tap arrives within 300ms → DOUBLE TAP fires immediately
    //   - Else after 300ms → SINGLE TAP fires
    //   - Any non-modifier keyDown during the press OR during the wait
    //     window → cancels both pending emits (chord detected)
    //   - Modifier becoming part of a chord (Ctrl+Fn, Cmd+Fn) → cancels
    //
    // Result: every "modifier-alone gesture" produces exactly ONE emit
    // (single OR double), never both. Quick chord usage produces neither.

    static let modifierTapMaxPressDurationSeconds: TimeInterval = 0.18
    static let modifierTapMaxBetweenTapsSeconds: TimeInterval = 0.30

    /// Per-modifier state for tap detection. Each modifier (Ctrl, Cmd) has
    /// its own instance so detections are independent.
    final class ModifierTapState {
        let modifier: NSEvent.ModifierFlags
        let singleTapPublisher: PassthroughSubject<Void, Never>
        let doubleTapPublisher: PassthroughSubject<Void, Never>

        /// Last seen modifier flags so we can detect transitions.
        private var lastSeenFlags: NSEvent.ModifierFlags = []
        /// When the modifier was alone-pressed (waiting for release).
        private var alonePressedAt: Date?
        /// Pending single-tap emit, scheduled for ~300ms after a confirmed
        /// tap release. Cancelled if a second tap arrives, or if a chord
        /// happens during the wait. Fires single-tap if neither.
        private var pendingSingleTapEmit: DispatchWorkItem?
        /// Whether we're currently waiting for a possible second tap.
        private var awaitingSecondTap: Bool = false

        init(
            modifier: NSEvent.ModifierFlags,
            singleTapPublisher: PassthroughSubject<Void, Never>,
            doubleTapPublisher: PassthroughSubject<Void, Never>
        ) {
            self.modifier = modifier
            self.singleTapPublisher = singleTapPublisher
            self.doubleTapPublisher = doubleTapPublisher
        }

        func processFlagsChangedEvent(eventType: CGEventType, event: CGEvent) {
            guard eventType == .flagsChanged else { return }
            let prevFlags = lastSeenFlags
            let currFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
            lastSeenFlags = currFlags

            let prevAlone = prevFlags == modifier
            let currAlone = currFlags == modifier
            let didPressAlone = !prevAlone && currAlone
            let didReleaseAlone = prevAlone && currFlags.isEmpty
            let becameChord = prevAlone && !currFlags.isEmpty && !currAlone

            let now = Date()

            if didPressAlone {
                alonePressedAt = now
            } else if didReleaseAlone, let pressedAt = alonePressedAt {
                alonePressedAt = nil
                let pressDuration = now.timeIntervalSince(pressedAt)
                if pressDuration > GlobalPushToTalkShortcutMonitor.modifierTapMaxPressDurationSeconds {
                    // Held too long — not a tap. Reset tap-pair tracking.
                    cancelPendingEmit()
                    awaitingSecondTap = false
                    return
                }
                if awaitingSecondTap {
                    // This is the second tap of a double-tap. Cancel the
                    // pending single-tap emit and fire double-tap immediately.
                    cancelPendingEmit()
                    awaitingSecondTap = false
                    doubleTapPublisher.send()
                } else {
                    // First (and possibly only) tap. Schedule single-tap
                    // emit for the end of the double-tap window. If a
                    // second tap arrives, we'll cancel and fire double-tap.
                    awaitingSecondTap = true
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.awaitingSecondTap = false
                        self.pendingSingleTapEmit = nil
                        self.singleTapPublisher.send()
                    }
                    pendingSingleTapEmit?.cancel()
                    pendingSingleTapEmit = workItem
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + GlobalPushToTalkShortcutMonitor.modifierTapMaxBetweenTapsSeconds,
                        execute: workItem
                    )
                }
            } else if becameChord {
                // Modifier became part of a chord (Ctrl+Fn, Cmd+Fn, etc.).
                alonePressedAt = nil
                cancelPendingEmit()
                awaitingSecondTap = false
            }
        }

        /// Called when any non-modifier key is pressed. If we're currently
        /// tracking a modifier-alone press OR waiting for a second tap,
        /// this means a chord (e.g. ⌘+C) is happening — cancel everything.
        func notifyNonModifierKeyDown() {
            if alonePressedAt != nil || awaitingSecondTap {
                alonePressedAt = nil
                cancelPendingEmit()
                awaitingSecondTap = false
            }
        }

        private func cancelPendingEmit() {
            pendingSingleTapEmit?.cancel()
            pendingSingleTapEmit = nil
        }
    }

    private lazy var ctrlTapState = ModifierTapState(
        modifier: .control,
        singleTapPublisher: controlSingleTapPublisher,
        doubleTapPublisher: controlDoubleTapPublisher
    )
    private lazy var cmdTapState = ModifierTapState(
        modifier: .command,
        singleTapPublisher: commandSingleTapPublisher,
        doubleTapPublisher: commandDoubleTapPublisher
    )
    /// v12s: Option modifier tap state for hands-free voice-mode toggle.
    private lazy var optTapState = ModifierTapState(
        modifier: .option,
        singleTapPublisher: optionSingleTapPublisher,
        doubleTapPublisher: optionDoubleTapPublisher
    )

    // MARK: - Native macOS screenshot session

    /// Key codes for the top-row number keys that pair with Cmd+Shift to
    /// trigger native macOS screenshot flows on a standard ANSI/ISO layout:
    /// 3 → full screen, 4 → selection (and spacebar window mode), 5 → UI.
    private static let screenshotKeyCode3: UInt16 = 20
    private static let screenshotKeyCode4: UInt16 = 21
    private static let screenshotKeyCode5: UInt16 = 23
    private static let escapeKeyCode: UInt16 = 53

    private func handleNativeScreenshotSession(eventType: CGEventType, event: CGEvent) {
        switch eventType {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let hasCmdShift = flags.contains(.maskCommand) && flags.contains(.maskShift)
            let isScreenshotKey = keyCode == Self.screenshotKeyCode3
                || keyCode == Self.screenshotKeyCode4
                || keyCode == Self.screenshotKeyCode5
            if isScreenshotKey && hasCmdShift && !isNativeScreenshotSessionActive {
                beginNativeScreenshotSession()
                return
            }
            if keyCode == Self.escapeKeyCode && isNativeScreenshotSessionActive {
                endNativeScreenshotSession()
                return
            }
        case .leftMouseUp:
            // The native picker captures on mouse-up. Use that as our signal
            // to restore the overlay once the shot has been grabbed.
            if isNativeScreenshotSessionActive {
                endNativeScreenshotSession()
            }
        default:
            break
        }
    }

    private func beginNativeScreenshotSession() {
        isNativeScreenshotSessionActive = true
        nativeScreenshotSessionPublisher.send(true)
        // Safety timeout — restore overlay if no Esc / mouseUp end event
        // fires within 30s (e.g. Cmd+Shift+5 UI left open indefinitely).
        nativeScreenshotTimeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isNativeScreenshotSessionActive {
                self.endNativeScreenshotSession()
            }
        }
        nativeScreenshotTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: task)
    }

    private func endNativeScreenshotSession() {
        guard isNativeScreenshotSessionActive else { return }
        isNativeScreenshotSessionActive = false
        nativeScreenshotTimeoutTask?.cancel()
        nativeScreenshotTimeoutTask = nil
        nativeScreenshotSessionPublisher.send(false)
    }
}
