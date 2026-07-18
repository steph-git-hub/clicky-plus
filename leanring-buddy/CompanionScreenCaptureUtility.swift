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
    /// v15p3ca (2026-05-13): cursor position in image-pixel coordinates
    /// (top-left origin) at the moment this screenshot was captured.
    /// Computed inside the capture function while we still have the
    /// authoritative cursor reading + captureSourceFrame in scope —
    /// avoids the coord-space ambiguity of doing it later from outside.
    /// Nil when the cursor wasn't on the captured region (e.g.,
    /// multi-display + cursor on a different screen, or window-crop
    /// where cursor is over a different window).
    let cursorPositionInImagePixels: CGPoint?
    /// v15p3cp (2026-05-13): the pre-JPEG CGImage bitmap. Exposed for
    /// downstream consumers (currently Marin's vision OCR pass) that
    /// want to read the original pixels without paying the JPEG-decode
    /// round-trip — JPEG at q=0.92 softens fine character edges enough
    /// to noticeably hurt Vision.framework's recognition accuracy on
    /// small UI text. Stays nil if the capture path didn't preserve the
    /// CGImage, so callers should fall back to decoding `imageData`.
    let cgImage: CGImage?
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
        //
        // v15p3i (2026-05-19): explicit allowlist for user-visible
        // Clicky UI (currently the settings panel). When Steph asks
        // Marin to read directions IN the Clicky panel, she needs to
        // actually see the panel — the broad bundle-id filter
        // otherwise made her blind to her own UI.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let allowedOwnWindowTitles: Set<String> = [
            "Clicky Settings Panel"
        ]
        let ownAppWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == ownBundleIdentifier else { return false }
            if let title = window.title, allowedOwnWindowTitles.contains(title) {
                return false
            }
            return true
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

            // v15p3ca (2026-05-13): compute cursor position in image
            // pixel coords for this screen. NSEvent.mouseLocation is
            // AppKit (bottom-left, primary-anchored). displayFrame
            // here is AppKit too (from NSScreen.frame), so we can stay
            // in one coord space. Only set when cursor is on this
            // screen; nil for the other screens in multi-display.
            let cursorPixelsForThisScreen: CGPoint? = {
                guard isCursorScreen else { return nil }
                let localPointX = mouseLocation.x - displayFrame.origin.x
                let localPointAppKitY = mouseLocation.y - displayFrame.origin.y
                // Flip Y: AppKit bottom-left → screenshot top-left.
                let localPointTopLeftY = displayFrame.height - localPointAppKitY
                let scaleX = CGFloat(configuration.width) / displayFrame.width
                let scaleY = CGFloat(configuration.height) / displayFrame.height
                return CGPoint(
                    x: localPointX * scaleX,
                    y: localPointTopLeftY * scaleY
                )
            }()

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                cursorPositionInImagePixels: cursorPixelsForThisScreen,
                cgImage: cgImage
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
    /// v15p4bh (2026-05-26): added `maxDimension` parameter for Watch
    /// Mode. The default 1920 keeps Marin's per-press vision sharp;
    /// Watch Mode passes 1280 to cut JPEG payload ~6× and per-frame
    /// token cost ~4×, which is the main lever for higher effective
    /// FPS in the streaming-frame pipeline.
    static func captureActiveScreenAsJPEG(maxDimension: Int = 1920, windowCrop: Bool = true) async throws -> CompanionScreenCapture {
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
        // v15p3i (2026-05-19): allowlist user-visible Clicky UI
        // (settings panel) so Marin can read her own panel when Steph
        // points her at it. Hidden overlays opt out via
        // sharingType = .none and never appear in content.windows.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let allowedOwnWindowTitles: Set<String> = [
            "Clicky Settings Panel"
        ]
        let ownAppWindows = content.windows.filter { window in
            guard window.owningApplication?.bundleIdentifier == ownBundleIdentifier else { return false }
            if let title = window.title, allowedOwnWindowTitles.contains(title) {
                return false
            }
            return true
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
            // v16r13: skip window-crop when the caller wants a FULL-SCREEN capture.
            // The highlight grounding needs the display frame (NSScreen, AppKit
            // bottom-left) for a correct coordinate map; a window crop returns the
            // window frame in CG top-left coords, which mismapped the box off-screen
            // on secondary monitors.
            guard windowCrop else { return nil }
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
                // Skip Clicky's own windows — EXCEPT the Settings
                // Panel, which Marin should be able to look at when
                // the cursor is over it. v15p3i (2026-05-19).
                let windowName = info[kCGWindowName as String] as? String
                let isAllowedOwnUI = (windowName == "Clicky Settings Panel")
                if isAllowedOwnUI { return true }
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
        if captureSourceWidth >= captureSourceHeight {
            configuration.width = maxDimension
            configuration.height = Int(captureSourceHeight * CGFloat(maxDimension) / captureSourceWidth)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(captureSourceWidth * CGFloat(maxDimension) / captureSourceHeight)
        }
        configuration.width = max(configuration.width, 1)
        configuration.height = max(configuration.height, 1)

        let rawCgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        // v15p3ce (2026-05-13): detect actual content bounds in the
        // captured image.
        // v15p3cl (2026-05-13): CROP the image to detected content
        // bounds before encoding. Black padding on Sceptre was
        // confusing Marin's vision (she couldn't find the cursor
        // amid the blank zones). Cropping gives a clean image with
        // no padding noise. On MacBook (no padding detected) this
        // is a no-op crop.
        let detectedContentBounds = detectActualContentBoundsInImage(rawCgImage)
        let contentPixelWidth = Int(detectedContentBounds.width)
        let contentPixelHeight = Int(detectedContentBounds.height)
        let contentPixelOffsetX = Int(detectedContentBounds.origin.x)
        let contentPixelOffsetY = Int(detectedContentBounds.origin.y)
        if contentPixelWidth != configuration.width
            || contentPixelHeight != configuration.height
            || contentPixelOffsetX != 0
            || contentPixelOffsetY != 0 {
            BuddyDictationManager.appendAudioDiag(
                "content-bounds: detected blank padding — image=(\(configuration.width)×\(configuration.height)) " +
                "content=(\(contentPixelWidth)×\(contentPixelHeight)) " +
                "topLeft=(\(contentPixelOffsetX),\(contentPixelOffsetY)) " +
                "rightPadding=\(configuration.width - contentPixelWidth - contentPixelOffsetX)px " +
                "bottomPadding=\(configuration.height - contentPixelHeight - contentPixelOffsetY)px " +
                "→ cropping output to content bounds"
            )
        }
        // Crop to content bounds. Falls back to original if cropping
        // fails (cropping(to:) returns nil for invalid rects).
        let cgImage: CGImage = {
            let needsCrop = contentPixelWidth != rawCgImage.width
                || contentPixelHeight != rawCgImage.height
                || contentPixelOffsetX != 0
                || contentPixelOffsetY != 0
            guard needsCrop else { return rawCgImage }
            let cropRect = CGRect(
                x: contentPixelOffsetX,
                y: contentPixelOffsetY,
                width: contentPixelWidth,
                height: contentPixelHeight
            )
            return rawCgImage.cropping(to: cropRect) ?? rawCgImage
        }()
        // After cropping, the effective output size is the content
        // size. Update the configuration's dimensions for the
        // returned struct so downstream consumers see the right pixel
        // counts.
        let outputPixelWidth = cgImage.width
        let outputPixelHeight = cgImage.height

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"]
            )
        }

        let label = "active screen — \(captureSourceLabel)"

        // v15p3ca (2026-05-13): cursor position in image pixel coords.
        // v15p3cb (2026-05-13): fixed primary-screen lookup + added diag.
        // Two cases:
        //   1. Window capture — captureSourceFrame is window.frame in
        //      CG coords (top-left, primary-anchored). Convert
        //      mouseLocation (AppKit/bottom-left) to CG using the
        //      origin-zero screen (NOT screens.first which can be a
        //      different display in multi-monitor setups). Then
        //      subtract window origin and scale to pixels.
        //   2. Display capture — captureSourceFrame is displayFrame
        //      from NSScreen (AppKit). Use AppKit math and y-flip
        //      within the local region.
        // v15p3ce (2026-05-13): scaling factor uses CONTENT pixel
        // bounds (detected above), not the full output image.
        // v15p3cf (2026-05-13): corrected the formula. The previous
        // version derived an intermediate "visibleSourceWidth" that
        // turned out to be wrong — the ENTIRE captureSourceFrame is
        // visible content (in points). The black padding in the
        // output image is purely an SCStream output artifact (when
        // the display is rendering at 1:1 backing scale and can't
        // upscale to fill the requested configuration size).
        //
        // Correct relationship:
        //   contentPixelWidth (pixels) represents captureSourceFrame.width (points)
        //   So: pixels per point = contentPixelWidth / frame.width
        //
        // Worked example (Sceptre, 1:1 backing):
        //   frame=1714pt, content=1714px, image=1920px, padding=206px
        //   scaleX = 1714/1714 = 1.0 ✓
        //
        // Worked example (MacBook Retina, 2x backing, content fills image):
        //   frame=1512pt, content=1920px (no padding), image=1920px
        //   scaleX = 1920/1512 = 1.27 ✓
        // v15p3cm (2026-05-13): switched scale from detected-content-bounds
        // to configuration-aspect-fit scale (uniform). Empirical analysis
        // showed marker was 20-30px above cursor with detected scale —
        // matches the difference between detected scale (1.09) and config
        // scale (1.12) on Sceptre. SCStream appears to render the cursor
        // using the configured output aspect-fit scale, not the actual
        // rendered content ratio. Using config scale puts the marker on
        // the cursor.
        let scaleX = captureSourceFrame.width > 0
            ? CGFloat(configuration.width) / captureSourceFrame.width
            : 0
        let scaleY = captureSourceFrame.height > 0
            ? CGFloat(configuration.height) / captureSourceFrame.height
            : 0
        BuddyDictationManager.appendAudioDiag(
            "cursor-marker: scales=(\(String(format: "%.3f", scaleX)),\(String(format: "%.3f", scaleY))) config=(\(configuration.width)×\(configuration.height)) frame=(\(Int(captureSourceFrame.width))×\(Int(captureSourceFrame.height)))"
        )
        let visibleSourceWidth = captureSourceFrame.width
        let visibleSourceHeight = captureSourceFrame.height

        let cursorPixels: CGPoint? = {
            if focusedWindow != nil {
                let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                    ?? NSScreen.screens.first
                guard let primaryHeight = primaryScreen?.frame.height else { return nil }
                let cgMouse = CGPoint(
                    x: mouseLocation.x,
                    y: primaryHeight - mouseLocation.y
                )
                let inside = captureSourceFrame.contains(cgMouse)
                BuddyDictationManager.appendAudioDiag(
                    "cursor-marker: window-capture ns=(\(Int(mouseLocation.x)),\(Int(mouseLocation.y))) " +
                    "cg=(\(Int(cgMouse.x)),\(Int(cgMouse.y))) " +
                    "winFrame=(\(Int(captureSourceFrame.origin.x)),\(Int(captureSourceFrame.origin.y)),\(Int(captureSourceFrame.width))×\(Int(captureSourceFrame.height))) " +
                    "visibleSrc=(\(Int(visibleSourceWidth))×\(Int(visibleSourceHeight))) " +
                    "primaryH=\(Int(primaryHeight)) inside=\(inside)"
                )
                guard inside else { return nil }
                let localX = cgMouse.x - captureSourceFrame.origin.x
                let localY = cgMouse.y - captureSourceFrame.origin.y
                // If cursor is in the off-content padding zone, clamp
                // to nil so we don't draw a marker that lands in the
                // black void. visibleSource defines where actual
                // content lives.
                guard localX <= visibleSourceWidth, localY <= visibleSourceHeight else {
                    BuddyDictationManager.appendAudioDiag(
                        "cursor-marker: cursor in padding zone, suppressing marker " +
                        "(localPt=(\(Int(localX)),\(Int(localY))) > visibleSrc)"
                    )
                    return nil
                }
                // v15p3ci: ADD content top/left offset so the dot lands
                // inside the detected content area, not in the padding
                // above/left of it.
                // v15p3cj REVERTED (2026-05-13): hotspot offset was wrong
                // direction — Steph points with the cursor TIP (which
                // IS the hotspot), not the cursor body. Removed the +5/+13
                // compensation.
                return CGPoint(
                    x: localX * scaleX + CGFloat(contentPixelOffsetX),
                    y: localY * scaleY + CGFloat(contentPixelOffsetY)
                )
            } else {
                BuddyDictationManager.appendAudioDiag(
                    "cursor-marker: display-capture isCursorScreen=\(isCursorScreen) " +
                    "ns=(\(Int(mouseLocation.x)),\(Int(mouseLocation.y))) " +
                    "displayFrame=(\(Int(captureSourceFrame.origin.x)),\(Int(captureSourceFrame.origin.y)),\(Int(captureSourceFrame.width))×\(Int(captureSourceFrame.height)))"
                )
                guard isCursorScreen else { return nil }
                let localX = mouseLocation.x - captureSourceFrame.origin.x
                let localAppKitY = mouseLocation.y - captureSourceFrame.origin.y
                let localTopLeftY = captureSourceFrame.height - localAppKitY
                guard localX <= visibleSourceWidth, localTopLeftY <= visibleSourceHeight else {
                    return nil
                }
                return CGPoint(
                    x: localX * scaleX + CGFloat(contentPixelOffsetX),
                    y: localTopLeftY * scaleY + CGFloat(contentPixelOffsetY)
                )
            }
        }()
        if let p = cursorPixels {
            BuddyDictationManager.appendAudioDiag(
                "cursor-marker: pixelPoint=(\(Int(p.x)),\(Int(p.y))) " +
                "image=(\(configuration.width)×\(configuration.height))"
            )
        } else {
            BuddyDictationManager.appendAudioDiag("cursor-marker: NO pixel point — marker will NOT be drawn")
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: label,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(captureSourceFrame.width),
            displayHeightInPoints: Int(captureSourceFrame.height),
            displayFrame: captureSourceFrame,
            // v15p3cl (2026-05-13): use cropped output dimensions
            // since we no longer pass through the full image with
            // black padding.
            screenshotWidthInPixels: outputPixelWidth,
            screenshotHeightInPixels: outputPixelHeight,
            cursorPositionInImagePixels: cursorPixels,
            // v15p3cp (2026-05-13): expose the cropped CGImage so Marin's
            // OCR pass can run on raw pixels instead of decoding the JPEG.
            cgImage: cgImage
        )
    }

    /// v15p3ck (2026-05-13): find the macOS arrow cursor in the
    /// captured image and return its tip pixel position. The cursor
    /// is rendered by SCStream when `showsCursor` is true (default).
    /// Computing cursor position from window/frame math has too many
    /// edge cases (non-Retina displays, off-display windows, scale
    /// asymmetry). The cursor is visibly correct in the image — we
    /// just need to locate it.
    ///
    /// Algorithm: in a search region centered on the approximate
    /// pixel position (from our coord-math estimate), look for a
    /// cluster of very dark pixels with bright surroundings — the
    /// signature of the macOS arrow cursor. Return the top-left
    /// (smallest x, smallest y) of the dark cluster — that's the
    /// arrow's tip / hotspot.
    ///
    /// Returns nil if no plausible cursor cluster is found (cursor
    /// hidden, fullscreen video, etc.) — caller falls back to the
    /// coord-math estimate.
    static func findCursorTipPixelInImage(
        _ image: CGImage,
        nearPixel: CGPoint,
        searchRadiusPx: Int = 60
    ) -> CGPoint? {
        let width = image.width
        let height = image.height

        // Sample a square region centered on nearPixel.
        let cx = Int(nearPixel.x.rounded())
        let cy = Int(nearPixel.y.rounded())
        let regionMinX = max(0, cx - searchRadiusPx)
        let regionMaxX = min(width - 1, cx + searchRadiusPx)
        let regionMinY = max(0, cy - searchRadiusPx)
        let regionMaxY = min(height - 1, cy + searchRadiusPx)
        guard regionMaxX > regionMinX, regionMaxY > regionMinY else { return nil }

        // Render the region's pixels into a byte buffer for sampling.
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Threshold: a pixel is "cursor-dark" if all RGB below this.
        // macOS arrow cursor is black-on-white, so the dark interior
        // of the arrow is very near (0,0,0).
        let darkThreshold: UInt8 = 50
        // Brightness check for "outline": the cursor has a white-ish
        // border. We use this to discriminate cursor-dark from
        // "this entire region is dark UI" (e.g., dark-mode app).
        let lightThreshold: UInt8 = 200

        func rgbAt(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (pixelData[offset], pixelData[offset + 1], pixelData[offset + 2])
        }
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgbAt(x: x, y: y)
            return r < darkThreshold && g < darkThreshold && b < darkThreshold
        }
        func isLight(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgbAt(x: x, y: y)
            return r > lightThreshold && g > lightThreshold && b > lightThreshold
        }

        // First pass: collect dark pixels in the region.
        var darkPixels: [(Int, Int)] = []
        for y in regionMinY...regionMaxY {
            for x in regionMinX...regionMaxX {
                if isDark(x, y) {
                    darkPixels.append((x, y))
                }
            }
        }

        // No dark pixels at all → no cursor here.
        // Too many → likely a dark-mode UI region, not a cursor.
        // macOS arrow is ~80–250 dark pixels at typical sizes.
        guard darkPixels.count >= 15, darkPixels.count <= 800 else { return nil }

        // Validate it's cursor-shaped: at least one of the dark pixels
        // must have a nearby LIGHT pixel (the arrow's outline). If
        // every dark pixel is surrounded by dark, this is dark UI not
        // a cursor.
        let outlineCheckRadius = 4
        var hasOutline = false
        outlineCheck: for (x, y) in darkPixels.prefix(50) {
            for dy in -outlineCheckRadius...outlineCheckRadius {
                for dx in -outlineCheckRadius...outlineCheckRadius {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    if isLight(nx, ny) {
                        hasOutline = true
                        break outlineCheck
                    }
                }
            }
        }
        guard hasOutline else { return nil }

        // The cursor tip is the topmost-leftmost dark pixel.
        // Sort by (y, x) ascending — smallest y first, then smallest x.
        var topLeftY = Int.max
        var topLeftX = Int.max
        for (x, y) in darkPixels {
            if y < topLeftY || (y == topLeftY && x < topLeftX) {
                topLeftY = y
                topLeftX = x
            }
        }
        guard topLeftY != Int.max else { return nil }

        BuddyDictationManager.appendAudioDiag(
            "cursor-marker: detected cursor in image at (\(topLeftX),\(topLeftY)) " +
            "— darkPixels=\(darkPixels.count) hadOutline=\(hasOutline) " +
            "[was estimating (\(Int(nearPixel.x)),\(Int(nearPixel.y)))]"
        )
        return CGPoint(x: topLeftX, y: topLeftY)
    }

    /// v15p3ce (2026-05-13): scan a captured CGImage for blank black
    /// padding on all four edges. Returns the bounds of actual content
    /// (origin may be non-zero if there's top or left padding).
    /// v15p3ci (2026-05-13): added top and left edge scanning. Previously
    /// only scanned right and bottom, which missed top padding that
    /// shifted the cursor marker upward.
    /// Algorithm: from each edge inward in coarse 8-px steps, find the
    /// first row/column containing a non-blank pixel. "Blank" means
    /// all RGB values below a low threshold (near pure black).
    private static func detectActualContentBoundsInImage(_ image: CGImage) -> CGRect {
        let width = image.width
        let height = image.height
        guard width > 100, height > 100 else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A pixel is "blank" if all RGB values fall below this threshold.
        // Tuned for the macOS off-display black render (typically exact
        // 0,0,0 but JPEG compression can nudge it a few values).
        let blankThreshold: UInt8 = 12
        let scanStep = 8

        func columnHasContent(_ x: Int) -> Bool {
            var y = 0
            while y < height {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if pixelData[offset] > blankThreshold
                    || pixelData[offset + 1] > blankThreshold
                    || pixelData[offset + 2] > blankThreshold {
                    return true
                }
                y += scanStep
            }
            return false
        }

        func rowHasContent(_ y: Int) -> Bool {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if pixelData[offset] > blankThreshold
                    || pixelData[offset + 1] > blankThreshold
                    || pixelData[offset + 2] > blankThreshold {
                    return true
                }
                x += scanStep
            }
            return false
        }

        // Scan right edge inward in scanStep increments, then refine.
        var rightEdge = width - 1
        while rightEdge > width / 2 && !columnHasContent(rightEdge) {
            rightEdge -= scanStep
        }
        // Refine: walk back forward one step until we find the actual edge.
        while rightEdge < width - 1 && columnHasContent(rightEdge + 1) {
            rightEdge += 1
        }

        var bottomEdge = height - 1
        while bottomEdge > height / 2 && !rowHasContent(bottomEdge) {
            bottomEdge -= scanStep
        }
        while bottomEdge < height - 1 && rowHasContent(bottomEdge + 1) {
            bottomEdge += 1
        }

        // v15p3ci (2026-05-13): also scan left + top edges. SCStream
        // can pad the content with blank space on any side depending
        // on how it fits the source frame into the configured output
        // dimensions. Missing top padding caused the cursor marker to
        // land above the user's actual target by N pixels (where N
        // is the top padding height).
        var leftEdge = 0
        while leftEdge < width / 2 && !columnHasContent(leftEdge) {
            leftEdge += scanStep
        }
        while leftEdge > 0 && columnHasContent(leftEdge - 1) {
            leftEdge -= 1
        }

        var topEdge = 0
        while topEdge < height / 2 && !rowHasContent(topEdge) {
            topEdge += scanStep
        }
        while topEdge > 0 && rowHasContent(topEdge - 1) {
            topEdge -= 1
        }

        return CGRect(
            x: leftEdge,
            y: topEdge,
            width: rightEdge - leftEdge + 1,
            height: bottomEdge - topEdge + 1
        )
    }
}
