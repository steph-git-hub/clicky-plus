//
//  CompanionScreenshotAnnotator.swift
//  leanring-buddy
//
//  Visual annotations that get composited onto a CompanionScreenCapture
//  before it's sent to Claude. Today the only annotation is a bright
//  green bounding box drawn around the currently-focused UI element,
//  so Claude's vision model knows where the text will land.
//
//  Why draw it instead of just describing it in text? Vision models
//  anchor strongly on visually salient cues. "The user is focused on
//  the Slack composer" is useful context; a green box around the
//  composer is better context. The two stack.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum CompanionScreenshotAnnotator {

    /// Stroke color for focus-field bounding boxes. Matches the
    /// typing-mode cursor tint (`overlayCursorGreen`) so the visual
    /// language is consistent — green = typing mode.
    private static let boundingBoxStrokeColor = CGColor(
        red: 0x2F / 255.0,
        green: 0xD6 / 255.0,
        blue: 0x7B / 255.0,
        alpha: 1.0
    )

    /// v15p3ca (2026-05-13): cursor marker for Marin vision pre-annotation.
    /// Magenta (Marin's tint) so the visual language matches her cursor
    /// indicator. White outline so the marker is legible against any
    /// background — magenta blends into pink/red UI elements, so the
    /// halo of white provides guaranteed contrast.
    private static let cursorMarkerFillColor = CGColor(
        red: 0xE0 / 255.0,
        green: 0x3D / 255.0,
        blue: 0xB0 / 255.0,
        alpha: 1.0
    )
    private static let cursorMarkerOutlineColor = CGColor(
        red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0
    )

    /// v15p3cc (2026-05-13): marker geometry redesigned to a HOLLOW
    /// reticle so it doesn't cover content underneath. Previous filled
    /// design (v15p3ca/cb) obscured small text the user was pointing
    /// at — fatal flaw when the whole purpose is to mark where Marin
    /// should READ. New design:
    ///   - Outer white halo (8px stroke at radius ~26px) for contrast
    ///   - Magenta ring (6px stroke at radius ~22px) for visibility
    ///   - Tiny magenta dot (3px radius) at exact center for precision
    /// The middle of the indicator stays empty so the content the user
    /// is pointing at remains fully visible to Marin.
    private static let cursorMarkerRingRadiusPixels: CGFloat = 22
    private static let cursorMarkerRingStrokePixels: CGFloat = 6
    private static let cursorMarkerOutlineRadiusPixels: CGFloat = 26
    private static let cursorMarkerOutlineStrokePixels: CGFloat = 8
    private static let cursorMarkerCenterDotRadiusPixels: CGFloat = 3

    /// Line width is thick on purpose. Retina screenshots are huge
    /// (sometimes 5000+ pixels wide), so a thin stroke would be
    /// invisible after the image is downscaled for the model.
    private static let boundingBoxLineWidthPixels: CGFloat = 10.0

    /// JPEG quality for the re-encoded image. 0.85 matches what the
    /// rest of the pipeline uses — lossy enough to keep payloads
    /// manageable, sharp enough the box stays crisp.
    private static let reencodeQuality: CGFloat = 0.85

    /// Draw a green bounding box on `capture` at the pixel region that
    /// corresponds to `axFrame` (a rect in AX coordinate space:
    /// top-left origin, y-down, points, anchored to the primary
    /// display's top-left). Returns a new CompanionScreenCapture with
    /// the annotated image. Returns the original capture unchanged
    /// if the frame doesn't fall inside this display, the coordinate
    /// conversion fails, or the re-encode fails — better to send an
    /// un-annotated screenshot than to fail the whole typing action.
    static func addFocusBoundingBox(
        to capture: CompanionScreenCapture,
        axFrame: CGRect
    ) -> CompanionScreenCapture {
        // Step 1: convert AX rect → pixel rect inside this capture.
        guard let pixelRect = convertAXFrameToPixelRect(
            axFrame: axFrame,
            capture: capture
        ) else {
            return capture
        }

        // Step 2: sanity-check the rect is inside the image. AX
        // sometimes reports stale frames during animations.
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: capture.screenshotWidthInPixels,
            height: capture.screenshotHeightInPixels
        )
        guard imageBounds.intersects(pixelRect) else {
            return capture
        }

        // Step 3: decode original JPEG → CGImage.
        guard let source = CGImageSourceCreateWithData(capture.imageData as CFData, nil),
              let originalImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return capture
        }

        // Step 4: redraw into a new bitmap context with the box on top.
        guard let annotatedImage = drawBoundingBox(
            onto: originalImage,
            pixelRect: pixelRect
        ) else {
            return capture
        }

        // Step 5: re-encode to JPEG so the payload stays small.
        guard let annotatedData = encodeJPEG(image: annotatedImage) else {
            return capture
        }

        return CompanionScreenCapture(
            imageData: annotatedData,
            label: capture.label,
            isCursorScreen: capture.isCursorScreen,
            displayWidthInPoints: capture.displayWidthInPoints,
            displayHeightInPoints: capture.displayHeightInPoints,
            displayFrame: capture.displayFrame,
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels,
            cursorPositionInImagePixels: capture.cursorPositionInImagePixels,
            // v15p3cp (2026-05-13): forward the freshly-annotated bitmap
            // so downstream consumers (OCR pass) still see consistent
            // pixels even after re-encode. If the encode path didn't
            // hand back a CGImage we just nil it out — OCR will fall
            // back to decoding `imageData`.
            cgImage: annotatedImage
        )
    }

    /// v15p3ca (2026-05-13): draw a magenta cursor marker on `capture`
    /// at the cursor position captured alongside the image. Used by
    /// Marin's vision path so the model knows exactly where the user
    /// is pointing. Returns the original capture unchanged if no
    /// cursor position is available (cursor was off the captured
    /// region) or if any drawing step fails — same fail-safe pattern
    /// as the bounding-box function.
    static func addCursorMarker(to capture: CompanionScreenCapture) -> CompanionScreenCapture {
        guard let cursorPixel = capture.cursorPositionInImagePixels else {
            return capture
        }

        // Sanity-check the point is inside the image bounds. Edge
        // cases: cursor right at the image edge, sub-pixel rounding.
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: capture.screenshotWidthInPixels,
            height: capture.screenshotHeightInPixels
        )
        guard imageBounds.contains(cursorPixel) else {
            return capture
        }

        // Decode → draw → re-encode (same flow as the bounding-box path).
        guard let source = CGImageSourceCreateWithData(capture.imageData as CFData, nil),
              let originalImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return capture
        }
        guard let annotatedImage = drawCursorMarker(
            onto: originalImage,
            pixelPoint: cursorPixel
        ) else {
            return capture
        }
        guard let annotatedData = encodeJPEG(image: annotatedImage) else {
            return capture
        }

        return CompanionScreenCapture(
            imageData: annotatedData,
            label: capture.label,
            isCursorScreen: capture.isCursorScreen,
            displayWidthInPoints: capture.displayWidthInPoints,
            displayHeightInPoints: capture.displayHeightInPoints,
            displayFrame: capture.displayFrame,
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels,
            cursorPositionInImagePixels: capture.cursorPositionInImagePixels,
            // v15p3cp (2026-05-13): forward the freshly-annotated bitmap
            // so downstream consumers (OCR pass) still see consistent
            // pixels even after re-encode. If the encode path didn't
            // hand back a CGImage we just nil it out — OCR will fall
            // back to decoding `imageData`.
            cgImage: annotatedImage
        )
    }

    /// v15p3cc (2026-05-13): hollow reticle marker — outer white halo
    /// + magenta ring + tiny magenta center dot. Middle of the indicator
    /// stays transparent so content the user is pointing at remains
    /// fully visible to Marin's vision pass.
    private static func drawCursorMarker(
        onto originalImage: CGImage,
        pixelPoint: CGPoint
    ) -> CGImage? {
        let width = originalImage.width
        let height = originalImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw the original image first.
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip y for our point: pixelPoint is top-left origin, but the
        // CGContext draws in bottom-left origin.
        let flippedY = CGFloat(height) - pixelPoint.y

        // Layer 1: outer white halo (drawn first, biggest). Provides
        // contrast against any background color the content has.
        let outlineRect = CGRect(
            x: pixelPoint.x - cursorMarkerOutlineRadiusPixels,
            y: flippedY - cursorMarkerOutlineRadiusPixels,
            width: cursorMarkerOutlineRadiusPixels * 2,
            height: cursorMarkerOutlineRadiusPixels * 2
        )
        context.setStrokeColor(cursorMarkerOutlineColor)
        context.setLineWidth(cursorMarkerOutlineStrokePixels)
        context.strokeEllipse(in: outlineRect)

        // Layer 2: magenta ring (drawn over the halo). Primary visible
        // signal of the cursor location.
        let ringRect = CGRect(
            x: pixelPoint.x - cursorMarkerRingRadiusPixels,
            y: flippedY - cursorMarkerRingRadiusPixels,
            width: cursorMarkerRingRadiusPixels * 2,
            height: cursorMarkerRingRadiusPixels * 2
        )
        context.setStrokeColor(cursorMarkerFillColor)
        context.setLineWidth(cursorMarkerRingStrokePixels)
        context.strokeEllipse(in: ringRect)

        // Layer 3: tiny magenta center dot for sub-ring precision. Tells
        // Marin exactly which pixel the user is on, while leaving the
        // text/content immediately around the cursor visible through
        // the ring's empty middle.
        let centerDotRect = CGRect(
            x: pixelPoint.x - cursorMarkerCenterDotRadiusPixels,
            y: flippedY - cursorMarkerCenterDotRadiusPixels,
            width: cursorMarkerCenterDotRadiusPixels * 2,
            height: cursorMarkerCenterDotRadiusPixels * 2
        )
        context.setFillColor(cursorMarkerFillColor)
        context.fillEllipse(in: centerDotRect)

        return context.makeImage()
    }

    // MARK: - Coordinate conversion

    /// Convert an AX rect (top-left origin, y-down, points, anchored
    /// to the primary display's top-left) into a pixel rect inside
    /// `capture` (top-left origin, y-down, pixels, local to that
    /// display's captured image).
    ///
    /// Returns nil if the primary display can't be identified or
    /// the resulting rect is entirely outside this capture.
    ///
    /// Coordinate-system note — there are three spaces involved:
    ///   1. AX/CG: top-left origin, y-down, points, global to primary.
    ///      This is what kAXPositionAttribute returns.
    ///   2. AppKit: bottom-left origin, y-up, points, global to primary.
    ///      This is what NSScreen.frame uses — including
    ///      `capture.displayFrame`, which was stored from an NSScreen.
    ///   3. Screenshot pixels: top-left origin, y-down, pixels, local
    ///      to this single display.
    /// We stay entirely in space 1 for the display-containment math
    /// (so there's no y-flip bug to worry about), then do a single
    /// scale to space 3.
    private static func convertAXFrameToPixelRect(
        axFrame: CGRect,
        capture: CompanionScreenCapture
    ) -> CGRect? {
        // Find the primary display — the one anchored at AppKit (0,0).
        // Fall back to NSScreen.screens.first if we can't find it.
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let primaryHeight = primaryScreen?.frame.height else {
            return nil
        }

        // Convert this capture's displayFrame (AppKit/bottom-left) to
        // its CG/AX origin (top-left of the display in primary-anchored
        // CG space).
        let displayCGOriginX = capture.displayFrame.origin.x
        let displayCGOriginY = primaryHeight
            - capture.displayFrame.origin.y
            - capture.displayFrame.height

        // Translate the AX rect into display-local points
        // (still top-left origin, y-down).
        let localPointX = axFrame.origin.x - displayCGOriginX
        let localPointY = axFrame.origin.y - displayCGOriginY

        // Scale points → pixels using the stored point/pixel sizes.
        // Guard against divide-by-zero just in case.
        guard capture.displayWidthInPoints > 0,
              capture.displayHeightInPoints > 0 else {
            return nil
        }
        let scaleX = CGFloat(capture.screenshotWidthInPixels) / CGFloat(capture.displayWidthInPoints)
        let scaleY = CGFloat(capture.screenshotHeightInPixels) / CGFloat(capture.displayHeightInPoints)

        return CGRect(
            x: localPointX * scaleX,
            y: localPointY * scaleY,
            width: axFrame.width * scaleX,
            height: axFrame.height * scaleY
        )
    }

    // MARK: - Drawing

    /// Draw the original image into a fresh bitmap context and stroke
    /// a green rectangle on top. Returns the composited CGImage.
    ///
    /// Note the y-flip: our `pixelRect` is in screenshot pixel coords
    /// (top-left origin, y-down), but CGContext draws in bottom-left
    /// origin, y-up. We flip the context once at the start so the
    /// rest of the drawing code can stay in natural top-left coords.
    private static func drawBoundingBox(
        onto originalImage: CGImage,
        pixelRect: CGRect
    ) -> CGImage? {
        let width = originalImage.width
        let height = originalImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw the original. CGContext is bottom-left origin, but
        // .draw(_:in:) handles the image orientation correctly — the
        // resulting pixels match the input image exactly.
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip y for our rect: our pixelRect is top-left origin, but
        // the context's stroke uses bottom-left origin.
        let flippedY = CGFloat(height) - pixelRect.origin.y - pixelRect.height
        let drawRect = CGRect(
            x: pixelRect.origin.x,
            y: flippedY,
            width: pixelRect.width,
            height: pixelRect.height
        )

        context.setStrokeColor(boundingBoxStrokeColor)
        context.setLineWidth(boundingBoxLineWidthPixels)
        context.setLineJoin(.round)
        context.stroke(drawRect)

        return context.makeImage()
    }

    // MARK: - JPEG encoding

    /// Re-encode a CGImage as JPEG data.
    private static func encodeJPEG(image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: reencodeQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
}
