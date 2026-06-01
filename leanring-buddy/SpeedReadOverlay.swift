//
//  SpeedReadOverlay.swift
//  leanring-buddy
//
//  v15p3gu (2026-05-18): tokenize splits long compound tokens at
//  internal punctuation (URLs, file paths, snake_case identifiers) so
//  a 50-char "word" doesn't blink past at 400 WPM. durationForWord
//  now scales with character count so long words stay readable.
//  Added chunked RSVP (1/2/3 words per frame, live-cycle via 1/2/3
//  number keys) so the user can A/B between classic single-word
//  Spritz RSVP and chunked RSVP without leaving the overlay.
//
//  v15p3gt (2026-05-18): NEW. RSVP (Rapid Serial Visual Presentation)
//  overlay invoked by double-tap Shift. Captures selected text (or
//  clipboard fallback), tokenizes, and plays back one word at a time
//  with an ORP-highlighted character at a configurable WPM.
//
//  Goal: counter the "drowning in AI text" problem — read 2-4x faster
//  on dense AI-generated prose (digests, dashboard narratives, model
//  outputs). Optional Haiku pre-compression strips filler before RSVP
//  for an additional speed multiplier (toggled via settings).
//
//  Design:
//    • Black floating NSPanel, centered on the active screen.
//    • Single word centered horizontally with one character highlighted
//      in accent color at the ORP (Optimal Recognition Point).
//    • Progress bar at the bottom showing position in the document.
//    • WPM label + controls.
//    • Keyboard: spacebar pause/resume, ←/→ jump 5 words, ↑/↓ ±25 WPM,
//      Esc close.
//
//  Hidden from screen captures (sharingType = .none) like the rest of
//  Clicky's overlays.
//

import AppKit
import Combine
import SwiftUI

/// NSPanel subclass that can accept key events so spacebar / arrow / Esc
/// keyboard control works without needing focus on a SwiftUI field.
private final class SpeedReadKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// State container the SwiftUI view observes. Lives on the main actor
/// so the timer-driven word advance can update @Published without
/// thread juggling.
@MainActor
final class SpeedReadController: ObservableObject {

    // MARK: - Published state

    @Published var isPlaying: Bool = false
    @Published var currentIndex: Int = 0
    @Published var wpm: Int = 400
    /// True while the optional Haiku pre-compression is in flight, before
    /// the first word renders.
    @Published var isCompressing: Bool = false
    /// v15p4ae (2026-05-24): chunked display + sliding highlight.
    /// A group of N words appears together and STAYS PUT while the
    /// ORP highlight moves through each word in the group at the per-
    /// word duration. After all N have been highlighted, the entire
    /// group swaps to the next N words.
    ///
    /// So the reading speed is identical across modes — every word
    /// gets `durationForWord` of focus regardless of N. The window
    /// size only affects how much trailing context is visible while
    /// you're on a given word.
    ///
    /// Values:
    ///   0 = smart (auto-pick 1-4 based on word lengths per group)
    ///   1-4 = fixed group size
    /// Cycle live with 0/1/2/3/4 keys; persisted via UserDefaults.
    @Published var chunkSize: Int = 1

    /// Current display group's first-word index. Stays put while the
    /// highlight slides through; jumps to currentIndex when the group
    /// has been fully read. v15p4ae.
    @Published private(set) var displayGroupStart: Int = 0

    /// Number of words in the current display group. For smart mode
    /// this is recomputed at each group boundary; for fixed modes it
    /// equals chunkSize. v15p4ae.
    @Published private(set) var displayGroupSize: Int = 1

    // MARK: - Constants & state

    /// All words after tokenization. Set once on engage, never mutated.
    private(set) var words: [String] = []

    /// Pacing multipliers applied to each word's display duration. End-of-
    /// clause punctuation gets longer pauses to give the eye a chance to
    /// settle, mirroring how natural reading rhythms work.
    private let commaMultiplier: Double = 1.3
    private let periodMultiplier: Double = 1.8

    /// Minimum WPM. Below 100 the cadence feels jarring (single word
    /// blinking on/off slowly).
    let minWPM: Int = 100
    let maxWPM: Int = 900
    let wpmStep: Int = 25

    private var advanceTask: Task<Void, Never>?

    // MARK: - Public API

    /// Load a body of text and start RSVP playback. Picks up the most
    /// recently persisted chunkSize so the user's last A/B choice
    /// (1 vs 2 vs 3 words per frame) carries across invocations.
    func load(text: String, startingWPM: Int) {
        stop()
        let tokens = Self.tokenize(text: text)
        self.words = tokens
        self.currentIndex = 0
        self.wpm = max(minWPM, min(maxWPM, startingWPM))
        let storedChunkSize = UserDefaults.standard.object(forKey: "clicky.speedRead.chunkSize") as? Int ?? 1
        self.chunkSize = max(0, min(4, storedChunkSize))
        guard !tokens.isEmpty else { return }
        startNewDisplayGroup(at: 0)
        play()
    }

    /// v15p4ae: chunkSize now means "group size."
    ///   0 = smart (auto 1-4 per group, based on word lengths)
    ///   1-4 = fixed group size
    /// Each individual word in the group is highlighted for its own
    /// per-word duration. The group itself swaps when the highlight
    /// has cycled through all N words.
    func setChunkSize(_ size: Int) {
        let clamped = max(0, min(4, size))
        chunkSize = clamped
        UserDefaults.standard.set(clamped, forKey: "clicky.speedRead.chunkSize")
        // Re-derive the current display group from currentIndex so the
        // change takes effect on the very next render (don't wait for
        // the user to drift into the next group).
        startNewDisplayGroup(at: currentIndex)
    }

    /// Start a new display group beginning at `index`. Computes the
    /// group size from chunkSize (fixed) or word lengths (smart).
    /// v15p4ae (2026-05-24).
    func startNewDisplayGroup(at index: Int) {
        let n = words.count
        guard index < n else {
            displayGroupStart = index
            displayGroupSize = 1
            return
        }
        displayGroupStart = index
        if chunkSize >= 1 {
            displayGroupSize = min(chunkSize, n - index)
        } else {
            // Smart mode: grow group as long as visual budget allows.
            let maxChars = 26
            var size = 1
            var totalChars = words[index].count
            while size < 4 && (index + size) < n {
                let nextLen = words[index + size].count + 1
                if totalChars + nextLen > maxChars { break }
                totalChars += nextLen
                size += 1
            }
            displayGroupSize = size
        }
    }

    /// Index of the highlighted word WITHIN the current display group
    /// (0-based). Used by the view to color exactly one word as the
    /// ORP-anchored focal word while the rest stay dim.
    var highlightIndexInGroup: Int {
        max(0, currentIndex - displayGroupStart)
    }

    /// Begin (or resume) advancing through `words` on the timer.
    func play() {
        guard !words.isEmpty, currentIndex < words.count else { return }
        isPlaying = true
        startAdvanceLoop()
    }

    /// Pause the timer in place; current word stays on screen.
    func pause() {
        isPlaying = false
        advanceTask?.cancel()
        advanceTask = nil
    }

    /// Toggle play/pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            // If we hit the end, restart from beginning.
            if currentIndex >= words.count {
                currentIndex = 0
            }
            play()
        }
    }

    /// Jump backward by N words. Stays paused if currently paused.
    func jumpBack(by count: Int = 5) {
        currentIndex = max(0, currentIndex - count)
        startNewDisplayGroup(at: currentIndex)
    }

    /// Jump forward by N words. Stays paused if currently paused.
    func jumpForward(by count: Int = 5) {
        currentIndex = min(words.count - 1, currentIndex + count)
        startNewDisplayGroup(at: currentIndex)
    }

    /// Adjust WPM by ±wpmStep. Persists to UserDefaults so the next
    /// invocation picks up the same speed.
    func adjustWPM(by delta: Int) {
        let next = max(minWPM, min(maxWPM, wpm + delta))
        wpm = next
        UserDefaults.standard.set(next, forKey: "clicky.speedRead.wpm")
    }

    /// Stop and clear all state. Called when the overlay is dismissed.
    func stop() {
        isPlaying = false
        advanceTask?.cancel()
        advanceTask = nil
        words = []
        currentIndex = 0
        isCompressing = false
    }

    // MARK: - Advance loop

    private func startAdvanceLoop() {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            // v15p4ad (2026-05-24): rolling-window RSVP — always advance
            // ONE word per tick. Window size only affects display, not
            // cadence. So 1-word, 2-word, 3-word, 4-word, and smart all
            // share the same per-word rhythm; the difference is how many
            // words are visible at once (trailing context to the right
            // of the ORP-anchored leading word).
            while let self, await MainActor.run(body: { self.isPlaying }) {
                let (idx, count, ms): (Int, Int, UInt64) = await MainActor.run {
                    let i = self.currentIndex
                    let n = self.words.count
                    let durationMs: UInt64 = i < n ? self.durationForWord(at: i) : 0
                    return (i, n, durationMs)
                }
                guard idx < count, ms > 0 else {
                    await MainActor.run { self.pause() }
                    return
                }
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    let next = self.currentIndex + 1
                    if next < self.words.count {
                        self.currentIndex = next
                        // v15p4ae: when the highlight has cycled past
                        // the end of the current display group, swap
                        // the group to a new chunk starting at the
                        // new currentIndex. The group is otherwise
                        // FIXED — display doesn't change mid-group.
                        if next >= self.displayGroupStart + self.displayGroupSize {
                            self.startNewDisplayGroup(at: next)
                        }
                    } else {
                        self.currentIndex = max(0, self.words.count - 1)
                        self.pause()
                    }
                }
            }
        }
    }

    /// Duration in milliseconds the word at `index` should display.
    /// Base = 60000 / WPM. Multipliers applied for:
    ///   • trailing punctuation (natural clause-end rests)
    ///   • word length (longer words need more fixation time;
    ///     ramps from 1.0× at ≤6 chars to 2.0× at ≥18 chars).
    /// Without length scaling, a 3-char "the" and a 14-char chunk
    /// like `voice-command` get the same time, which is unreadable.
    private func durationForWord(at index: Int) -> UInt64 {
        guard index < words.count else { return 0 }
        let baseMs = 60_000.0 / Double(wpm)
        let word = words[index]
        let punctuationMultiplier: Double = {
            if word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") {
                return periodMultiplier
            }
            if word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") {
                return commaMultiplier
            }
            return 1.0
        }()
        let lengthMultiplier = lengthMultiplier(for: word)
        return UInt64(baseMs * punctuationMultiplier * lengthMultiplier)
    }

    /// Linear scaling: 1.0× at ≤6 chars, 2.0× at ≥18 chars, interpolated
    /// in between. Keeps short words fast and long words readable.
    private func lengthMultiplier(for word: String) -> Double {
        let count = word.count
        if count <= 6 { return 1.0 }
        if count >= 18 { return 2.0 }
        let normalized = Double(count - 6) / 12.0
        return 1.0 + normalized
    }

    // MARK: - Tokenization

    /// Maximum character count before a compound token is split at its
    /// internal punctuation. 14 chosen as the upper bound of comfortable
    /// single-fixation word width; anything longer benefits from being
    /// broken into pieces the eye can grab in one saccade.
    private static let longTokenSplitThreshold: Int = 14

    /// Characters used to split long compound tokens. Includes URL/path
    /// delimiters (/, \, :), query separators (?, &, =), and identifier
    /// joiners (_, |, ;) so tokens like
    /// `https://clicky-proxy.sapierso.workers.dev/voice-command` become
    /// readable chunks instead of one 50-char "word" flickering past.
    private static let longTokenSplitCharacters: Set<Character> = [
        "/", "\\", ":", "?", "&", "=", "_", "|", ";"
    ]

    /// Split text on whitespace, then break any token longer than the
    /// split threshold at its internal punctuation. Punctuation is kept
    /// as the trailing character of the chunk before it (e.g. `https:`
    /// rather than `https`) so the reader still sees the structure.
    private static func tokenize(text: String) -> [String] {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return [] }
        let whitespaceTokens = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var result: [String] = []
        result.reserveCapacity(whitespaceTokens.count)
        for token in whitespaceTokens {
            if token.count <= longTokenSplitThreshold {
                result.append(token)
            } else {
                result.append(contentsOf: splitLongToken(token))
            }
        }
        return result
    }

    /// Break a long compound token at its internal punctuation. Each
    /// resulting chunk keeps its trailing delimiter so the reader can
    /// still see the structure (`https:` then `//clicky-proxy.…` etc.).
    /// If a chunk is still longer than the threshold after punctuation
    /// splitting, it is halved repeatedly so no single chunk exceeds
    /// the threshold by more than a few characters.
    private static func splitLongToken(_ token: String) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        for character in token {
            currentChunk.append(character)
            if longTokenSplitCharacters.contains(character) {
                chunks.append(currentChunk)
                currentChunk = ""
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        // Secondary pass: any chunk still longer than the threshold
        // (e.g. a very long subdomain or a function name with no
        // delimiters) gets halved until it fits.
        var finalChunks: [String] = []
        finalChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            finalChunks.append(contentsOf: halveUntilUnderThreshold(chunk))
        }
        return finalChunks
    }

    /// Repeatedly halve a string until every piece is at or below the
    /// split threshold. Used as a fallback for compound tokens with no
    /// internal punctuation (long subdomains, run-on identifiers).
    private static func halveUntilUnderThreshold(_ string: String) -> [String] {
        if string.count <= longTokenSplitThreshold {
            return [string]
        }
        let midIndex = string.index(string.startIndex, offsetBy: string.count / 2)
        let firstHalf = String(string[..<midIndex])
        let secondHalf = String(string[midIndex...])
        return halveUntilUnderThreshold(firstHalf) + halveUntilUnderThreshold(secondHalf)
    }

    // MARK: - ORP (Optimal Recognition Point)

    /// Returns the character index that should be highlighted for word
    /// `w`. Standard Spritz-style ORP heuristic:
    ///   1 char: index 0
    ///   2-5 chars: index 1
    ///   6-9 chars: index 2
    ///   10-13 chars: index 3
    ///   14+ chars: index 4
    /// Punctuation-stripped length is what drives the heuristic; the
    /// returned index applies to the original word.
    static func orpIndex(for word: String) -> Int {
        let stripped = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        let n = stripped.count
        switch n {
        case 0...1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }
}

// MARK: - SwiftUI view

private struct SpeedReadView: View {
    @ObservedObject var controller: SpeedReadController
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if controller.isCompressing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: DS.Colors.overlayCursorBlue))
                Text("Compressing with AI…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                wordDisplay
                progressBar
                controlsRow
            }
        }
        .frame(width: 560, height: 220)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 8)
        )
        // Accept keyboard events; the NSPanel parent sets canBecomeKey.
        .onAppear { /* focus is handled by the NSPanel makeKey on show */ }
    }

    // MARK: - Subviews

    /// RSVP display with the ORP character of the first word highlighted
    /// in the accent color. In single-word mode (chunkSize=1) this is
    /// classic Spritz RSVP. In chunked mode (2 or 3) the additional
    /// words trail to the right at a slightly smaller, dimmer style so
    /// the eye still anchors on the same ORP point but takes in the
    /// extra context per fixation.
    private var wordDisplay: some View {
        Group {
            if controller.currentIndex < controller.words.count {
                // v15p4ae: render the entire FIXED display group. Only
                // the word at `highlightIndexInGroup` gets the bright
                // ORP-anchored treatment; others stay dim. As the
                // highlight slides through, the group itself doesn't
                // move — only the colored word changes.
                let groupStart = controller.displayGroupStart
                let groupEnd = min(groupStart + controller.displayGroupSize, controller.words.count)
                let groupWords = Array(controller.words[groupStart..<groupEnd])
                let highlightIdx = controller.highlightIndexInGroup
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(groupWords.enumerated()), id: \.offset) { localIdx, word in
                        if localIdx == highlightIdx {
                            // Focal word: bright with ORP-colored letter
                            let orp = SpeedReadController.orpIndex(for: word)
                            HStack(spacing: 0) {
                                ForEach(Array(word.enumerated()), id: \.offset) { charIdx, char in
                                    Text(String(char))
                                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                                        .foregroundColor(
                                            charIdx == orp
                                                ? DS.Colors.overlayCursorRed
                                                : .white
                                        )
                                }
                            }
                        } else {
                            // Context word: dim, no ORP marker
                            Text(word)
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.38))
                        }
                    }
                }
            } else {
                Text("done")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Slim progress bar showing position through the word stream.
    private var progressBar: some View {
        let total = max(controller.words.count, 1)
        let progress = Double(controller.currentIndex) / Double(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: max(2, geo.size.width * progress))
            }
        }
        .frame(height: 3)
    }

    /// Bottom row: play/pause indicator, WPM, chunk size, word counter.
    private var controlsRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: controller.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(controller.wpm) WPM")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.85))

            Text("•")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.white.opacity(0.25))

            Text(controller.chunkSize == 0 ? "auto" : "\(controller.chunkSize)w")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            Text("\(controller.currentIndex + 1) / \(controller.words.count)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))

            Text("space pause · ← → jump · ↑ ↓ speed · 1-4/s window · esc close")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.white.opacity(0.35))
        }
    }
}

// MARK: - Panel manager

/// Owns the SpeedReadKeyablePanel lifecycle. Shows the overlay,
/// installs a local keyboard monitor for keyboard control, and tears
/// everything down on close.
@MainActor
final class SpeedReadOverlayManager {

    private var panel: SpeedReadKeyablePanel?
    private var keyMonitor: Any?
    let controller = SpeedReadController()

    /// Show the overlay with the given text. If `compressFirst` is
    /// true, the text is routed through Haiku before tokenization.
    /// The compression call is the caller's responsibility — we just
    /// flip the isCompressing flag here and the caller updates the
    /// text via `loadText` when ready.
    func showOverlay(text: String, startingWPM: Int, compressing: Bool) {
        if panel == nil {
            createPanel()
        }
        positionPanel()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installKeyMonitor()

        if compressing {
            controller.isCompressing = true
        } else {
            controller.load(text: text, startingWPM: startingWPM)
        }
    }

    /// Replace the current text after async compression finishes. The
    /// overlay must already be showing.
    func loadCompressedText(_ text: String, startingWPM: Int) {
        controller.isCompressing = false
        controller.load(text: text, startingWPM: startingWPM)
    }

    /// Mark compression as failed; load the original text instead so
    /// the user isn't stuck staring at a spinner.
    func compressionFailed(fallbackText: String, startingWPM: Int) {
        controller.isCompressing = false
        controller.load(text: fallbackText, startingWPM: startingWPM)
    }

    func hideOverlay() {
        controller.stop()
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Setup

    private func createPanel() {
        let view = SpeedReadView(controller: controller, onDismiss: { [weak self] in
            self?.hideOverlay()
        })

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 608, height: 268)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let p = SpeedReadKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 608, height: 268),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isExcludedFromWindowsMenu = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        // Hidden from screen captures — same convention as the cursor
        // overlay and notch pill.
        p.sharingType = .none
        p.contentView = hostingView
        panel = p
    }

    private func positionPanel() {
        guard let panel else { return }
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = (frame.midX - panelSize.width / 2).rounded()
        // Slightly above vertical center — eye line is more natural
        // looking slightly upward than dead-center on a laptop screen.
        let y = (frame.midY - panelSize.height / 2 + 60).rounded()
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 49: // space
                self.controller.togglePlayPause()
                return nil
            case 53: // esc
                self.hideOverlay()
                return nil
            case 123: // left arrow
                self.controller.jumpBack()
                return nil
            case 124: // right arrow
                self.controller.jumpForward()
                return nil
            case 125: // down arrow
                self.controller.adjustWPM(by: -self.controller.wpmStep)
                return nil
            case 126: // up arrow
                self.controller.adjustWPM(by: self.controller.wpmStep)
                return nil
            case 18: // 1
                self.controller.setChunkSize(1)
                return nil
            case 19: // 2
                self.controller.setChunkSize(2)
                return nil
            case 20: // 3
                self.controller.setChunkSize(3)
                return nil
            case 21: // 4
                self.controller.setChunkSize(4)
                return nil
            case 29: // 0 — smart/auto mode
                self.controller.setChunkSize(0)
                return nil
            case 1:  // s — also smart/auto, easier mnemonic
                self.controller.setChunkSize(0)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
