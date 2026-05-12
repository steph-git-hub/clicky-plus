//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1920
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// v15p2 (2026-05-02): Capture ONLY the active screen — the one
    /// containing the window with keyboard focus. Used by Realtime
    /// conversation mode to send a single per-press screenshot.
    ///
    /// Active screen detection priority:
    ///   1. NSScreen.main — the screen of the focused window (what
    ///      Apple semantically calls "main"). This is what users mean
    ///      by "active screen" — the one their focused app is on.
    ///   2. Cursor screen — if NSScreen.main is nil (rare), fall back
    ///      to whichever screen contains the mouse cursor.
    ///   3. NSScreen.screens.first — last-ditch fallback (primary
    ///      with menu bar).
    static func captureActiveScreenAsJPEG() async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard !content.displays.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]
            )
        }

        // Determine the target screen via NSScreen.main (focused-window
        // screen). Falls back to cursor screen, then primary.
        let mouseLocation = NSEvent.mouseLocation
        let targetNSScreen: NSScreen = {
            if let main = NSScreen.main {
                return main
            }
            if let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                return cursorScreen
            }
            return NSScreen.screens.first ?? NSScreen.screens[0]
        }()

        guard let targetDisplayID = targetNSScreen
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine display ID for active screen"]
            )
        }

        guard let targetDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Active screen not found in shareable content"]
            )
        }

        // Exclude Clicky's own windows so the AI sees only Steph's content.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        let displayFrame = targetNSScreen.frame
        let isCursorScreen = displayFrame.contains(mouseLocation)

        // v15p3ax (2026-05-11): cursor-window detection using CGWindowList.
        // SC's content.windows array order isn't reliable (smallest-area
        // heuristic also failed in v15p3aw). CGWindowListCopyWindowInfo IS
        // guaranteed front-to-back per Apple docs, so we use it for the
        // hit-test and then match the resulting CGWindowID back to an
        // SCWindow (since SCContentFilter requires SCWindow, not raw CG id).
        let focusedWindow: SCWindow? = {
            guard let primaryScreen = NSScreen.screens.first else { return nil }
            let cgMouse = CGPoint(
                x: mouseLocation.x,
                y: primaryScreen.frame.maxY - mouseLocation.y
            )

            // CGWindowList: front-to-back, on-screen only.
            let cgWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []

            // Find first window in z-order containing the cursor that
            // looks like a real app window.
            let hitID: CGWindowID? = cgWindows.first(where: { info in
                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
                guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else { return false }
                guard let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
                guard cgRect.width > 100, cgRect.height > 100 else { return false }
                guard cgRect.contains(cgMouse) else { return false }
                // Skip Clicky's own windows.
                if let ownerName = info[kCGWindowOwnerName as String] as? String,
                   ownerName == "Clicky" {
                    return false
                }
                if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                   pid == ProcessInfo.processInfo.processIdentifier {
                    return false
                }
                return true
            }).flatMap { $0[kCGWindowNumber as String] as? CGWindowID }

            // Diag (file log so Steph can read it later).
            let diag = "cursor-window: ns=(\(Int(mouseLocation.x)),\(Int(mouseLocation.y))) " +
                "cg=(\(Int(cgMouse.x)),\(Int(cgMouse.y))) " +
                "cgWindowsTotal=\(cgWindows.count) hitID=\(hitID.map(String.init) ?? "nil")"

            guard let id = hitID else {
                BuddyDictationManager.appendAudioDiag("\(diag) → no hit")
                return nil
            }

            // Match the CGWindowID back to an SCWindow.
            let matched = content.windows.first { $0.windowID == id }
            BuddyDictationManager.appendAudioDiag(
                "\(diag) → matched=\(matched?.owningApplication?.applicationName ?? "nil") " +
                "(\(Int(matched?.frame.width ?? 0))×\(Int(matched?.frame.height ?? 0)))"
            )
            return matched
        }()

        let filter: SCContentFilter
        let captureSourceWidth: CGFloat
        let captureSourceHeight: CGFloat
        let captureSourceFrame: CGRect
        let captureSourceLabel: String

        if let window = focusedWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureSourceWidth = window.frame.width
            captureSourceHeight = window.frame.height
            captureSourceFrame = window.frame
            let appName = window.owningApplication?.applicationName ?? "?"
            captureSourceLabel = "focused window of \(appName) " +
                "(\(Int(window.frame.width))×\(Int(window.frame.height)))"
        } else {
            filter = SCContentFilter(display: targetDisplay, excludingWindows: ownAppWindows)
            captureSourceWidth = CGFloat(targetDisplay.width)
            captureSourceHeight = CGFloat(targetDisplay.height)
            captureSourceFrame = displayFrame
            captureSourceLabel = "full display \(targetDisplayID) " +
                "(\(Int(displayFrame.width))×\(Int(displayFrame.height)))"
        }

        let configuration = SCStreamConfiguration()
        let maxDimension = 1920
        if captureSourceWidth >= captureSourceHeight {
            configuration.width = maxDimension
            configuration.height = Int(captureSourceHeight * CGFloat(maxDimension) / captureSourceWidth)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(captureSourceWidth * CGFloat(maxDimension) / captureSourceHeight)
        }
        configuration.width = max(configuration.width, 1)
        configuration.height = max(configuration.height, 1)

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"]
            )
        }

        let label = "active screen — \(captureSourceLabel)"

        return CompanionScreenCapture(
            imageData: jpegData,
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(captureSourceFrame.width),
            displayHeightInPoints: Int(captureSourceFrame.height),
            displayFrame: captureSourceFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}
