//
//  FocusedElementContextProvider.swift
//  leanring-buddy
//
//  Queries the macOS Accessibility API for the currently-focused UI
//  element, so typing mode can tell Claude exactly what kind of field
//  the user is about to paste into (Slack composer? email body? a
//  markdown editor? a terminal?).
//
//  This is READ-ONLY AX — we only copy attribute values, we never
//  synthesize events or mutate state. No extra permission beyond what
//  Clicky already requests (Accessibility) is required.
//
//  All failures here are silent and non-fatal: if AX can't tell us
//  anything about the focused element (locked field, Electron app
//  with a sparse tree, AX denied), we just return nil and typing
//  mode falls back to "screenshot only, no hint."
//

import AppKit
import ApplicationServices
import Foundation

/// A snapshot of the user's currently-focused UI element, captured
/// at the moment typing mode was engaged. Passed into the LLM prompt
/// so Claude can match tone/format to the destination.
struct FocusedElementContext {
    /// Localized name of the frontmost app (e.g. "Slack", "Mail", "Xcode").
    let appName: String?
    /// AX role, e.g. "AXTextArea", "AXTextField". Useful for coarse
    /// categorization (text area = long-form, text field = short input).
    let role: String?
    /// Human-readable role description, e.g. "text area", "search field".
    let roleDescription: String?
    /// Element's title/label if it has one, e.g. "Message #engineering",
    /// "Subject", "Body". Often the most informative single field.
    let label: String?
    /// Title of the containing window, e.g. the document name or tab
    /// title. Useful context especially when the element itself is
    /// unlabeled.
    let windowTitle: String?
    /// Up to the last ~200 characters of text already in the field.
    /// Gives Claude real examples of the user's voice/tone/tense so
    /// the paste blends in. Nil if the field is empty, secure, or
    /// AX refused to return its value.
    let recentText: String?
    /// Frame of the focused element in AX coordinate space (top-left
    /// origin, y-down, in POINTS, relative to the global display
    /// arrangement's top-left). Used to draw a bounding box on the
    /// screenshot before sending it to the model.
    let elementFrameInAXCoords: CGRect?

    /// True if we have at least one meaningful piece of context
    /// beyond the app name — otherwise we'd be adding noise to the
    /// prompt rather than signal.
    var hasMeaningfulContext: Bool {
        return role != nil
            || roleDescription != nil
            || label != nil
            || windowTitle != nil
            || recentText != nil
            || elementFrameInAXCoords != nil
    }
}

enum FocusedElementContextProvider {

    /// Upper bound on the amount of existing field text we include in
    /// the prompt. 200 chars is enough to capture tone and a sentence
    /// or two of immediate context; more just costs tokens.
    private static let recentTextCharLimit = 200

    /// Capture the currently-focused element's context. Must be called
    /// on the main thread because AX APIs are not thread-safe and
    /// NSWorkspace lookups depend on main-thread state. Returns nil
    /// on any failure (no focused element, AX denied, etc.).
    @MainActor
    static func capture() -> FocusedElementContext? {
        // Step 1: find the frontmost app. This is the app that has
        // keyboard focus — typing mode is always targeting its
        // focused text field.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName

        // Step 2: get the AX root element for that app.
        let appElement = AXUIElementCreateApplication(pid)

        // Step 3: ask for the focused UI element inside it. This is
        // the element currently receiving keyboard input — exactly
        // what we want for typing mode.
        guard let focused = copyAXElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute) else {
            // No focused element — probably a non-text app. Still
            // useful to at least know the app name.
            return FocusedElementContext(
                appName: appName,
                role: nil,
                roleDescription: nil,
                label: nil,
                windowTitle: nil,
                recentText: nil,
                elementFrameInAXCoords: nil
            )
        }

        // Step 4: pull the attributes we care about. All reads are
        // defensive — any individual attribute may be missing.
        let role = copyAXStringAttribute(focused, attribute: kAXRoleAttribute)
        let roleDescription = copyAXStringAttribute(focused, attribute: kAXRoleDescriptionAttribute)

        // Label: try AXTitle first, then AXDescription, then AXPlaceholderValue.
        // Different apps expose identifying text under different keys;
        // any of them is fine as a human-readable label.
        let label = copyAXStringAttribute(focused, attribute: kAXTitleAttribute)
            ?? copyAXStringAttribute(focused, attribute: kAXDescriptionAttribute)
            ?? copyAXStringAttribute(focused, attribute: "AXPlaceholderValue")

        // Window title: walk up via AXWindow, then read its title.
        let windowTitle = copyAXElementAttribute(focused, attribute: kAXWindowAttribute)
            .flatMap { copyAXStringAttribute($0, attribute: kAXTitleAttribute) }

        // Recent text: AXValue on a text element is the current text.
        // Slice off the tail so we send a manageable amount.
        let recentText = copyAXStringAttribute(focused, attribute: kAXValueAttribute)
            .map { trimToSuffix($0, maxLength: recentTextCharLimit) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Element frame: AXPosition + AXSize come back as AXValue
        // boxes that we unpack with AXValueGetValue.
        let elementFrame = copyAXFrame(focused)

        let context = FocusedElementContext(
            appName: appName,
            role: role,
            roleDescription: roleDescription,
            label: label,
            windowTitle: windowTitle,
            recentText: recentText,
            elementFrameInAXCoords: elementFrame
        )
        return context
    }

    /// v15p3cn (2026-05-13): Marin Vision Option B — capture the AX
    /// element AT the cursor position (not the focused element). Used
    /// by Marin's vision path to tell her exactly what UI element the
    /// user is hovering over, regardless of which element has keyboard
    /// focus. Mirrors Google DeepMind's "HOVERING: <element_id>" pattern
    /// in their Gemini AI cursor demo.
    ///
    /// Uses AXUIElementCopyElementAtPosition with the system-wide
    /// AX element as the root — that finds the deepest accessibility
    /// node at the given screen point, across any app. Coordinates are
    /// in AX space (top-left origin, y-down, primary-anchored points).
    ///
    /// Returns nil if AX is disabled, the cursor isn't over any app
    /// that exposes accessibility, or the lookup fails — caller falls
    /// back to "screenshot only, no hover context."
    @MainActor
    static func captureAtCursor() -> FocusedElementContext? {
        // Convert cursor position from AppKit (bottom-left) to AX
        // (top-left, primary-anchored). The origin-zero NSScreen is
        // the primary; AppKit y is measured from primary's bottom.
        let mouseLocation = NSEvent.mouseLocation
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let primaryHeight = primaryScreen?.frame.height else { return nil }
        let axX = Float(mouseLocation.x)
        let axY = Float(primaryHeight - mouseLocation.y)

        // Ask AX for the deepest element at that point. Note this is
        // the "leaf" — e.g., a specific button, not its parent group.
        let systemElement = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemElement, axX, axY, &elementRef)
        guard result == .success, let element = elementRef else {
            return nil
        }

        // Pull the same attributes the focused-capture path reads, but
        // from the element under the cursor. The frontmost app is
        // typically the one being hovered (cursor over Chrome → Chrome
        // is frontmost), but if not we still record it for context.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName

        let role = copyAXStringAttribute(element, attribute: kAXRoleAttribute)
        let roleDescription = copyAXStringAttribute(element, attribute: kAXRoleDescriptionAttribute)
        // Try several common label attributes — different app frameworks
        // (AppKit, Electron, Chrome, Safari) expose human-readable text
        // under different keys.
        let label = copyAXStringAttribute(element, attribute: kAXTitleAttribute)
            ?? copyAXStringAttribute(element, attribute: kAXDescriptionAttribute)
            ?? copyAXStringAttribute(element, attribute: "AXPlaceholderValue")
            ?? copyAXStringAttribute(element, attribute: "AXIdentifier")

        // The value of a text-bearing element is its content. Trim to
        // the last ~200 chars to keep token cost bounded.
        let recentText = copyAXStringAttribute(element, attribute: kAXValueAttribute)
            .map { trimToSuffix($0, maxLength: recentTextCharLimit) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Walk up to the window for the containing-page/document
        // context. This is the most reliable signal of "what page or
        // document is this on" — e.g., the Chrome tab title.
        let windowTitle = copyAXElementAttribute(element, attribute: kAXWindowAttribute)
            .flatMap { copyAXStringAttribute($0, attribute: kAXTitleAttribute) }

        let elementFrame = copyAXFrame(element)

        return FocusedElementContext(
            appName: appName,
            role: role,
            roleDescription: roleDescription,
            label: label,
            windowTitle: windowTitle,
            recentText: recentText,
            elementFrameInAXCoords: elementFrame
        )
    }

    /// v15p3cn (2026-05-13): build a one-line human-readable summary
    /// of what the cursor is over, suitable for inclusion in Marin's
    /// prompt. Examples:
    ///   "Hovering over: button labeled 'Discard Changes' in window
    ///    'Marin Vision Benchmark'"
    ///   "Hovering over: text 'Quantum mechanics predicts particle...'
    ///    in window 'Marin Vision Benchmark'"
    ///   "Hovering over: link 'Privacy Policy' on page 'X · Bookmarks'"
    /// Returns nil if no useful info is available.
    static func describeForHoverHint(_ context: FocusedElementContext) -> String? {
        // Prefer a clean role name. AX roles come back as "AXButton",
        // "AXTextField", "AXStaticText" etc. — strip the AX prefix and
        // lowercase the remainder for readability.
        let prettyRole: String? = {
            guard let r = context.role else { return context.roleDescription }
            let stripped = r.hasPrefix("AX") ? String(r.dropFirst(2)) : r
            return stripped.lowercased()
        }()

        // Build the element description. Prefer label, fall back to a
        // short snippet of the element's value/text content.
        let elementText: String? = {
            if let label = context.label, !label.isEmpty {
                return "'\(label)'"
            }
            if let value = context.recentText, !value.isEmpty {
                // Quote a short snippet so Marin can recognize text.
                let snippet = value.count > 60 ? String(value.prefix(60)) + "…" : value
                return "'\(snippet)'"
            }
            return nil
        }()

        var parts: [String] = []
        if let role = prettyRole, let text = elementText {
            parts.append("\(role) \(text)")
        } else if let role = prettyRole {
            parts.append(role)
        } else if let text = elementText {
            parts.append(text)
        }
        if let window = context.windowTitle, !window.isEmpty {
            parts.append("in window '\(window)'")
        } else if let app = context.appName, !app.isEmpty {
            parts.append("in \(app)")
        }
        guard !parts.isEmpty else { return nil }
        return "Hovering over: " + parts.joined(separator: " ")
    }

    // MARK: - Low-level AX helpers

    /// Copy an arbitrary AX attribute. Returns nil if the attribute
    /// isn't set or the API call fails.
    private static func copyAXAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    /// Fetch an attribute that should be an AXUIElement. AXUIElement is a
    /// CoreFoundation type, so `as?` downcasts always succeed at the
    /// language level (Swift emits a warning/error). Instead we gate on
    /// CFGetTypeID and force-cast once we've verified the type.
    private static func copyAXElementAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        guard let value = copyAXAttribute(element, attribute: attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Copy an AX attribute expected to be a String.
    private static func copyAXStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        return copyAXAttribute(element, attribute: attribute) as? String
    }

    /// Read AXPosition + AXSize and return the combined CGRect in AX
    /// coordinate space (top-left origin, y-down, in points, across
    /// the full multi-display arrangement).
    private static func copyAXFrame(_ element: AXUIElement) -> CGRect? {
        // Both attributes return AXValue boxes. Guard on the CFTypeID
        // instead of force-casting — if an app returns something
        // unexpected we'd rather skip the box than crash the app.
        guard let posRaw = copyAXAttribute(element, attribute: kAXPositionAttribute),
              let sizeRaw = copyAXAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        let posValue = posRaw as! AXValue
        let sizeValue = sizeRaw as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Human-readable label for an AXError raw code. Useful for
    /// diagnostic logging so we can tell at a glance whether AX
    /// failed because TCC blocked the call (apiDisabled), the app
    /// doesn't expose the attribute (cannotComplete / notImplemented),
    /// or something else entirely.
    private static func describeAXErrorCode(_ axError: AXError) -> String {
        switch axError {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled (TCC accessibility blocked)"
        case .noValue: return "noValue (attribute exists but is empty/nil)"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(axError.rawValue))"
        }
    }

    /// Return the last `maxLength` characters of a string, trimmed
    /// of leading/trailing whitespace. If the string is shorter,
    /// return it as-is (still trimmed).
    private static func trimToSuffix(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let startIndex = trimmed.index(trimmed.endIndex, offsetBy: -maxLength)
        // Prepend "…" so Claude knows this is a tail, not the whole field.
        return "…" + trimmed[startIndex..<trimmed.endIndex]
    }

    // MARK: - Polish: read full focused field text + any selection
    //
    // Polish mode (voice "polish" command in voice-to-text, or the
    // ⌃⌥⌘ polish hotkey) operates ON existing text in the focused
    // field, not on new spoken input. It needs the full text (no
    // 200-char cap) and the selected-text range if anything is
    // highlighted. The default `capture()` above is tuned for typing
    // mode and intentionally truncates `recentText`, so we provide
    // a separate path here rather than overload the typing-mode call.

    /// Snapshot of the focused field's content for polish-style
    /// transformations. Captured at the moment polish was triggered.
    /// All fields are best-effort: any can be nil if AX refused to
    /// answer (locked field, sparse Electron tree, no focused element,
    /// etc.). The polish caller decides what to do with partial data.
    struct FocusedFieldContent {
        /// Localized name of the frontmost app, for tone hints sent
        /// to the polish system prompt (e.g. "Slack", "Mail").
        let appName: String?
        /// AX role of the focused element (e.g. "AXTextArea").
        let role: String?
        /// Title of the containing window — extra tone hint.
        let windowTitle: String?
        /// Full text in the focused field, NOT truncated. Polish
        /// may operate on this entire string when no selection
        /// exists. nil if AX refused or the field is non-textual.
        let fullFieldText: String?
        /// Just the highlighted text, if any. nil if nothing is
        /// selected (the typical "no selection" case from AX is
        /// an empty string — we normalize that to nil here so the
        /// caller's `if let selectedText = ...` works as expected).
        let selectedText: String?
        /// Range of `selectedText` within `fullFieldText`, in UTF-16
        /// code units (AX's native unit). nil if nothing is selected.
        let selectedRange: NSRange?
    }

    /// Capture the full text + selection from the currently-focused
    /// field. Used by the polish command bus and ⌃⌥⌘ hotkey. Must be
    /// called on the main thread for the same AX-thread-safety reason
    /// as `capture()`. Returns nil only if there's no frontmost app
    /// at all — every other failure surfaces as a nil sub-field on
    /// the returned struct so the caller can still proceed.
    @MainActor
    static func captureFieldContentForPolish() -> FocusedFieldContent? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("✨ Polish-AX: NSWorkspace.frontmostApplication returned nil")
            return nil
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName

        // Diagnostic: also report the raw AX trust state so we can
        // distinguish "TCC says no" from "AX returned nothing for this app".
        let isAxApiTrusted = AXIsProcessTrusted()
        print("✨ Polish-AX: app=\(appName ?? "nil") pid=\(pid) AXIsProcessTrusted=\(isAxApiTrusted)")

        let appElement = AXUIElementCreateApplication(pid)

        // Force Chromium-based apps (Chrome, Slack, Cowork, VS Code,
        // Discord, Electron apps in general) to expose their full
        // accessibility tree. By default Chromium lazily activates AX
        // only when it detects a "trusted accessibility client" via
        // specific signals — and that detection has been observed to
        // fail or stop working unpredictably (broke for us 2026-04-26
        // even though Clicky's TCC entry was granted). Setting
        // AXManualAccessibility=true is the documented way to force
        // activation explicitly. This is a no-op on native AppKit apps
        // (they ignore the unknown attribute), so it's safe to always
        // call. Set BEFORE the first attribute query so Chromium has
        // time to flip its internal accessibility-enabled state.
        let axManualAccessibilityActivationResult = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        if axManualAccessibilityActivationResult != .success {
            // Not fatal — many apps don't accept the attribute (and
            // that's fine, they're either non-Chromium or already in
            // full AX mode). Log for diagnostic visibility.
            print("✨ Polish-AX: AXManualAccessibility set returned \(axManualAccessibilityActivationResult.rawValue) (non-fatal)")
        }

        // Direct call to AXUIElementCopyAttributeValue so we can capture
        // the actual AXError code. The convenience helpers below collapse
        // every error to nil, which is fine for production but useless
        // for diagnosing TCC vs not-implemented vs no-value cases.
        var rawFocused: AnyObject?
        let focusedQueryErrorCode = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &rawFocused
        )
        print("✨ Polish-AX: focused-element query errorCode=\(focusedQueryErrorCode.rawValue) (\(describeAXErrorCode(focusedQueryErrorCode))) gotValue=\(rawFocused != nil)")

        // Without a focused element we can't read field text or
        // selection — but we still return the app name so the polish
        // caller can decide whether to surface a "nothing to polish"
        // toast vs silently no-op.
        guard focusedQueryErrorCode == .success,
              let rawFocusedNonNil = rawFocused,
              CFGetTypeID(rawFocusedNonNil) == AXUIElementGetTypeID() else {
            return FocusedFieldContent(
                appName: appName,
                role: nil,
                windowTitle: nil,
                fullFieldText: nil,
                selectedText: nil,
                selectedRange: nil
            )
        }
        let focused = rawFocusedNonNil as! AXUIElement

        let role = copyAXStringAttribute(focused, attribute: kAXRoleAttribute)

        let windowTitle = copyAXElementAttribute(focused, attribute: kAXWindowAttribute)
            .flatMap { copyAXStringAttribute($0, attribute: kAXTitleAttribute) }

        // Full field text: AXValue. Unlike capture() above, we do
        // NOT truncate — polish needs the whole thing to operate on.
        let fullFieldText = copyAXStringAttribute(focused, attribute: kAXValueAttribute)

        // Selected text: AXSelectedText is the actual highlighted
        // string. AX returns "" when nothing is selected, which we
        // normalize to nil so callers can use `if let` cleanly.
        let rawSelectedText = copyAXStringAttribute(focused, attribute: kAXSelectedTextAttribute)
        let selectedText: String? = (rawSelectedText?.isEmpty ?? true) ? nil : rawSelectedText

        // Selected range: AXSelectedTextRange is an AXValue box
        // wrapping a CFRange. We only return it if a non-empty
        // selection exists (matches selectedText behavior).
        let selectedRange: NSRange?
        if selectedText != nil,
           let rawRangeValue = copyAXAttribute(focused, attribute: kAXSelectedTextRangeAttribute),
           CFGetTypeID(rawRangeValue) == AXValueGetTypeID() {
            let axRangeValue = rawRangeValue as! AXValue
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(axRangeValue, .cfRange, &cfRange) {
                selectedRange = NSRange(location: cfRange.location, length: cfRange.length)
            } else {
                selectedRange = nil
            }
        } else {
            selectedRange = nil
        }

        return FocusedFieldContent(
            appName: appName,
            role: role,
            windowTitle: windowTitle,
            fullFieldText: fullFieldText,
            selectedText: selectedText,
            selectedRange: selectedRange
        )
    }
}
