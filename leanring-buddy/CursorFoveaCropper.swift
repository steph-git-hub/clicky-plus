//
//  CursorFoveaCropper.swift
//  leanring-buddy
//
//  v15p3cq (2026-05-13): build a tight crop centered on the cursor
//  position, sent to Marin as a SECOND image alongside the full
//  screenshot.
//
//  Why this exists:
//
//  Modern multimodal models (GPT-4o / 4.1 / o-series, Claude 3.5+,
//  Gemini 2.0) lose grounding accuracy on tiny targets inside large
//  images — they have to allocate their limited visual attention
//  across the whole frame and small text or buttons get glossed over.
//  Research on visual grounding (Set-of-Mark, ScreenSpot-Pro) and
//  the Cluely / Cap / Granola family of products converged on the
//  "fovea trick": give the model the full image for context, and a
//  separate magnified tile centered on the region of interest. The
//  model then has high-detail pixels of exactly what the user is
//  pointing at, with no marker-alignment math or AX tree wrangling.
//
//  How it solves problems we previously fought:
//
//   - Display scaling on Sceptre and other external monitors: gone.
//     Marin sees raw pixel content around the cursor at native res,
//     not a re-sampled fraction of a 1920-wide capture.
//
//   - Cursor marker drift across versions cb-cl: gone. There IS no
//     marker — the cursor itself is the center of the crop, so
//     wherever it actually rendered, that's the middle of the tile.
//
//   - Chromium "scrollarea" AX failure: irrelevant. We're not asking
//     any accessibility API a question — we're showing Marin the
//     pixels and letting her vision encoder do the work.
//
//   - OCR proximity errors (30-50px off on small text): gone. No
//     nearest-text math; the model reads whatever text is in the
//     crop directly.
//
//  This is purely additive — the existing AX hint, OCR hint, and
//  cursor-pixel-coords text fields all stay in the prompt, providing
//  defense-in-depth. If the fovea crop is missing (cursor off-screen,
//  encode failed), Marin still has everything she had before.
//

import AppKit
import CoreGraphics
import Foundation

/// Result of cropping a fovea tile from a larger screenshot. JPEG
/// payload + the cursor position EXPRESSED IN CROP-LOCAL coords (so
/// Marin can also be told where the cursor is within the tile, in case
/// it shifted off-center due to edge clamping).
struct CursorFoveaCrop {
    /// The JPEG-encoded crop, ready to send as input_image.
    let jpegData: Data
    /// The crop's width in pixels (matches the source CGImage subregion
    /// — no upscaling applied here; we let the model's vision encoder
    /// handle resampling on its end).
    let widthInPixels: Int
    /// The crop's height in pixels.
    let heightInPixels: Int
    /// Cursor position in CROP-LOCAL pixel coordinates (top-left origin).
    /// Useful for a one-line "cursor at (X, Y) in this crop" hint sent
    /// alongside. If the cursor was clamped from the original position
    /// to keep the crop in-bounds, this shows the actual offset within
    /// the resulting tile.
    let cursorInCropPixels: CGPoint
}

enum CursorFoveaCropper {

    /// Build a square crop centered on the cursor's pixel position.
    /// Returns nil if the cursor position is missing, the requested
    /// radius exceeds the image dimensions, or any step fails.
    ///
    /// - Parameters:
    ///   - sourceImage: The full-resolution CGImage we just captured.
    ///     Required (no fallback to JPEG decode — call sites with
    ///     only Data should expose the CGImage first; the price of
    ///     decoding here would defeat the whole point of preserving
    ///     pixel fidelity).
    ///   - cursorInImagePixels: Cursor position in image-pixel coords
    ///     (top-left origin), matching the value computed in
    ///     CompanionScreenCaptureUtility.
    ///   - radiusInPixels: Half the crop side length. v15p3cr default
    ///     256 → a 512×512 tile, which matches OpenAI's vision encoder
    ///     tile size — bigger crops just get downsampled on their end,
    ///     so we save upload bytes by sending the native size. Small
    ///     enough that the cursor target is visually prominent, large
    ///     enough to include surrounding text/UI for disambiguation.
    ///   - jpegQuality: Encoding quality 0.0–1.0. v15p3cr dropped to
    ///     0.85 — at a 512×512 tile the visual difference vs 0.92 is
    ///     invisible to the vision encoder but the file is ~25% smaller.
    /// - Returns: Crop + cursor-in-crop position, or nil on failure.
    static func cropAroundCursor(
        sourceImage: CGImage,
        cursorInImagePixels: CGPoint?,
        radiusInPixels: Int = 256,
        jpegQuality: CGFloat = 0.85
    ) -> CursorFoveaCrop? {
        // Without a cursor position there's nothing to center on.
        guard let cursor = cursorInImagePixels else { return nil }

        let imgW = sourceImage.width
        let imgH = sourceImage.height
        // The desired crop side length. Diameter, not radius.
        let side = radiusInPixels * 2
        // If the image is smaller than the requested crop on either
        // axis we can't crop at all — sending the full image (already
        // being sent as the context tile) would be redundant.
        guard imgW >= side, imgH >= side else { return nil }

        // Compute the crop origin so the cursor lands at the center.
        // Cursor is in image-pixel TOP-LEFT coords, matching CGImage's
        // native bitmap orientation, so we don't need to y-flip.
        let cx = Int(cursor.x.rounded())
        let cy = Int(cursor.y.rounded())
        var originX = cx - radiusInPixels
        var originY = cy - radiusInPixels
        // Clamp so the crop rect stays inside the image — when the
        // cursor is near an edge we shift the crop, preferring to keep
        // a full-size tile rather than letting it shrink. The cursor
        // then sits off-center inside the resulting crop, which we
        // surface via `cursorInCropPixels` so the prompt can mention it.
        originX = max(0, min(originX, imgW - side))
        originY = max(0, min(originY, imgH - side))

        // Compute where the cursor actually lands inside the crop.
        let cursorInCrop = CGPoint(x: cx - originX, y: cy - originY)

        let cropRect = CGRect(x: originX, y: originY, width: side, height: side)
        guard let cropped = sourceImage.cropping(to: cropRect) else { return nil }

        // Encode to JPEG. NSBitmapImageRep is the standard path on
        // macOS — same one used by the main capture utility.
        guard let jpegData = NSBitmapImageRep(cgImage: cropped)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: jpegQuality]) else {
            return nil
        }

        return CursorFoveaCrop(
            jpegData: jpegData,
            widthInPixels: cropped.width,
            heightInPixels: cropped.height,
            cursorInCropPixels: cursorInCrop
        )
    }
}
