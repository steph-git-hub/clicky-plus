//
//  MouseSideButtonMonitor.swift
//  leanring-buddy
//
//  v15p3gv (2026-05-18): NEW. System-wide CGEvent tap that publishes
//  "advance Marin to the next step" signals.
//
//  v15p3ha (2026-05-18): redesigned for reliability. Original inputs
//  (caps lock + side mouse buttons 3/4) were unreliable:
//    • Caps lock fired BOTH .keyDown AND .flagsChanged on every press,
//      double-firing advance; the IOHID forceCapsLockOff call raced
//      the kernel's own toggle so the LED state was unpredictable;
//      and rapid sub-75ms taps were dropped at the HID layer entirely.
//    • Side mouse buttons depend on the manufacturer's driver passing
//      them through as standard otherMouseDown events. SteelSeries
//      Engine and similar third-party software frequently intercept
//      them before macOS sees them. Bug-prone across mouse models.
//
//  New inputs:
//    • Middle mouse button (otherMouseDown button 2 — the scroll-wheel
//      click). Single dedicated input, present on every mouse, bypasses
//      driver remapping that affects side buttons, no toggle state.
//    • Left Cmd tap — press and release Left Cmd alone, under 200ms,
//      with no other modifier change during the press. Mirror of the
//      existing Polish hotkey's tap-vs-hold pattern. Right Cmd left
//      free for normal use.
//
//  Why these inputs: when Marin is walking Steph through a multi-step
//  guidance flow (e.g., clicking through Amazon Ads Console), his hand
//  is already on the mouse or keyboard for the clicks. Saying "done"
//  or "next" each step adds friction and gets mis-transcribed. Middle
//  click = zero-context-switch for the mouse hand. Left Cmd tap =
//  zero-context-switch for the keyboard hand.
//
//  GATING: both inputs only fire publish events when Marin is in an
//  active guidance/realtime session (set via `isMarinActive`). When
//  Marin is inactive, both inputs pass through unmodified — middle
//  click still middle-clicks (closes tabs in browsers, etc.), Left
//  Cmd still composes shortcuts normally. When Marin is active, both
//  inputs are CONSUMED so they don't double-fire.
//
//  Class name preserved as MouseSideButtonMonitor for diff sanity,
//  but it now monitors middle click + Left Cmd. Conceptually it's
//  the "Marin step advance input monitor."
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit
import IOKit.hidsystem

@MainActor
final class MouseSideButtonMonitor {

    /// What kind of input fired the advance. The case names match the
    /// v15p3ha redesign; older sideMouseButton/capsLock cases are gone.
    enum AdvanceTrigger {
        case middleMouseButton
        case leftCmdTap
    }

    // v15p3ha (2026-05-18): Left Cmd tap state. The CGEvent callback is
    // off-main and synchronous, so we mirror tap state in nonisolated
    // atomic-ish fields. Single Bool/TimeInterval reads are atomic on
    // aarch64; sufficient for this gate.
    nonisolated(unsafe) fileprivate static var leftCmdPressTimestamp: TimeInterval = 0
    nonisolated(unsafe) fileprivate static var leftCmdTapDisqualified: Bool = false

    /// Max duration of a Left Cmd tap. Held longer than this = treated
    /// as a real Cmd hold for app shortcuts; advance does not fire.
    fileprivate static let leftCmdTapMaxDurationSeconds: TimeInterval = 0.2

    /// Fires each time an advance input is pressed while Marin is
    /// active. When Marin is inactive, no events are published and
    /// the inputs pass through to the OS unchanged.
    let advanceTriggeredPublisher = PassthroughSubject<AdvanceTrigger, Never>()

    /// Set to `true` while a Marin guidance/realtime session is in
    /// progress. While true, side buttons + caps lock are CONSUMED
    /// and emit advance events instead of doing their normal thing.
    /// Set back to `false` when Marin ends so caps lock and side
    /// buttons restore their normal behavior.
    nonisolated(unsafe) private static var isMarinActiveStorage: Bool = false

    /// Thread-safe accessor used from the CGEvent callback. The callback
    /// runs on a high-priority event-dispatch thread, not main, so we
    /// can't touch @MainActor state directly without hopping — and the
    /// hop is too slow to decide event consumption synchronously.
    /// Instead we mirror the flag in a nonisolated atomic-ish bool.
    /// Reads/writes of a single Bool are atomic on aarch64; that's
    /// sufficient for this gate.
    nonisolated static func setMarinActive(_ isActive: Bool) {
        let prior = isMarinActiveStorage
        isMarinActiveStorage = isActive
        if prior != isActive {
            // Diag the gate flip so we can correlate with "side button
            // didn't advance" bug reports.
            Task { @MainActor in
                RealtimeConversationManager.appendDiag(
                    "[advance-input] gate \(prior ? "OPEN" : "closed") → \(isActive ? "OPEN" : "closed")"
                )
            }
        }
    }

    nonisolated static var isMarinActive: Bool {
        isMarinActiveStorage
    }

    private var globalEventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedBridge: Unmanaged<MouseSideButtonMonitorBridge>?

    // MARK: - Lifecycle

    /// Start the event tap. Uses .defaultTap (not .listenOnly) so we
    /// can swallow events when Marin is active. Requires Accessibility
    /// permission — same TCC entry as the PTT shortcut monitor, so if
    /// PTT works, this will too.
    func startMonitoring() {
        if globalEventTap != nil { return }

        // v15p3v (2026-05-21): added .keyDown to fix the Cmd+V collision
        // with Left-Cmd-tap. Previously chord detection only caught
        // OTHER MODIFIER flag changes (shift/alt/ctrl/fn) — regular
        // keypresses like V didn't disqualify, so pasting fired advance.
        // .keyDown observation lets the detector disqualify on any
        // non-modifier key pressed while Cmd is held. The keyDown event
        // itself passes through unchanged.
        let monitoredEventTypes: [CGEventType] = [
            .otherMouseDown, .otherMouseUp,
            .rightMouseDown, .flagsChanged,
            .keyDown,
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let bridge = Unmanaged<MouseSideButtonMonitorBridge>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            // Tap-disabled-by-timeout self-heal — same pattern as the
            // PTT monitor.
            if eventType == .tapDisabledByTimeout {
                if let tap = bridge.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            let shouldConsume = bridge.processEventFromTap(eventType: eventType, event: event)
            if shouldConsume {
                // Returning nil swallows the event so neither the focused
                // app nor the OS sees it.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let bridge = MouseSideButtonMonitorBridge(owner: self)
        let bridgePointer = Unmanaged.passRetained(bridge).toOpaque()

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: bridgePointer
        ) else {
            print("⚠️ MouseSideButtonMonitor: couldn't create CGEvent tap (Accessibility permission?)")
            RealtimeConversationManager.appendDiag(
                "[advance-input] FAILED to create CGEvent tap — Accessibility permission likely missing"
            )
            Unmanaged<MouseSideButtonMonitorBridge>.fromOpaque(bridgePointer).release()
            return
        }
        RealtimeConversationManager.appendDiag(
            "[advance-input] CGEvent tap created OK (.defaultTap, otherMouseDown + flagsChanged + keyDown) — middle click + Left Cmd tap with chord guard"
        )

        bridge.eventTap = createdEventTap

        let createdRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, createdEventTap, 0
        )

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            createdRunLoopSource,
            .commonModes
        )

        CGEvent.tapEnable(tap: createdEventTap, enable: true)

        globalEventTap = createdEventTap
        runLoopSource = createdRunLoopSource
        retainedBridge = Unmanaged.fromOpaque(bridgePointer)
    }

    func stopMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                runLoopSource,
                .commonModes
            )
            self.runLoopSource = nil
        }
        if let globalEventTap {
            CGEvent.tapEnable(tap: globalEventTap, enable: false)
            self.globalEventTap = nil
        }
        retainedBridge?.release()
        retainedBridge = nil
    }

    // MARK: - Event dispatch (called from off-main callback thread)

    /// Returns true if the event should be CONSUMED (swallowed). Called
    /// from the CGEvent tap thread, so this is nonisolated and reads
    /// the mirrored isMarinActive flag directly.
    fileprivate nonisolated func handleEventNonisolated(
        eventType: CGEventType, event: CGEvent
    ) -> Bool {
        // v15p3ha (2026-05-18): redesigned — middle click + Left Cmd tap
        // replace the unreliable caps lock + side button design. Diag
        // every relevant event regardless of gate so failures are easy
        // to trace.
        let marinActive = MouseSideButtonMonitor.isMarinActive
        switch eventType {
        case .otherMouseDown, .otherMouseUp, .rightMouseDown:
            let rawButtonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            logDiagFromNonisolated(
                "[advance-input] mouseEvent type=\(eventType.rawValue) button=\(rawButtonNumber) marinActive=\(marinActive)"
            )
            // Only middle-click (button 2) advances. Side buttons (3/4)
            // were unreliable across mouse drivers and were retired.
            if eventType == .otherMouseDown && marinActive && rawButtonNumber == 2 {
                publishAdvance(.middleMouseButton)
                return true
            }
            return false
        case .flagsChanged:
            // Left Cmd tap detection. Press the key, release within
            // 200ms without engaging any other modifier — fires advance.
            // Held longer than 200ms or used in a chord = passthrough.
            //
            // keycode 55 = kVK_Command (left cmd). keycode 54 is the
            // right cmd — we explicitly do NOT detect that one so it
            // stays available for normal shortcuts. Caps lock (keycode
            // 57) is gone entirely — no more HID toggle race.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            if keycode == 55 {
                let now = Date().timeIntervalSinceReferenceDate
                let cmdHeld = flags.contains(.maskCommand)

                if cmdHeld {
                    Self.leftCmdPressTimestamp = now
                    Self.leftCmdTapDisqualified = false
                    logDiagFromNonisolated(
                        "[advance-input] left-cmd down marinActive=\(marinActive)"
                    )
                    return false
                } else {
                    let elapsed = now - Self.leftCmdPressTimestamp
                    let withinTapWindow = elapsed > 0 && elapsed < Self.leftCmdTapMaxDurationSeconds
                    logDiagFromNonisolated(
                        "[advance-input] left-cmd up elapsed=\(Int(elapsed * 1000))ms disqualified=\(Self.leftCmdTapDisqualified) marinActive=\(marinActive)"
                    )
                    let willFire = marinActive && withinTapWindow && !Self.leftCmdTapDisqualified
                    // Reset the press timestamp regardless so the next
                    // press starts fresh.
                    Self.leftCmdPressTimestamp = 0
                    Self.leftCmdTapDisqualified = false
                    if willFire {
                        publishAdvance(.leftCmdTap)
                        return true
                    }
                    return false
                }
            }
            // Any OTHER modifier flag change while Left Cmd is held
            // disqualifies the tap (it's a chord, not a tap).
            if Self.leftCmdPressTimestamp > 0 && !Self.leftCmdTapDisqualified {
                let otherFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
                if !flags.intersection(otherFlags).isEmpty {
                    Self.leftCmdTapDisqualified = true
                    logDiagFromNonisolated(
                        "[advance-input] left-cmd tap disqualified by chord (modifier)"
                    )
                }
            }
            return false
        case .keyDown:
            // v15p3v (2026-05-21): disqualify the in-flight Left Cmd tap
            // when ANY regular key fires while Cmd is held. Previously
            // chord detection only caught modifier-flag changes, so
            // Cmd+V (V is a regular key, not a modifier) slipped through
            // and fired advance when Steph pasted Marin's clipboard URL.
            // We never consume the keyDown — just observe it.
            if Self.leftCmdPressTimestamp > 0 && !Self.leftCmdTapDisqualified {
                let chordKeycode = event.getIntegerValueField(.keyboardEventKeycode)
                Self.leftCmdTapDisqualified = true
                logDiagFromNonisolated(
                    "[advance-input] left-cmd tap disqualified by chord (keyDown keycode=\(chordKeycode))"
                )
            }
            return false
        default:
            return false
        }
    }

    /// Use IOHID to forcibly set caps lock state back to off. CGEvent
    /// taps can't suppress the kernel-level toggle that's already
    /// happened by the time our callback fires — IOHID is the
    /// system-of-record for the modifier lock state. Same approach
    /// Karabiner-Elements uses.
    ///
    /// Failing silently is acceptable — if the call doesn't go through,
    /// caps lock just stays toggled and Steph can press it again. The
    /// advance still fires either way.
    private nonisolated static func forceCapsLockOff() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != 0 else {
            Task { @MainActor in
                RealtimeConversationManager.appendDiag(
                    "[advance-input] forceCapsLockOff: IOServiceGetMatchingService failed"
                )
            }
            return
        }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        let openResult = IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &connect
        )
        guard openResult == KERN_SUCCESS else {
            Task { @MainActor in
                RealtimeConversationManager.appendDiag(
                    "[advance-input] forceCapsLockOff: IOServiceOpen failed kr=\(openResult)"
                )
            }
            return
        }
        defer { IOServiceClose(connect) }

        // false = caps lock off
        let setResult = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
        Task { @MainActor in
            RealtimeConversationManager.appendDiag(
                "[advance-input] forceCapsLockOff: IOHIDSetModifierLockState kr=\(setResult)"
            )
        }
    }

    /// Diag logger callable from the off-main CGEvent thread. Hops to
    /// MainActor for the actual append.
    private nonisolated func logDiagFromNonisolated(_ message: String) {
        Task { @MainActor in
            RealtimeConversationManager.appendDiag(message)
        }
    }

    private nonisolated func publishAdvance(_ trigger: AdvanceTrigger) {
        Task { @MainActor [weak self] in
            self?.advanceTriggeredPublisher.send(trigger)
        }
    }
}

/// NSObject bridge so the CGEvent callback (C, off-main) can call back
/// into the MainActor-isolated monitor without compiler complaints.
private final class MouseSideButtonMonitorBridge {
    weak var owner: MouseSideButtonMonitor?
    var eventTap: CFMachPort?

    init(owner: MouseSideButtonMonitor) { self.owner = owner }

    func processEventFromTap(eventType: CGEventType, event: CGEvent) -> Bool {
        owner?.handleEventNonisolated(eventType: eventType, event: event) ?? false
    }
}
