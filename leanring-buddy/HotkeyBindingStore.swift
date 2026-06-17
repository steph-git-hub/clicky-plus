//
//  HotkeyBindingStore.swift
//  Clicky+
//
//  v16qo (2026-06-14): user-configurable hotkeys (press-to-set recorder).
//
//  Replaces the per-mode `static let xModifierFlags` constants + hardcoded
//  "forbidden flags" overlap logic in BuddyDictationManager with a single
//  UserDefaults-backed store the user can rebind at runtime (Settings →
//  record a combo). Detection moves to EXACT modifier match, which is
//  naturally mutually-exclusive — so rebinding any mode to any combo can
//  never silently overlap another.
//
//  This file is ADDITIVE: nothing consumes it until the monitor + UI are
//  wired in (next steps). Safe to ship on its own.
//
//  Scope note: modifier-only chords (no key code), device-independent mask
//  (shift/control/option/command/function) only.
//

import AppKit
import Foundation

/// The Clicky+ modes that have a (rebindable) modifier-chord hotkey.
enum ClickyHotkeyMode: String, CaseIterable {
    case basePTT
    case typing
    case vtt
    case watch
    case captureToInbox
    case polish
    case realtime

    var displayName: String {
        switch self {
        case .basePTT:        return "Push-to-talk (Claude)"
        case .typing:         return "Typing mode"
        case .vtt:            return "Voice-to-text"
        case .watch:          return "Watch mode"
        case .captureToInbox: return "Capture to inbox"
        case .polish:         return "Polish"
        case .realtime:       return "Marin (realtime)"
        }
    }

    /// Seed default = the binding this mode ships with on a clean install /
    /// before the user records their own. The first three reflect Steph's
    /// 2026-06-14 remap; the rest preserve the long-standing bindings.
    /// NOTE: captureToInbox + polish defaults to be re-confirmed against the
    /// live `BuddyDictationManager` constants when the monitor is wired
    /// (the old hotkey-map memory disagreed with the code on these two).
    var defaultFlags: NSEvent.ModifierFlags {
        switch self {
        case .basePTT:        return [.command, .function]            // Fn+Cmd  (was unbound)
        case .typing:         return [.option, .function]             // Fn+Opt  (was Cmd+Fn)
        case .watch:          return [.shift, .option, .function]     // Fn+Shift+Opt (was Fn+Opt)
        case .vtt:            return [.control, .function]            // Ctrl+Fn (unchanged)
        case .polish:         return [.shift, .function]              // Shift+Fn (unchanged)
        case .captureToInbox: return [.option, .shift, .function]    // verify at wire-time
        case .realtime:       return [.control, .option]             // Ctrl+Opt (unchanged)
        }
    }
}

/// UserDefaults-backed, runtime-editable hotkey bindings. Source of truth
/// for which modifier chord triggers which mode once wired into the input
/// monitor.
enum HotkeyBindingStore {
    /// Only these flags are meaningful for a chord; strip everything else
    /// (caps lock, numeric pad, etc.) so comparisons are stable.
    static let relevantMask: NSEvent.ModifierFlags =
        [.shift, .control, .option, .command, .function]

    private static func defaultsKey(_ mode: ClickyHotkeyMode) -> String {
        "clicky.hotkey.\(mode.rawValue)"
    }

    /// Current binding for a mode — the user's recorded value, else the
    /// seed default.
    static func flags(for mode: ClickyHotkeyMode) -> NSEvent.ModifierFlags {
        let key = defaultsKey(mode)
        if UserDefaults.standard.object(forKey: key) != nil {
            let raw = UInt(bitPattern: UserDefaults.standard.integer(forKey: key))
            return NSEvent.ModifierFlags(rawValue: raw).intersection(relevantMask)
        }
        return mode.defaultFlags.intersection(relevantMask)
    }

    /// Record a new binding (called by the recorder UI after capturing a
    /// combo). Returns false (without saving) if `flags` is empty or already
    /// bound to a different mode — the caller decides whether to steal.
    @discardableResult
    static func set(_ flags: NSEvent.ModifierFlags, for mode: ClickyHotkeyMode) -> Bool {
        let cleaned = flags.intersection(relevantMask)
        guard !cleaned.isEmpty else { return false }
        if let owner = Self.mode(matching: cleaned), owner != mode { return false }
        UserDefaults.standard.set(Int(bitPattern: UInt(cleaned.rawValue)), forKey: defaultsKey(mode))
        return true
    }

    /// Force-save even if it steals another mode's combo (the stolen mode is
    /// left with whatever it had — caller should surface the conflict first).
    static func forceSet(_ flags: NSEvent.ModifierFlags, for mode: ClickyHotkeyMode) {
        let cleaned = flags.intersection(relevantMask)
        guard !cleaned.isEmpty else { return }
        UserDefaults.standard.set(Int(bitPattern: UInt(cleaned.rawValue)), forKey: defaultsKey(mode))
    }

    /// Reset a mode to its seed default.
    static func reset(_ mode: ClickyHotkeyMode) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(mode))
    }

    /// The single mode whose binding EXACTLY matches the given live modifier
    /// flags, or nil. Exact match = the whole mutual-exclusion story.
    static func mode(matching liveFlags: NSEvent.ModifierFlags) -> ClickyHotkeyMode? {
        let cleaned = liveFlags.intersection(relevantMask)
        guard !cleaned.isEmpty else { return nil }
        return ClickyHotkeyMode.allCases.first { flags(for: $0) == cleaned }
    }

    /// Human-readable combo, e.g. "fn + cmd", for the settings UI.
    static func displayString(for mode: ClickyHotkeyMode) -> String {
        displayString(for: flags(for: mode))
    }

    static func displayString(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("fn") }
        if flags.contains(.control)  { parts.append("ctrl") }
        if flags.contains(.option)   { parts.append("opt") }
        if flags.contains(.shift)    { parts.append("shift") }
        if flags.contains(.command)  { parts.append("cmd") }
        return parts.isEmpty ? "(unset)" : parts.joined(separator: " + ")
    }
}
