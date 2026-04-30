//
//  MacKeyboardSafety.swift
//  Defensive helpers to prevent stuck modifier state from synthesized
//  CGEvent posting (typeTextViaClipboard, polish paste, etc.).
//
//  Extracted from the v13i modifier-safety fix (originally lived inside
//  the now-removed AgenticTools.swift). Keep at file scope so any code
//  that synthesizes keystrokes can call releaseAllModifiers() as a
//  belt-and-suspenders panic clear.
//

import AppKit
import Foundation

enum MacKeyboardSafety {

    /// Post keyUp events with empty flags for every common modifier key.
    /// Idempotent — calling this when no modifiers are stuck is a no-op
    /// from the user's POV (releasing an already-released key does nothing).
    /// Designed as a panic-clear after any synthesized chord, and on Esc.
    @MainActor
    static func releaseAllModifiers() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let modifierKeyCodes: [CGKeyCode] = [
            55,  // left Cmd
            54,  // right Cmd
            56,  // left Shift
            60,  // right Shift
            58,  // left Opt
            61,  // right Opt
            59,  // left Ctrl
            62,  // right Ctrl
            63,  // Fn
        ]
        for keyCode in modifierKeyCodes {
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            up?.flags = []
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
