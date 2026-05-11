//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace
        /// v15p2 (2026-05-02): Fn+Opt held — new home for Base PTT
        /// after the Realtime↔Base hotkey swap.
        case optionFunction

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            case .optionFunction:
                return "fn + option"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            case .optionFunction:
                return ["fn", "option"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .optionFunction:
                return [.option, .function]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .optionFunction:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    // v15p2 (2026-05-02): swapped from .controlOption (Ctrl+Opt) to
    // .optionFunction (Fn+Opt). Realtime PTT moved to Ctrl+Opt; Base
    // PTT moves here. Easier hotkeys go to Realtime, which is the
    // mode Steph actually uses now.
    static let currentShortcutOption: ShortcutOption = .optionFunction
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            // v15p2 (2026-05-02): mutual-exclusivity logic depends on
            // which option we're using. Old behavior: forbid .function
            // (so we don't double-fire with burst). New for .optionFunction:
            // we REQUIRE .function, so the forbidden flags shift to
            // shift/command/control to keep us mutually exclusive with
            // VTT (fn+ctrl), capture (fn+shift), typing (cmd+fn), and
            // the new Realtime PTT (ctrl+opt).
            let hasRequired = modifierFlags.isSuperset(of: modifierOnlyFlags)
            let hasForbidden: Bool
            switch currentShortcutOption {
            case .optionFunction:
                hasForbidden = modifierFlags.contains(.shift)
                    || modifierFlags.contains(.control)
                    || modifierFlags.contains(.command)
            default:
                // Original behavior for legacy chords: Fn is forbidden.
                hasForbidden = modifierFlags.contains(.function)
            }
            let isShortcutCurrentlyPressed = hasRequired && !hasForbidden

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }

    // MARK: - Burst Mode (Screenshot Burst) Shortcut
    //
    // Burst mode is activated by holding Fn + Control + Option.
    // This is additive — it does NOT replace or interfere with the normal
    // push-to-talk shortcut (Control + Option). The normal shortcut detector
    // above explicitly ignores events where .function is held, so the two
    // modes are mutually exclusive and never fire together.

    // Burst hotkey: Fn + Shift + Option.
    // Notably does NOT include .control, because holding Ctrl while clicking
    // is hardwired by macOS to mean "secondary click" (right-click) — which
    // made it impossible to click browser tabs while recording a burst.
    // Normal push-to-talk (Ctrl+Opt) still works unchanged because the
    // normal detector explicitly rejects any event that includes .function.
    static let burstModifierFlags: NSEvent.ModifierFlags = [.shift, .option, .function]

    /// Returns the burst-shortcut transition for a given modifier flag change.
    /// Only responds to .flagsChanged events (burst mode is modifier-only,
    /// no key code required).
    static func burstTransition(
        for event: NSEvent,
        wasBurstPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard event.type == .flagsChanged else { return .none }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return burstTransition(
            modifierFlags: flags,
            wasBurstPreviouslyPressed: wasBurstPreviouslyPressed
        )
    }

    /// Overload for CGEvent taps that pass raw modifier flags (UInt64).
    static func burstTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasBurstPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return burstTransition(
            modifierFlags: flags,
            wasBurstPreviouslyPressed: wasBurstPreviouslyPressed
        )
    }

    private static func burstTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasBurstPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let isBurstCurrentlyPressed = modifierFlags.isSuperset(of: burstModifierFlags)

        if isBurstCurrentlyPressed && !wasBurstPreviouslyPressed {
            return .pressed
        }
        if !isBurstCurrentlyPressed && wasBurstPreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Typing Mode (Dictated Draft → Clipboard + Paste) Shortcut
    //
    // Cmd + Fn triggers "typing mode": the user speaks a request, Clicky
    // calls Claude with the spoken transcript + a single screenshot, then
    // copies the response to the clipboard and pastes it into whatever
    // text field is focused. Additive — fully isolated from normal
    // push-to-talk (Ctrl+Opt) and burst (Fn+Shift+Opt).
    //
    // To prevent any overlap with burst, the typing detector requires
    // Cmd+Fn to be held WITHOUT shift, option, or control. That way
    // holding Cmd+Shift+Opt+Fn (if that ever happens) fires burst only.

    static let typingModifierFlags: NSEvent.ModifierFlags = [.command, .function]

    static func typingTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasTypingPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return typingTransition(
            modifierFlags: flags,
            wasTypingPreviouslyPressed: wasTypingPreviouslyPressed
        )
    }

    private static func typingTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasTypingPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        // Must have Cmd + Fn, and must NOT include shift, option, or
        // control — otherwise it's ambiguous with burst (shift+opt+fn)
        // or a future combo and we'd fire two modes at once.
        let hasRequired = modifierFlags.isSuperset(of: typingModifierFlags)
        let hasForbidden = modifierFlags.contains(.shift)
            || modifierFlags.contains(.option)
            || modifierFlags.contains(.control)
        let isTypingCurrentlyPressed = hasRequired && !hasForbidden

        if isTypingCurrentlyPressed && !wasTypingPreviouslyPressed {
            return .pressed
        }
        if !isTypingCurrentlyPressed && wasTypingPreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Voice-to-Text Mode (Dictation → Paste, NO Claude) Shortcut
    //
    // Fn + Shift triggers "voice-to-text mode": pure transcription piped
    // straight through typeTextViaClipboard into whatever field has
    // focus. No Claude call, no TTS, no conversation history — fastest
    // path from voice to typed text.
    //
    // Mutual exclusion:
    //   - Burst (shift+opt+fn)      → excluded by `.option` forbidden
    //   - Typing (cmd+fn)           → excluded by `.command` forbidden
    //   - Normal PTT (ctrl+opt)     → excluded by `.function` required (normal PTT explicitly rejects .function)
    //
    // So voice-to-text fires only when Fn+Shift are held together
    // WITHOUT option, command, or control.

    // Swapped 2026-04-26 (v10g): voice-to-text moved from Shift+Fn to Ctrl+Fn
    // because Steph holds it constantly and Ctrl+Fn is the easier two-finger
    // hold on the MacBook keyboard. Polish moved to Shift+Fn (it was tap-or-
    // briefly-hold and is used less often).
    static let voiceToTextModifierFlags: NSEvent.ModifierFlags = [.control, .function]

    static func voiceToTextTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasVoiceToTextPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return voiceToTextTransition(
            modifierFlags: flags,
            wasVoiceToTextPreviouslyPressed: wasVoiceToTextPreviouslyPressed
        )
    }

    private static func voiceToTextTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasVoiceToTextPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let hasRequired = modifierFlags.isSuperset(of: voiceToTextModifierFlags)
        // Forbidden flags must NOT include .control (it's required now).
        // Shift, option, command stay forbidden so this combo doesn't
        // overlap with polish (shift+fn), burst (shift+option+fn), or typing (cmd+fn).
        let hasForbidden = modifierFlags.contains(.shift)
            || modifierFlags.contains(.option)
            || modifierFlags.contains(.command)
        let isVoiceToTextCurrentlyPressed = hasRequired && !hasForbidden

        if isVoiceToTextCurrentlyPressed && !wasVoiceToTextPreviouslyPressed {
            return .pressed
        }
        if !isVoiceToTextCurrentlyPressed && wasVoiceToTextPreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Capture-to-Inbox (Fn + Shift)
    //
    // v15p2 (2026-05-02): MOVED from Fn+Opt → Fn+Shift to free up Fn+Opt
    // for the new Realtime mode. Fn+Shift was previously empty.
    //
    // Holds Fn+Shift alone → writes the transcript straight to
    // Inbox/Idea Inbox.md with a datestamp + [?] tag. Must be
    // mutually exclusive with every other shortcut:
    //   - VTT (fn+ctrl)                → excluded by `.control` forbidden
    //   - Burst (fn+shift+opt)         → excluded by `.option` forbidden
    //   - Typing (cmd+fn)              → excluded by `.command` forbidden
    //   - Realtime (fn+opt)            → excluded by `.option` forbidden

    static let captureToInboxModifierFlags: NSEvent.ModifierFlags = [.shift, .function]

    static func captureToInboxTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasCaptureToInboxPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return captureToInboxTransition(
            modifierFlags: flags,
            wasCaptureToInboxPreviouslyPressed: wasCaptureToInboxPreviouslyPressed
        )
    }

    private static func captureToInboxTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasCaptureToInboxPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let hasRequired = modifierFlags.isSuperset(of: captureToInboxModifierFlags)
        // v15p2: Fn+Shift is required; .option/.command/.control are
        // forbidden so we don't double-fire with Realtime (fn+opt),
        // burst (fn+shift+opt), typing (cmd+fn), or VTT (fn+ctrl).
        let hasForbidden = modifierFlags.contains(.option)
            || modifierFlags.contains(.command)
            || modifierFlags.contains(.control)
        let isCaptureToInboxCurrentlyPressed = hasRequired && !hasForbidden

        if isCaptureToInboxCurrentlyPressed && !wasCaptureToInboxPreviouslyPressed {
            return .pressed
        }
        if !isCaptureToInboxCurrentlyPressed && wasCaptureToInboxPreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Realtime conversation (Fn + Opt)
    //
    // v15p2 (2026-05-02): NEW (re-added after v15p revert). Holds Fn+Opt
    // alone → opens an OpenAI Realtime API WebSocket session for live
    // speech-to-speech conversation. Additive — Base PTT (Ctrl-tap) and
    // every other mode are unchanged.
    //
    // Mutually exclusive with every other shortcut:
    //   - VTT (fn+ctrl)                → excluded by `.control` forbidden
    //   - Capture-to-inbox (fn+shift)  → excluded by `.shift` forbidden
    //   - Burst (fn+shift+opt)         → excluded by `.shift` forbidden
    //   - Typing (cmd+fn)              → excluded by `.command` forbidden

    // v15p2 (2026-05-02): swapped from Fn+Opt → Ctrl+Opt. The previous
    // chord required reaching for the Fn key which is awkward; Ctrl+Opt
    // is the legacy Base PTT chord that's much easier to hold.
    // Base PTT moves to Fn+Opt as part of the same swap.
    static let realtimeModifierFlags: NSEvent.ModifierFlags = [.control, .option]

    static func realtimeTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasRealtimePreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return realtimeTransition(
            modifierFlags: flags,
            wasRealtimePreviouslyPressed: wasRealtimePreviouslyPressed
        )
    }

    private static func realtimeTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasRealtimePreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let hasRequired = modifierFlags.isSuperset(of: realtimeModifierFlags)
        // Ctrl+Opt is the chord. Forbidden: shift/command/function so
        // we don't double-fire with VTT (fn+ctrl), capture-to-inbox
        // (fn+shift), typing (cmd+fn), or Base PTT (fn+opt).
        let hasForbidden = modifierFlags.contains(.shift)
            || modifierFlags.contains(.command)
            || modifierFlags.contains(.function)
        let isRealtimeCurrentlyPressed = hasRequired && !hasForbidden

        if isRealtimeCurrentlyPressed && !wasRealtimePreviouslyPressed {
            return .pressed
        }
        if !isRealtimeCurrentlyPressed && wasRealtimePreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Realtime hands-free toggle (Fn + Shift + Opt)
    //
    // v15p2 (2026-05-02): direct toggle hotkey for hands-free Realtime
    // tutor mode. Single tap → flip hands-free state. When ON, next
    // Fn+Opt session starts in continuous-listening mode (server VAD
    // turn detection, no key needed between turns). When OFF, default
    // PTT semantics. State persists across cold-starts.
    //
    // Chord: Fn+Shift+Opt — reuses the old burst-mode chord (burst
    // was disabled in v13t). The burst detector still fires on this
    // chord but its handler is a no-op behind isBurstModeEnabled, so
    // the two coexist harmlessly.
    //
    // Mutually exclusive with every other ACTIVE hotkey:
    //   - VTT (fn+ctrl)                → excluded by `.control` forbidden
    //   - Capture-to-inbox (fn+shift)  → excluded by `.option` (capture's
    //                                    forbidden flags include .option)
    //   - Typing (cmd+fn)              → excluded by `.command` forbidden
    //                                    on capture/realtime; typing
    //                                    itself forbids .shift+.option
    //   - Realtime (fn+opt)            → excluded by `.shift` (Realtime's
    //                                    forbidden flags)

    static let realtimeHandsFreeToggleModifierFlags: NSEvent.ModifierFlags = [.shift, .option, .function]

    static func realtimeHandsFreeToggleTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return realtimeHandsFreeToggleTransition(
            modifierFlags: flags,
            wasPreviouslyPressed: wasPreviouslyPressed
        )
    }

    private static func realtimeHandsFreeToggleTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let hasRequired = modifierFlags.isSuperset(of: realtimeHandsFreeToggleModifierFlags)
        // Forbidden: anything OUTSIDE Fn+Shift+Opt. We require exactly
        // those three modifiers (not more, not fewer).
        let hasForbidden = modifierFlags.contains(.command)
            || modifierFlags.contains(.control)
        let isPressed = hasRequired && !hasForbidden

        if isPressed && !wasPreviouslyPressed {
            return .pressed
        }
        if !isPressed && wasPreviouslyPressed {
            return .released
        }
        return .none
    }

    // MARK: - Polish Hotkey (⌃Fn — Tap or Hold-and-Speak)
    //
    // Control + Fn fires polish on the currently-focused field's
    // existing text. Two gestures supported (tap-vs-hold logic lives
    // in CompanionManager.handlePolishHotkeyTransition):
    //   - Quick tap (release < 300ms) → polish with no modifier, instant
    //   - Hold > 300ms → engage dictation for spoken modifier, on
    //     release fire polish with that as modifier
    //
    // Mutual exclusion vs the other 5 shortcut paths:
    //   - Normal PTT (ctrl+opt)         → forbidden flag .option excludes Polish
    //                                     (and PTT itself excludes when .function is held)
    //   - Burst (fn+shift+opt)          → forbidden flags .shift + .option exclude
    //   - Typing (cmd+fn)               → forbidden flag .command excludes
    //                                     (typing already forbids .control)
    //   - Voice-to-text (fn+shift)      → forbidden flag .shift excludes
    //                                     (voice-to-text already forbids .control)
    //   - Capture-to-inbox (fn+opt)     → forbidden flag .option excludes
    //                                     (capture-to-inbox already forbids .control)
    //
    // History: an earlier version (2026-04-25 ship) used ⌃⌥⌘ modifier-only,
    // which collided with macOS accessibility shortcuts (Voice Control /
    // VoiceOver) when held — quick taps worked but holds got hijacked.
    // ⌃Fn fits the existing Fn+modifier pattern of the other 4 modes and
    // macOS doesn't use Fn-based combos for system shortcuts.

    // Swapped 2026-04-27 (v11d): polish moved from Shift+Fn to Shift+Control
    // (no Fn). Steph holds VTT (Ctrl+Fn) constantly and often fires polish
    // immediately after — keeping Ctrl anchored and just adding Shift is
    // the natural left-hand flow. Pure modifier-only hotkey, no Fn.
    static let polishHotkeyModifierFlags: NSEvent.ModifierFlags = [.shift, .control]

    static func polishHotkeyTransition(
        eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasPolishHotkeyPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return polishHotkeyTransition(
            modifierFlags: flags,
            wasPolishHotkeyPreviouslyPressed: wasPolishHotkeyPreviouslyPressed
        )
    }

    private static func polishHotkeyTransition(
        modifierFlags: NSEvent.ModifierFlags,
        wasPolishHotkeyPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let hasRequired = modifierFlags.isSuperset(of: polishHotkeyModifierFlags)
        // Forbid the modifiers used by other modes so polish doesn't double-fire:
        //   - .option excludes base PTT (⌃⌥) and burst (⇧⌥Fn) and capture-to-inbox (⌥Fn)
        //   - .command excludes typing (⌘Fn)
        //   - .function excludes VTT (⌃Fn) and the four Fn-modes above
        // After v11d, .control + .shift are both REQUIRED.
        let hasForbidden = modifierFlags.contains(.option)
            || modifierFlags.contains(.command)
            || modifierFlags.contains(.function)
        let isPolishHotkeyCurrentlyPressed = hasRequired && !hasForbidden

        if isPolishHotkeyCurrentlyPressed && !wasPolishHotkeyPreviouslyPressed {
            return .pressed
        }
        if !isPolishHotkeyCurrentlyPressed && wasPolishHotkeyPreviouslyPressed {
            return .released
        }
        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    /// v15p3v (2026-05-09): live partial transcript for the in-progress
    /// dictation. Mirrors `latestRecognizedText` (which is private and
    /// updated as AssemblyAI delivers streaming partials) so SwiftUI
    /// overlays can show what's being recognized in real time. Empty
    /// when no dictation in progress. Cleared on session end via
    /// resetSessionState. Steph asked for this so he has live
    /// confidence the mic + STT are working, can catch a misheard
    /// word mid-flight, and is never surprised by what got transcribed.
    @Published private(set) var liveTranscriptForDisplay: String = ""

    // v15p3w (2026-05-10): clean AssemblyAI's raw partial text for the
    // floating live-preview overlay. Removes em-dash / en-dash pause
    // artifacts, collapses runs of whitespace, trims edges. Cheap —
    // runs on every transcript update on the main actor; transcripts
    // stay short (a few sentences worth of in-flight words).
    fileprivate static func sanitizeForLiveDisplay(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var cleaned = raw
        // Remove em-dash and en-dash (with any adjacent spaces) entirely.
        cleaned = cleaned.replacingOccurrences(of: " — ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: " – ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "—", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "–", with: " ")
        // Collapse multiple whitespace (incl. newlines) into single space.
        let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+", options: [])
        if let regex = whitespaceRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: range,
                withTemplate: " "
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private let transcriptionProvider: any BuddyTranscriptionProvider
    private var audioEngine = AVAudioEngine()
    private var audioEngineUsesVoiceProcessing = false
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    // v15p3ao (2026-05-10): per Steph — drop the time + count-based
    // rebuild guardrails. As long as AirPods stay the input device, we
    // reuse the same VP engine indefinitely. Natural reset points are:
    // mode change (Bluetooth ↔ built-in), AVAudioEngineConfigurationChange,
    // and the new health-based rebuild below. The previous 15s warm
    // window and 3-reuse cap were a hedge against unknown AU staleness;
    // we're trading that hedge for an explicit detection mechanism.
    //
    // Health-based rebuild: after each engage, schedule a check at
    // +500ms. If we're using VP (Bluetooth) and the tap has delivered
    // zero buffers OR audio power is effectively zero, the engine is
    // probably silent — flag it for rebuild on next engage. This is the
    // empirical version of "the engine went stale" detection rather
    // than the time-based hedge.
    private var pendingHealthCheckWorkItem: DispatchWorkItem?
    private var bluetoothEngineNeedsRebuildOnNextEngage = false
    /// Serializes audio buffers from the tap thread so buffers captured during
    /// the transcription provider's websocket handshake (before the session is
    /// live) are replayed in order once the session opens. This eliminates
    /// first-word clipping across all push-to-talk modes.
    private let audioHandoff = TranscriptionAudioHandoff()
    /// v13j: diagnostic — timestamp of the very first audio buffer received
    /// in the current session's tap callback. Lets us measure the audio
    /// engine warm-up gap (between audioEngine.start() returning and audio
    /// actually flowing). nil until the first buffer arrives.
    private var firstTapBufferReceivedAt: Date?
    /// v13j: diagnostic — count of tap callbacks during the current session.
    private var tapBufferCount: Int = 0
    /// v14 (2026-04-30): cumulative audio engine start/stop cycle count
    /// across the app lifetime. Bumped on every cleanup. Useful for
    /// correlating CoreAudio degradation with cycle count — high cycle
    /// counts strongly suggest cumulative-state issues.
    private var audioSessionCycleCount: Int = 0
    /// v14: re-entry guard. Cleanup paths can race when (e.g.) Esc fires
    /// during finalize, or when shortcut release coincides with cancel.
    /// Without this, two cleanup calls could overlap, double-stopping the
    /// engine or double-cancelling the transcription session — both of
    /// which contribute to orphan-state buildup in CoreAudio.
    private var isCleaningUpAudioCapture: Bool = false
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
        observeAudioEngineConfigurationChanges(for: audioEngine)
    }

    deinit {
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
        }
    }

    private func observeAudioEngineConfigurationChanges(for engine: AVAudioEngine) {
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
        }
        audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioEngineConfigurationChange()
            }
        }
    }

    private func replaceAudioEngine(reason: String, voiceProcessing: Bool = false) {
        let oldEngine = audioEngine
        oldEngine.inputNode.removeTap(onBus: 0)
        if oldEngine.isRunning {
            oldEngine.stop()
        }
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
            self.audioEngineConfigurationObserver = nil
        }

        audioEngine = AVAudioEngine()
        audioEngineUsesVoiceProcessing = voiceProcessing
        observeAudioEngineConfigurationChanges(for: audioEngine)
        // v15p3ao (2026-05-10): the new engine hasn't captured anything,
        // so the rebuild-required flag from a prior failed health check
        // is no longer relevant. Also kill any in-flight health check
        // from the previous engine instance.
        bluetoothEngineNeedsRebuildOnNextEngage = false
        pendingHealthCheckWorkItem?.cancel()
        pendingHealthCheckWorkItem = nil
        Self.appendAudioDiag("audioEngine: replaced (\(reason))")
    }

    private func handleAudioEngineConfigurationChange() {
        Self.appendAudioDiag("audioEngine: configuration changed; will rebuild before next capture")
        if !isActivelyRecordingAudio {
            replaceAudioEngine(reason: "configuration change while idle", voiceProcessing: false)
        }
    }

    private static func defaultInputDeviceUsesBluetoothTransport() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceIDStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceIDAddr,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        )
        guard deviceIDStatus == noErr, deviceID != 0 else { return false }

        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &transportAddr,
            0,
            nil,
            &transportSize,
            &transport
        )
        guard transportStatus == noErr else { return false }

        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        cleanupAudioCapture(cancelTranscription: true)

        resetSessionState()
    }

    /// v14 (2026-04-30): unified audio-capture cleanup. Was duplicated across
    /// 4 sites with subtle variations that contributed to orphan-state buildup
    /// in CoreAudio over many sessions. Now every cleanup path goes through
    /// here:
    ///   - re-entry guard (prevents double-cleanup races)
    ///   - idempotent engine stop (only if running, AVAudioEngine.stop on
    ///     a stopped engine is technically safe but generates needless work)
    ///   - explicit tap removal
    ///   - optional graceful transcription session close (Terminate JSON +
    ///     .goingAway WebSocket frame, see AssemblyAIStreamingTranscriptionProvider.cancel)
    ///   - cycle counter bump for diagnostic correlation
    ///
    /// - Parameter cancelTranscription: when true (cancel/destroy paths),
    ///   immediately cancels the transcription session. When false (the
    ///   release-to-finalize path in stopPushToTalk), leaves the
    ///   transcription session alive so it can drain its final transcript
    ///   before being teardown'd in finishCurrentDictationSessionIfNeeded.
    private func cleanupAudioCapture(cancelTranscription: Bool) {
        guard !isCleaningUpAudioCapture else {
            Self.appendAudioDiag("RE-ENTRY BLOCKED at cycle=\(audioSessionCycleCount)")
            return
        }
        isCleaningUpAudioCapture = true
        defer { isCleaningUpAudioCapture = false }

        audioSessionCycleCount += 1
        let diagLine = "cycle=\(audioSessionCycleCount) cancelTranscription=\(cancelTranscription) engine.isRunning=\(audioEngine.isRunning)"
        print("🎙️ cleanupAudioCapture #\(audioSessionCycleCount) \(diagLine)")
        Self.appendAudioDiag(diagLine)

        // v14 Item 2 reverted (2026-05-01): the engine-warm experiment held
        // up for many sessions but introduced a new failure mode where the
        // audio input device powered down after several minutes of warm-but-
        // idle running. Reverting to stop/start per session as the known-
        // working baseline. Item 1's cleanup unification stays.
        // File-based diag at /tmp/clicky_audio_diag.log captures every cycle
        // for offline analysis when failure recurs.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if cancelTranscription {
            activeTranscriptionSession?.cancel()
        }

        // v15p3ao (2026-05-10): cancel any in-flight health check so it
        // doesn't fire after the engine is already torn down.
        pendingHealthCheckWorkItem?.cancel()
        pendingHealthCheckWorkItem = nil
    }

    // v15p3ao (2026-05-10): health check for Bluetooth VP engines. After
    // engine.start() returns, schedule a check at +500ms to see if the
    // tap has actually delivered audio. If we're VP'd and the tap has
    // received zero buffers OR audio power has been silent the entire
    // window, the AU is probably in a stale state and the next engage
    // should rebuild. We don't try to recover the current session — by
    // the time we'd diagnose and rebuild, the user has likely already
    // released. Just flag for next time.
    private static let bluetoothHealthCheckDelaySeconds: Double = 0.5

    private func scheduleHealthCheckIfBluetooth() {
        pendingHealthCheckWorkItem?.cancel()
        guard audioEngineUsesVoiceProcessing else { return }
        let snapshotCycle = audioSessionCycleCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // If we've cycled past this engage already, the user
                // released before the check fired — skip silently to
                // avoid false positives from a real-world short tap.
                guard self.audioSessionCycleCount == snapshotCycle else { return }
                let hasBuffers = self.tapBufferCount > 0
                let hasSignal = self.currentAudioPowerLevel > 0.001
                if !hasBuffers || !hasSignal {
                    self.bluetoothEngineNeedsRebuildOnNextEngage = true
                    Self.appendAudioDiag("health check FAILED at +\(Int(Self.bluetoothHealthCheckDelaySeconds * 1000))ms (buffers=\(self.tapBufferCount), power=\(self.currentAudioPowerLevel)) — next engage will rebuild")
                } else {
                    Self.appendAudioDiag("health check passed (buffers=\(self.tapBufferCount), power=\(self.currentAudioPowerLevel))")
                }
            }
        }
        pendingHealthCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bluetoothHealthCheckDelaySeconds,
            execute: workItem
        )
    }

    /// File-based diagnostic logger for audio cleanup events. Bypasses OSLog
    /// because Swift print() from a sandboxed Mac app doesn't reliably
    /// surface there. Plain-text JSONL-ish format we can grep + correlate
    /// with user-reported failures.
    static func appendAudioDiag(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/clicky_audio_diag.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        // v15p3 (2026-05-06): break the toggle-stuck race. If a prior
        // session is still finalizing (rapid disengage→re-engage during
        // the 2.4s fallback window), `isDictationInProgress` is still
        // true via `isFinalizingTranscript`, and the guard below silently
        // no-ops. User-visible symptom: hold or toggle mode does nothing
        // on subsequent presses for a couple seconds. Cancel the prior
        // session cleanly so the new one can run.
        if isFinalizingTranscript {
            print("🎙️ BuddyDictationManager: previous session still finalizing — force-resetting to allow new session")
            Self.appendAudioDiag("FORCE_RESET_FROM_FINALIZE startSource=\(startSource)")
            cancelCurrentDictation(preserveDraftText: false)
        }

        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                cleanupAudioCapture(cancelTranscription: true)
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        // v14: leave transcription alive so it can drain final transcript
        cleanupAudioCapture(cancelTranscription: false)
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let didReceiveTranscript = !self.latestRecognizedText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                print("⏰ Dictation fallback fired (\(finalTranscriptFallbackDelaySeconds)s) — gotTranscript=\(didReceiveTranscript)")
                self.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        // v13j (2026-04-30): timing diagnostics for first-word-clip debug.
        // The audio handoff was supposed to eliminate this on 2026-04-20.
        // If it's clipping again, these logs tell us where audio is being
        // lost — between engine.start() and first tap callback (engine
        // warm-up gap), or between session activation and AssemblyAI
        // actually accepting audio (handoff flush bug).
        let phaseStartTime = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(phaseStartTime) * 1000) }

        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil
        audioHandoff.reset()
        print("🎙️ T+\(elapsedMs())ms: handoff reset")

        // Start the audio engine BEFORE opening the transcription websocket so
        // the mic is already capturing when the user starts speaking. Audio
        // received while the session is still handshaking is deep-copied and
        // buffered in `audioHandoff`, then flushed in order once the session
        // is live. Without this, the first ~100–400ms of audio (the handshake
        // window) is silently dropped, clipping the first word.
        let shouldUseVoiceProcessing = Self.defaultInputDeviceUsesBluetoothTransport()

        // v15p3ao (2026-05-10): rebuild ONLY on:
        //   1. Mode change (Bluetooth ↔ built-in)
        //   2. Health check from previous engage flagged us as stale
        //   3. AVAudioEngineConfigurationChange observer fired
        // Everything else reuses the existing engine. As long as AirPods
        // stay connected, no rebuilds happen — the first engage pays the
        // ~1-1.5s HFP renegotiation tax once, every subsequent engage is
        // near-instant. Steph wanted this rather than the time-based hedge.
        let canReuseExistingEngine: Bool = {
            guard !bluetoothEngineNeedsRebuildOnNextEngage else { return false }
            if shouldUseVoiceProcessing {
                // Bluetooth path: need an existing VP-enabled engine.
                guard audioEngineUsesVoiceProcessing else { return false }
                guard audioEngine.inputNode.isVoiceProcessingEnabled else { return false }
                return true
            } else {
                // Non-Bluetooth path: need an existing non-VP engine.
                guard !audioEngineUsesVoiceProcessing else { return false }
                guard !audioEngine.inputNode.isVoiceProcessingEnabled else { return false }
                return true
            }
        }()

        if !canReuseExistingEngine {
            let reason: String
            if bluetoothEngineNeedsRebuildOnNextEngage {
                reason = "rebuilding after health check flagged previous engage as silent"
            } else if shouldUseVoiceProcessing {
                reason = audioEngineUsesVoiceProcessing
                    ? "rebuilding Bluetooth VP engine"
                    : "first Bluetooth voice-processing capture"
            } else {
                reason = "leaving Bluetooth voice-processing mode"
            }
            replaceAudioEngine(reason: reason, voiceProcessing: shouldUseVoiceProcessing)
            bluetoothEngineNeedsRebuildOnNextEngage = false
        } else {
            Self.appendAudioDiag("audioEngine: reusing existing engine (vp=\(audioEngineUsesVoiceProcessing))")
        }

        let inputNode = audioEngine.inputNode
        if shouldUseVoiceProcessing && !inputNode.isVoiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                audioEngineUsesVoiceProcessing = true
                // v15p3an (2026-05-10): per Codex — disable AGC explicitly
                // on the VP input. AGC was a likely culprit for the very
                // low / fluctuating input volume we saw in Voice Memos,
                // and we want predictable input level for STT regardless.
                inputNode.isVoiceProcessingAGCEnabled = false
                Self.appendAudioDiag("voiceProcessing: enabled for Bluetooth input, AGC=\(inputNode.isVoiceProcessingAGCEnabled)")
            } catch {
                audioEngineUsesVoiceProcessing = false
                Self.appendAudioDiag("voiceProcessing: enable threw \(error.localizedDescription)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        Self.appendAudioDiag("input format: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) fmt=\(inputFormat.commonFormat.rawValue) vpEnabled=\(inputNode.isVoiceProcessingEnabled) bluetoothInput=\(shouldUseVoiceProcessing)")

        // Track first tap callback timing (Atomic-ish via instance var to
        // survive across async boundaries). Reset each session.
        firstTapBufferReceivedAt = nil
        tapBufferCount = 0

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Diagnostic: log the first tap callback so we can see how long
            // after engine.start() it actually fires (engine warm-up gap).
            if self.firstTapBufferReceivedAt == nil {
                self.firstTapBufferReceivedAt = Date()
                let warmupMs = Int(Date().timeIntervalSince(phaseStartTime) * 1000)
                print("🎙️ T+\(warmupMs)ms: FIRST tap buffer received (engine warm-up)")
            }
            self.tapBufferCount += 1
            self.updateAudioPowerLevel(from: buffer)
            // v15p3ae (2026-05-10): voice processing AU emits multi-channel
            // buffers (channel 0 = post-AEC mic, channels 1+ = echo
            // reference). AssemblyAI expects mono, so collapse to channel 0
            // before handoff. When voice processing isn't engaged the
            // buffer is already mono and this is a no-op deep copy.
            // AVAudioEngine may reuse the tap buffer's backing memory on
            // the next callback, so we must own our own storage here.
            guard let copy = buffer.clickyDeepCopyAsMono() else { return }
            self.audioHandoff.enqueue(copy)
        }

        print("🎙️ T+\(elapsedMs())ms: tap installed; calling audioEngine.prepare()")
        // v15p3ab (2026-05-10): log input device + format right before
        // engine.start(). When AirPods are the input, start() can throw
        // OSStatus errors that only appear in stdout — surface them in
        // the diag log instead so we can debug without Xcode attached.
        let inputFormatDiag = "sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) fmt=\(inputFormat.commonFormat.rawValue)"
        Self.appendAudioDiag("engine.prepare: \(inputFormatDiag)")
        audioEngine.prepare()
        print("🎙️ T+\(elapsedMs())ms: prepare() returned; calling audioEngine.start()")
        do {
            try audioEngine.start()
        } catch {
            Self.appendAudioDiag("engine.start THREW: \(error) [nsError=\((error as NSError).domain) code=\((error as NSError).code) userInfo=\((error as NSError).userInfo)] \(inputFormatDiag)")
            throw error
        }
        print("🎙️ T+\(elapsedMs())ms: audioEngine.start() returned; opening transcription provider \(transcriptionProvider.displayName)")

        // v15p3ao (2026-05-10): kick off the health check for Bluetooth VP
        // engines. If the tap doesn't deliver any audio in the next 500ms
        // and we're VP'd, the AU is silent and we'll rebuild on next engage.
        scheduleHealthCheckIfBluetooth()

        let session = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                    // v15p3v (2026-05-09): mirror partial to the public
                    // display var so the live-preview overlay can show
                    // words as they're recognized.
                    // v15p3w (2026-05-10): sanitize for display only —
                    // AssemblyAI's unformatted partials sprinkle em/en
                    // dashes at every pause, which makes the overlay
                    // look fragmented. Strip them + collapse whitespace
                    // for the display path; raw text still feeds polish.
                    self?.liveTranscriptForDisplay = Self.sanitizeForLiveDisplay(transcriptText)
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        // Atomically hand the session to the audio handoff queue. This flushes
        // the buffered backlog in order before any subsequent tap callback is
        // processed, so audio arrives at the provider in capture order.
        let flushedCount = audioHandoff.activate(session: session)
        self.activeTranscriptionSession = session
        let firstTapMs = firstTapBufferReceivedAt.map { Int($0.timeIntervalSince(phaseStartTime) * 1000) } ?? -1
        print("🎙️ T+\(elapsedMs())ms: provider ready, flushed \(flushedCount) buffers (first tap was T+\(firstTapMs)ms, total taps=\(tapBufferCount))")
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks
        // v15p3 (2026-05-06): capture start source for empty-transcript
        // diagnostics. resetSessionState() below nils it out, so we have
        // to grab it first or the log loses the mode that bailed.
        let startSourceForLogging = activeStartSource

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        cleanupAudioCapture(cancelTranscription: true)

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else {
            // v15p3 (2026-05-06): surface "no output" to the diagnostic log
            // so we can correlate with audio failures, network blips, or
            // user-spoke-too-softly cases. Used to be silent — user saw
            // spinner clear with nothing pasted and no signal of why.
            // Common causes: AssemblyAI fallback fired before final transcript
            // arrived; mic captured silence; first-buffer audio race.
            print("⚠️ BuddyDictationManager: empty final transcript — nothing to paste (startSource=\(String(describing: startSourceForLogging)))")
            Self.appendAudioDiag("EMPTY_TRANSCRIPT_ON_FINALIZE startSource=\(String(describing: startSourceForLogging))")
            return
        }

        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        audioHandoff.reset()
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        // v15p3v (2026-05-09): clear the live-preview mirror so the
        // overlay disappears when the session ends.
        liveTranscriptForDisplay = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    /// v12m (2026-04-28): hardcoded base list of proper nouns + jargon that
    /// Steph uses regularly. AssemblyAI's `keyterms_prompt` parameter biases
    /// the model toward these spellings, fixing common mishearings at the
    /// STT layer instead of relying on polish to catch them. Updated daily
    /// by the clicky-daily-memory-scan skill via the override JSON below.
    private static let baseTranscriptionKeyterms = [
        // People
        // RULE: prefer the SHORTEST unambiguous form for each name. Adding
        // both "Bunheng" and "Bunheng Hok" caused AssemblyAI to over-force
        // the long form even when Steph said only "Bunheng" (v12m hotfix).
        // "Hok" gets transcribed normally; the keyterm just protects the
        // first name.
        "Lukas",          // commonly misheard as "Lucas"
        "Bunheng",        // commonly misheard as "Boonhang", "Bunhang"
        // Companies / brands
        "Kombo",
        "Glamnetic",
        "Anthropic",
        "OpenAI",
        // Tools / platforms Steph uses daily
        "Claude",
        "Cowork",
        "Clicky",
        "Wispr",
        "Obsidian",
        "ClickUp",
        "Omni",
        "Slack",
        "Axiom",
        "Codex",
        "Voicebox",
        // Tech jargon
        "SwiftUI",
        "Xcode",
        "Vercel",
        "Next.js",
        "localhost",
        // Legacy carry-overs
        "makesomething",
        "Learning Buddy"
    ]

    /// Path to the auto-updating keyterms override file inside Steph's
    /// Obsidian vault. The clicky-daily-memory-scan skill writes new
    /// keyterm candidates here based on observed mishearings. The file
    /// is missing on first run; we treat that as "no overrides" — the
    /// hardcoded base list still works.
    private static let keytermsOverrideFilePath =
        "/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/keyterms.json"

    /// Read the override file. Expected shape:
    /// `{ "keyterms": [ {"term": "...", ...optional metadata...} ] }`
    /// or simply `{ "keyterms": ["term1", "term2"] }`.
    /// Returns empty array on any error so the base list still works.
    private func loadOverrideKeyterms() -> [String] {
        let fileURL = URL(fileURLWithPath: Self.keytermsOverrideFilePath)
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let rawTerms = parsed["keyterms"] as? [Any] else { return [] }

        var extractedTerms: [String] = []
        for entry in rawTerms {
            if let stringEntry = entry as? String {
                extractedTerms.append(stringEntry)
            } else if let dictEntry = entry as? [String: Any],
                      let term = dictEntry["term"] as? String {
                extractedTerms.append(term)
            }
        }
        return extractedTerms
    }

    private func buildTranscriptionKeyterms() -> [String] {
        let baseKeyterms = Self.baseTranscriptionKeyterms
        let overrideKeyterms = loadOverrideKeyterms()

        let combinedKeyterms = baseKeyterms + overrideKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}

/// Serializes audio buffers coming from the AVAudioEngine tap thread while the
/// transcription provider's streaming session is still being established. Any
/// buffers received before `activate(session:)` is called are retained and
/// replayed in order once the session is live, so the first word of each
/// push-to-talk utterance isn't dropped during the websocket handshake window.
///
/// All mutations run on a private serial queue so enqueued buffers and the
/// activation hand-off cannot reorder relative to one another.
private final class TranscriptionAudioHandoff {
    private let queue = DispatchQueue(label: "com.clicky.buddyDictation.audioHandoff")
    private var session: (any BuddyStreamingTranscriptionSession)?
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    /// Enqueue an audio buffer from the tap thread. Buffers received before
    /// `activate(session:)` are held; buffers received after are forwarded
    /// directly. Non-blocking on the caller.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session {
                session.appendAudioBuffer(buffer)
            } else {
                self.pendingBuffers.append(buffer)
            }
        }
    }

    /// Atomically attach the live transcription session and flush any audio
    /// buffered during the handshake. Returns the number of buffers flushed.
    @discardableResult
    func activate(session: any BuddyStreamingTranscriptionSession) -> Int {
        return queue.sync {
            self.session = session
            let backlog = self.pendingBuffers
            self.pendingBuffers.removeAll()
            for buffer in backlog {
                session.appendAudioBuffer(buffer)
            }
            return backlog.count
        }
    }

    /// Clear any retained state. Safe to call between sessions.
    func reset() {
        queue.sync {
            self.session = nil
            self.pendingBuffers.removeAll()
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Deep-copies an AVAudioPCMBuffer so it can safely outlive the audio tap
    /// callback that delivered it. AVAudioEngine may reuse the tap buffer's
    /// backing memory on subsequent callbacks, so any buffer we want to hold
    /// beyond the closure must own its own sample storage.
    func clickyDeepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength

        let channelCount = Int(format.channelCount)
        let frames = Int(frameLength)

        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channelCount {
                memcpy(dst[channel], src[channel], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channelCount {
                memcpy(dst[channel], src[channel], frames * MemoryLayout<Int16>.size)
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channelCount {
                memcpy(dst[channel], src[channel], frames * MemoryLayout<Int32>.size)
            }
        }
        return copy
    }

    /// v15p3ae (2026-05-10): deep-copy as mono. When voice processing AU is
    /// engaged on macOS the input bus emits multi-channel buffers (channel
    /// 0 = post-AEC mic, additional channels = echo reference). AssemblyAI
    /// expects mono PCM, so we extract just channel 0 into a fresh
    /// single-channel buffer with the same sample rate. When the input is
    /// already mono this is equivalent to clickyDeepCopy().
    func clickyDeepCopyAsMono() -> AVAudioPCMBuffer? {
        let frames = Int(frameLength)
        guard frames > 0 else {
            // Empty buffer — return an empty mono buffer of the same format.
            let monoFormat = AVAudioFormat(
                commonFormat: format.commonFormat,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            )
            guard let mf = monoFormat else { return nil }
            return AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: frameCapacity)
        }

        // If already mono, just deep-copy. No need to construct a new format.
        if format.channelCount == 1 {
            return clickyDeepCopy()
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: format.commonFormat,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = AVAudioFrameCount(frames)

        if let src = floatChannelData, let dst = copy.floatChannelData {
            memcpy(dst[0], src[0], frames * MemoryLayout<Float>.size)
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            memcpy(dst[0], src[0], frames * MemoryLayout<Int16>.size)
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            memcpy(dst[0], src[0], frames * MemoryLayout<Int32>.size)
        } else {
            return nil
        }
        return copy
    }
}
