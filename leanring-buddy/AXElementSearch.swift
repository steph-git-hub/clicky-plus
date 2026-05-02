//
//  AXElementSearch.swift
//  leanring-buddy / Clicky+
//
//  Created 2026-05-02 (v15p2 Chunk 2). Searches the macOS Accessibility
//  tree of the currently-focused application for UI elements matching
//  a natural-language description. Used by the Realtime mode's
//  `highlight_element` tool so Marin can point at things like
//  "the upload button in the top-left" while walking Steph through
//  unfamiliar apps.
//
//  Match strategy:
//    • Walk the AX tree of the frontmost app (BFS, capped depth)
//    • For each element, build a "search blob" from its title, label,
//      description, role, role description, and value
//    • Score each blob against the search description using a simple
//      keyword + substring match (case-insensitive)
//    • Return the highest-scoring element with a non-zero score, plus
//      its frame in AppKit screen coordinates
//
//  This is READ-ONLY AX — same permission Clicky already requests.
//  No event synthesis, no state mutation.
//
//  Failure modes are silent + non-fatal: if AX denies access, the app
//  has a sparse tree (some Electron apps), or no element scores well,
//  we return nil. The Realtime tool dispatcher then reports back to
//  Marin "I couldn't find that element on screen" so she can ask the
//  user to clarify rather than highlighting the wrong thing.
//

import AppKit
import ApplicationServices
import Foundation

/// Result of a successful element search.
struct AXSearchHit {
    /// The element frame in AppKit screen coordinates (bottom-left
    /// origin, full multi-display arrangement). This is what
    /// RealtimeHighlightOverlayManager.show() expects.
    let screenRect: CGRect
    /// What the matched element was (title/label/role) — useful for
    /// debugging + for the tool's response back to Marin.
    let matchedDescription: String
    /// Score from the matcher (higher = better match). Useful for
    /// thresholding "good enough" hits in the dispatcher.
    let score: Int
}

@MainActor
enum AXElementSearch {

    /// Search the focused app's AX tree for an element matching the
    /// given description. Returns the best hit, or nil if nothing
    /// scored above the minimum threshold.
    ///
    /// - Parameters:
    ///   - description: natural-language target ("the upload button",
    ///     "Add Source", "search bar in the top-left")
    ///   - maxDepth: how deep to walk the tree. 8 covers most apps;
    ///     deeper means longer searches but more thorough.
    static func find(
        description: String,
        maxDepth: Int = 8
    ) -> AXSearchHit? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        let queryTokens = tokenize(description)
        guard !queryTokens.isEmpty else { return nil }

        // Compute the union of all screens once so we can sanity-check
        // converted rects (a hit whose rect lies entirely off-screen
        // means our coord math or AX data is bad — better to return
        // not_found than draw a highlight nobody can see).
        let screenUnion = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }

        // BFS through the AX tree. We score every visited element and
        // track the best scorer. Capped at depth + total node count
        // to avoid runaway searches in deep trees.
        var bestHit: AXSearchHit?
        var bestEffectiveScore = 2 // min threshold — below = too noisy
        var nodesVisited = 0
        let nodeBudget = 800

        var queue: [(element: AXUIElement, depth: Int)] = [(appElement, 0)]
        while !queue.isEmpty, nodesVisited < nodeBudget {
            let (element, depth) = queue.removeFirst()
            nodesVisited += 1

            let blob = buildSearchBlob(element)
            let rawScore = scoreMatch(queryTokens: queryTokens, blob: blob)

            // Hotfix v15p2 (2026-05-02): bias toward deeper, smaller
            // elements when scores are close. The previous matcher
            // happily picked top-level Window items because their
            // titles included every keyword in the query; that's
            // technically correct but useless for "highlight the
            // upload button." Here we add a depth bonus and a
            // size penalty so a 100×30 button beats a 1700×1300 window.
            if rawScore > 2, let frame = copyAXFrame(element) {
                let convertedRect = axFrameToScreenRect(frame)

                // Sanity: must intersect at least one screen.
                guard screenUnion.intersects(convertedRect) else {
                    // Rect is off-screen — likely bad AX data. Skip.
                    if depth < maxDepth, let children = copyAXChildren(element) {
                        for child in children { queue.append((child, depth + 1)) }
                    }
                    continue
                }

                // Granularity bonus: deeper elements score higher.
                // v15p2 hotfix3 (2026-05-02): capped at +3 (was +6).
                // The previous +6 was inflating false positives —
                // a deeply-nested "New Tab" would beat the threshold
                // off one keyword match. Lower cap forces multi-
                // token matches to do the heavy lifting.
                let depthBonus = min(depth, 3)

                // Size penalty: huge elements (whole windows) lose
                // points. We score them by how much of the smallest-
                // dimension screen the rect occupies. >50% of either
                // axis = -3. >80% = -6.
                let smallestScreen = NSScreen.screens.min(by: { $0.frame.area < $1.frame.area })?.frame ?? .zero
                let widthRatio = convertedRect.width / max(smallestScreen.width, 1)
                let heightRatio = convertedRect.height / max(smallestScreen.height, 1)
                let bigDimRatio = max(widthRatio, heightRatio)
                let sizePenalty: Int
                switch bigDimRatio {
                case 0..<0.5: sizePenalty = 0
                case 0.5..<0.8: sizePenalty = 3
                default: sizePenalty = 6
                }

                let effectiveScore = rawScore + depthBonus - sizePenalty
                if effectiveScore > bestEffectiveScore {
                    bestHit = AXSearchHit(
                        screenRect: convertedRect,
                        matchedDescription: blob.shortLabel,
                        score: effectiveScore
                    )
                    bestEffectiveScore = effectiveScore
                }
            }

            // Recurse into children.
            if depth < maxDepth, let children = copyAXChildren(element) {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }

        return bestHit
    }

    // MARK: - Search-blob construction

    /// All the text we want to match against for a single element.
    private struct ElementSearchBlob {
        let combinedText: String
        let shortLabel: String // for diagnostic output
    }

    private static func buildSearchBlob(_ element: AXUIElement) -> ElementSearchBlob {
        var fields: [String] = []
        var label: String?
        if let title = copyAXStringAttribute(element, attribute: kAXTitleAttribute), !title.isEmpty {
            fields.append(title)
            if label == nil { label = title }
        }
        if let desc = copyAXStringAttribute(element, attribute: kAXDescriptionAttribute), !desc.isEmpty {
            fields.append(desc)
            if label == nil { label = desc }
        }
        if let placeholder = copyAXStringAttribute(element, attribute: "AXPlaceholderValue"), !placeholder.isEmpty {
            fields.append(placeholder)
        }
        if let value = copyAXStringAttribute(element, attribute: kAXValueAttribute), !value.isEmpty {
            // Cap value strings — long text fields would dominate scoring.
            let capped = value.count > 200 ? String(value.prefix(200)) : value
            fields.append(capped)
        }
        if let roleDesc = copyAXStringAttribute(element, attribute: kAXRoleDescriptionAttribute), !roleDesc.isEmpty {
            fields.append(roleDesc)
        }
        if let role = copyAXStringAttribute(element, attribute: kAXRoleAttribute), !role.isEmpty {
            fields.append(role)
        }
        return ElementSearchBlob(
            combinedText: fields.joined(separator: " "),
            shortLabel: label ?? fields.first ?? "(unlabeled)"
        )
    }

    // MARK: - Matching / scoring

    private static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        // Split on whitespace + common punctuation, drop very short tokens.
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let raw = lowered.components(separatedBy: separators)
        return raw.filter { token in
            // Drop noise words that don't help disambiguate.
            let length = token.count
            guard length >= 2 else { return false }
            return !stopWords.contains(token)
        }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "at", "with",
        "for", "by", "is", "are", "be", "this", "that", "it", "its", "my",
        "your", "click", "tap", "press", "find", "show", "highlight", "point",
        "out", "ui", "element", "button", "icon", "the", "thing",
    ]

    /// Score a blob against the query tokens. Each token that appears
    /// as a substring in the blob earns 1 point; an exact-word match
    /// earns 3 points. Plus a bonus if every query token is found.
    ///
    /// v15p2 hotfix3 (2026-05-02): also enforces a "must match ≥2
    /// tokens" gate. Returns 0 if only one query token matched, no
    /// matter how strong that match is. This kills the "tab" → "New
    /// Tab" false-positive class — a single-keyword match isn't a
    /// reliable indicator that we found the right element.
    private static func scoreMatch(queryTokens: [String], blob: ElementSearchBlob) -> Int {
        let lowerBlob = blob.combinedText.lowercased()
        var score = 0
        var allFound = true
        var matchedTokenCount = 0
        for token in queryTokens {
            if lowerBlob.contains(" \(token) ")
                || lowerBlob.hasPrefix(token + " ")
                || lowerBlob.hasSuffix(" " + token)
                || lowerBlob == token {
                score += 3
                matchedTokenCount += 1
            } else if lowerBlob.contains(token) {
                score += 1
                matchedTokenCount += 1
            } else {
                allFound = false
            }
        }
        if allFound && !queryTokens.isEmpty {
            score += 2 // bonus for "everything in the query was found"
        }
        // Single-keyword match isn't enough confidence — return 0.
        // Caller will fall back to vision instead.
        if queryTokens.count >= 2 && matchedTokenCount < 2 {
            return 0
        }
        return score
    }

    // MARK: - AX coordinate conversion

    /// AX (a.k.a. Quartz/CG) coordinates have origin at the top-left
    /// of the PRIMARY display with y growing downward. AppKit's
    /// NSScreen frames have origin at the bottom-left of the primary
    /// with y growing upward. To convert:
    ///
    ///     appKit.y = primaryScreen.frame.height - ax.maxY
    ///
    /// Critical: this uses `primaryScreen.frame.height` (the screen
    /// containing the menu bar), NOT `unionFrame.maxY`. The previous
    /// version of this function used the union, which broke for
    /// multi-monitor setups where the secondary display sits above
    /// the primary in AppKit space — the off-by-(secondary-height)
    /// error pushed all hits ~1300 px off-screen, which is why no
    /// highlights were visible.
    ///
    /// Reference: Apple TN2024, "Coordinate Systems in macOS."
    private static func axFrameToScreenRect(_ axFrame: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return axFrame
        }
        let appKitY = primaryScreen.frame.height - axFrame.maxY
        return CGRect(
            x: axFrame.origin.x,
            y: appKitY,
            width: axFrame.width,
            height: axFrame.height
        )
    }

    // MARK: - Low-level AX helpers (mirror FocusedElementContextProvider)

    private static func copyAXAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func copyAXStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        return copyAXAttribute(element, attribute: attribute) as? String
    }

    private static func copyAXChildren(_ element: AXUIElement) -> [AXUIElement]? {
        guard let value = copyAXAttribute(element, attribute: kAXChildrenAttribute) else {
            return nil
        }
        guard let array = value as? [AnyObject] else { return nil }
        var elements: [AXUIElement] = []
        for raw in array {
            if CFGetTypeID(raw) == AXUIElementGetTypeID() {
                elements.append(raw as! AXUIElement)
            }
        }
        return elements
    }

    private static func copyAXFrame(_ element: AXUIElement) -> CGRect? {
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
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
