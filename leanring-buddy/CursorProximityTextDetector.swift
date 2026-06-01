//
//  CursorProximityTextDetector.swift
//  leanring-buddy
//
//  v15p3co (2026-05-13): universal "what is the cursor over?" detector
//  using Apple's Vision framework. Runs OCR on the screenshot we're
//  about to send to Marin, then returns the text observation closest
//  to the cursor's pixel position.
//
//  Why this exists:
//
//  v15p3cn shipped AX-based hover detection (AXUIElementCopyElementAt
//  Position). That works brilliantly on native AppKit apps but fails on
//  Chrome because Chromium hides its DOM tree behind a single generic
//  "scrollarea" AX node. Steph explicitly rejected platform-specific
//  bridges (AppleScript + JS, Chrome DevTools Protocol, etc.) — he
//  wants a universal answer that doesn't need per-app setup.
//
//  OCR-on-the-screenshot is the universal answer: we already have a
//  picture of whatever is visible. Run text recognition on that picture,
//  find the text observation nearest the cursor, and tell Marin "user
//  is hovering near text 'Five owls swooped silently'." This works on
//  ANY app — Chrome, Safari, the Sceptre external display, native AX-
//  opaque apps, virtualized windows, full-screen games with text,
//  PDFs viewed in Preview — anywhere pixels are visible.
//
//  Composes with AX: callers ask AX first (fast, semantic), and fall
//  through to OCR when AX returns a low-info element. OCR adds ~80–
//  200ms on Apple Silicon for a 1920×1080 frame; acceptable for vision
//  turns that already include a multi-second LLM call.
//

import AppKit
import Foundation
import Vision

/// Result of an OCR-based proximity lookup. All fields nil/empty means
/// either there was no text on screen, or OCR failed (which we still
/// want to return gracefully so the caller can fall back).
struct CursorProximityTextResult {
    /// The text Vision recognized closest to the cursor. Trimmed of
    /// surrounding whitespace. Empty if no text observation was found.
    let nearestText: String
    /// Distance from cursor to the nearest text observation's bounding
    /// box, in image pixels. `0` if the cursor is inside the box.
    /// `.infinity` if no observations were available.
    let distanceInPixels: CGFloat
    /// True iff the cursor pixel was inside the bounding box of the
    /// returned text. Useful for caller heuristics ("over text" vs
    /// "near text").
    let cursorIsInsideTextBox: Bool
    /// Vision's confidence on the returned text observation (0–1).
    let confidence: Float
}

enum CursorProximityTextDetector {

    /// Run OCR on an image (CGImage preferred; JPEG fallback) and find
    /// the text observation closest to the cursor's pixel position.
    /// Returns nil if the image can't be decoded or Vision throws —
    /// caller should treat that as "no OCR hint available" and proceed
    /// with whatever fallback context they have.
    ///
    /// - Parameters:
    ///   - cgImage: The pre-encoded screenshot bitmap. PREFERRED over
    ///     `imageData` because it skips a lossy JPEG decode round-trip
    ///     (cleaner pixels → tighter Vision boxes + fewer mis-reads).
    ///     If nil, falls back to decoding from `imageData`.
    ///   - imageData: JPEG bytes used as a decode fallback when
    ///     `cgImage` is nil. Same JPEG we're sending to Marin.
    ///   - cursorInImagePixels: Cursor position in image-pixel coords
    ///     (TOP-LEFT origin, matching CompanionScreenCapture's
    ///     cursorPositionInImagePixels field). nil → can't compute
    ///     proximity, return nil.
    ///   - imageWidthInPixels: Width of the source image, used to
    ///     convert Vision's normalized boxes back to pixel space.
    ///   - imageHeightInPixels: Same for height.
    ///   - recognitionLevel: `.fast` (~50–80ms, lower accuracy) or
    ///     `.accurate` (~200–400ms, higher accuracy). Default `.accurate`
    ///     because Marin's vision turn is already gated by the LLM
    ///     round-trip — an extra 200ms is invisible vs. wrong text.
    /// - Returns: Best result + distance, or nil on hard failure.
    static func findNearestText(
        cgImage: CGImage?,
        imageData: Data?,
        cursorInImagePixels: CGPoint?,
        imageWidthInPixels: Int,
        imageHeightInPixels: Int,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) -> CursorProximityTextResult? {
        // Without a cursor position there's nothing to find proximity
        // TO — the caller should have skipped this call entirely, but
        // we guard defensively rather than crash on a force-unwrap.
        guard let cursor = cursorInImagePixels else { return nil }
        // Need positive image dimensions to normalize coords. A 0×0
        // capture would crash the division below.
        guard imageWidthInPixels > 0, imageHeightInPixels > 0 else { return nil }

        // Prefer the pre-encoded CGImage so Vision sees clean pixels;
        // fall back to decoding the JPEG if no CGImage was supplied.
        // JPEG at q=0.92 is high-quality but introduces soft-edge
        // artifacts that bite Vision's character recognition on small
        // text (e.g., "Properess" instead of "Progress" — the rounded
        // 'g' gets softened until it reads as 'e' + 'r').
        let imageForVision: CGImage
        if let cgImage {
            imageForVision = cgImage
        } else if let imageData,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            imageForVision = decoded
        } else {
            return nil
        }

        // Build the OCR request. v15p3cp (2026-05-13): flipped
        // `usesLanguageCorrection` ON. The original "off" was a hedge
        // against dictionary-shaped fix-ups stomping partial words and
        // code identifiers, but the empirical result was the opposite —
        // small UI text was getting mis-recognized as gibberish that
        // a dictionary pass would have rescued ("Properess" → "Progress",
        // "algac" → "algae", "Discarn,Changes" → "Discard Changes",
        // "soutnward" → "southward"). For hover hints on screen-pixels
        // we want the corrected version every time.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true

        // Vision's bounding boxes are in NORMALIZED coordinates with a
        // BOTTOM-LEFT origin. Our cursor pixel is TOP-LEFT origin. To
        // compare, we normalize the cursor to Vision's space here.
        let imgW = CGFloat(imageWidthInPixels)
        let imgH = CGFloat(imageHeightInPixels)
        let cursorNormX = max(0, min(1, cursor.x / imgW))
        // y-flip: image-top-y=0 ↔ vision-bottom-y=1.
        let cursorNormY = max(0, min(1, 1 - (cursor.y / imgH)))

        // Synchronous perform — we're already on a background Task at
        // the call site, so blocking here is fine and saves the
        // ceremony of an async wrapper. Errors collapse to nil so the
        // caller can fall back without special-casing.
        let handler = VNImageRequestHandler(cgImage: imageForVision, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else {
            // No text on screen (or Vision found none). Return nil
            // rather than an empty hit so the caller knows OCR ran
            // but had nothing useful to contribute.
            return nil
        }

        // Find the observation whose bounding box is nearest the
        // cursor. If the cursor is INSIDE a box, distance is 0 — and
        // among multiple containing boxes we prefer the smallest
        // (deepest, most specific) one, mimicking how AX's leaf-node
        // lookup behaves.
        var bestResult: (observation: VNRecognizedTextObservation,
                         distance: CGFloat,
                         insideBox: Bool,
                         boxArea: CGFloat)?

        for observation in observations {
            let box = observation.boundingBox  // normalized, bottom-left
            let containsCursor = box.contains(CGPoint(x: cursorNormX, y: cursorNormY))
            // Distance to box: 0 if inside, else euclidean distance to
            // the nearest edge of the box (in normalized space, then
            // scaled to pixels for an intuitive unit on the way out).
            let dxNorm: CGFloat = {
                if cursorNormX < box.minX { return box.minX - cursorNormX }
                if cursorNormX > box.maxX { return cursorNormX - box.maxX }
                return 0
            }()
            let dyNorm: CGFloat = {
                if cursorNormY < box.minY { return box.minY - cursorNormY }
                if cursorNormY > box.maxY { return cursorNormY - box.maxY }
                return 0
            }()
            // Mixed-axis distance: convert each axis back to pixels so
            // a screenshot's actual aspect ratio is respected (a thin
            // wide box shouldn't look 'closer' than a tall narrow one
            // just because of normalization warping).
            let dxPx = dxNorm * imgW
            let dyPx = dyNorm * imgH
            let distancePx = sqrt(dxPx * dxPx + dyPx * dyPx)
            let area = box.width * box.height

            if let current = bestResult {
                if containsCursor && !current.insideBox {
                    // First "inside" win beats any prior "outside" hit.
                    bestResult = (observation, distancePx, true, area)
                } else if containsCursor && current.insideBox {
                    // Both inside — prefer the smaller (more specific) box.
                    if area < current.boxArea {
                        bestResult = (observation, distancePx, true, area)
                    }
                } else if !current.insideBox {
                    // Both outside — closer wins.
                    if distancePx < current.distance {
                        bestResult = (observation, distancePx, false, area)
                    }
                }
                // (current inside, candidate outside) → keep current.
            } else {
                bestResult = (observation, distancePx, containsCursor, area)
            }
        }

        guard let winner = bestResult else { return nil }

        // Pull the top candidate text from the winning observation.
        // VNRecognizedTextObservation.topCandidates(_:) gives us the
        // highest-confidence string; we ask for one because we don't
        // care about runner-up alternatives.
        let candidates = winner.observation.topCandidates(1)
        guard let top = candidates.first else { return nil }

        let cleanedText = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }

        return CursorProximityTextResult(
            nearestText: cleanedText,
            distanceInPixels: winner.distance,
            cursorIsInsideTextBox: winner.insideBox,
            confidence: top.confidence
        )
    }

    /// Human-readable hover hint for Marin's prompt, built from an OCR
    /// result. Examples:
    ///
    ///   "Hovering directly over text: 'Five owls swooped silently'"
    ///   "Hovering near text (12 px away): 'Quantum mechanics predicts'"
    ///
    /// Returns nil if the OCR result is missing or empty so the caller
    /// can fall through to other hint sources without nil-guarding the
    /// individual fields.
    static func describeForHoverHint(_ result: CursorProximityTextResult?) -> String? {
        guard let result, !result.nearestText.isEmpty else { return nil }
        // Cap the snippet so a stray paragraph-long OCR hit doesn't
        // anchor Marin's attention on the wrong region. v15p3cp tightened
        // 120 → 80 chars so even when Vision returns a whole sentence,
        // the hint focuses on the part closest to the cursor.
        let snippet: String = {
            if result.nearestText.count > 80 {
                return String(result.nearestText.prefix(80)) + "…"
            }
            return result.nearestText
        }()

        if result.cursorIsInsideTextBox {
            return "Hovering directly over text: '\(snippet)'"
        }
        // Round distance to a whole pixel — sub-pixel precision is
        // noise for an LLM hint.
        let distancePx = Int(result.distanceInPixels.rounded())
        return "Hovering near text (\(distancePx) px away): '\(snippet)'"
    }
}
