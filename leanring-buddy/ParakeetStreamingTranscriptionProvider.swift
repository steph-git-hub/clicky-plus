//
//  ParakeetStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by NVIDIA Parakeet TDT
//  running fully local on Apple Neural Engine via FluidAudio SDK.
//
//  v15p4bm (2026-05-29): added as the 3rd VTT provider.
//
//  v15p4br (2026-05-29): REWRITTEN to bypass SlidingWindowAsrManager.
//  Sliding window in FluidAudio v0.14.7 only emits at chunkSeconds
//  cadence (hypothesisChunkSeconds is dead config), capping partial
//  latency at ~3s. We now use AsrManager.transcribe([Float]) directly
//  with a rolling Float buffer + 700ms timer for partials. Since
//  transcribe runs at ~190× realtime on Apple Silicon, re-transcribing
//  a 30s buffer takes ~160ms — easily within a 700ms budget.
//
//  First-launch cost: ~600MB model download (cached). First inference
//  ~5-10s for ANE compilation. Warm sub-200ms.
//

import AppKit
import AVFoundation
import FluidAudio
import Foundation


struct ParakeetStreamingTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Shared model loader

/// Single-instance actor owning the AsrModels bundle. First call
/// triggers download+compile; subsequent calls return the cached
/// instance. Concurrent callers all await the same in-flight task.
actor ParakeetModelLoader {
    static let shared = ParakeetModelLoader()

    private var cachedModels: AsrModels?
    private var loadTask: Task<AsrModels, Error>?

    // v15p4bu (2026-05-29): also cache CtcModels (needed for vocab
    // boosting) and a tokenized vocab context. CtcModels is a
    // separate ~30-50MB download on first use.
    private var cachedCtcModels: CtcModels?
    private var ctcLoadTask: Task<CtcModels, Error>?
    private var cachedVocabKey: [String]?      // last-built key
    private var cachedVocab: CustomVocabularyContext?

    func models() async throws -> AsrModels {
        if let cached = cachedModels { return cached }
        if let existingTask = loadTask { return try await existingTask.value }
        let task = Task<AsrModels, Error> {
            print("🦜 Parakeet: loading AsrModels (~600MB on first launch)…")
            let started = Date()
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "🦜 Parakeet: AsrModels loaded in %.1fs", elapsed))
            return models
        }
        loadTask = task
        do {
            let models = try await task.value
            cachedModels = models
            loadTask = nil
            return models
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Lazy-load CtcModels (separate model bundle for keyword spotting
    /// in vocab boosting). First call triggers download + ANE compile.
    func ctcModels() async throws -> CtcModels {
        if let cached = cachedCtcModels { return cached }
        if let existingTask = ctcLoadTask { return try await existingTask.value }
        let task = Task<CtcModels, Error> {
            print("🦜 Parakeet: loading CtcModels for vocab boost…")
            let started = Date()
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "🦜 Parakeet: CtcModels loaded in %.1fs", elapsed))
            return models
        }
        ctcLoadTask = task
        do {
            let models = try await task.value
            cachedCtcModels = models
            ctcLoadTask = nil
            return models
        } catch {
            ctcLoadTask = nil
            throw error
        }
    }

    /// Build (or return cached) CustomVocabularyContext for a given
    /// keyterms list. Uses CtcTokenizer to pre-tokenize each term —
    /// required for the vocab rescorer. Cached on the keyterms array
    /// so we don't re-tokenize every session start.
    func vocabContext(keyterms: [String]) async throws -> CustomVocabularyContext {
        let dedupedSorted = Array(Set(keyterms)).sorted()
        if let key = cachedVocabKey, key == dedupedSorted, let vocab = cachedVocab {
            return vocab
        }
        let ctcVariant: CtcModelVariant = .ctc110m
        _ = try await ctcModels()  // ensures download done before tokenizer load
        let ctcTokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: ctcVariant)
        )
        let terms: [CustomVocabularyTerm] = dedupedSorted.compactMap { text in
            let ids = ctcTokenizer.encode(text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: text, weight: nil, aliases: nil, tokenIds: nil, ctcTokenIds: ids
            )
        }
        let vocab = CustomVocabularyContext(terms: terms)
        cachedVocabKey = dedupedSorted
        cachedVocab = vocab
        print("🦜 Parakeet: built vocab context with \(terms.count) tokenized terms")
        return vocab
    }

    func prewarm() async {
        do { _ = try await models() }
        catch { print("🦜 Parakeet: prewarm failed: \(error.localizedDescription)") }
    }
}


// MARK: - Provider

final class ParakeetStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let models: AsrModels
        do {
            models = try await ParakeetModelLoader.shared.models()
        } catch {
            throw ParakeetStreamingTranscriptionProviderError(
                message: "Parakeet model load failed: \(error.localizedDescription)"
            )
        }

        // Fast partial path: AsrManager, 700ms rolling-buffer re-transcribe.
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)

        // v16 (2026-06-04): boosted-final path RE-ENABLED behind a token
        // guard for the STT bake-off. The boosted vocab-boost engine
        // fixes mistranscribed proper nouns but used to over-correct
        // common words ("both"→"Bodhi", "using"→"ASIN") because finalize
        // adopted the WHOLE boosted transcript whenever it wasn't a
        // length-drop. Now Self.guardedMerge keeps the fast transcript as
        // the base and only swaps in a boosted word where the fast word
        // isn't a real English word — proper-noun fixes land, real words
        // are never overwritten. Flip to false to fully revert.
        let useBoostedFinalize = true
        var boostedFinal: SlidingWindowAsrManager?
        if useBoostedFinalize && !keyterms.isEmpty {
            do {
                let ctc = try await ParakeetModelLoader.shared.ctcModels()
                let vocab = try await ParakeetModelLoader.shared.vocabContext(keyterms: keyterms)
                let sw = SlidingWindowAsrManager(config: .streaming)
                try await sw.loadModels(models)
                try await sw.configureVocabularyBoosting(vocabulary: vocab, ctcModels: ctc)
                try await sw.startStreaming(source: .microphone)
                boostedFinal = sw
                print("🦜 Parakeet: boosted-final path active (\(keyterms.count) keyterms)")
            } catch {
                print("🦜 Parakeet: boost setup failed (\(error.localizedDescription)) — falling back to fast-only final")
                boostedFinal = nil
            }
        }

        let session = ParakeetStreamingTranscriptionSession(
            asr: asr,
            boostedFinal: boostedFinal,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        session.startPartialTimer()
        return session
    }

    func prewarmSession(keyterms: [String]) {
        Task.detached { await ParakeetModelLoader.shared.prewarm() }
    }
}


// MARK: - Session

/// Rolling-buffer session. Appends resampled Float32 mono samples
/// as audio arrives; a timer fires every `partialIntervalSeconds`
/// and re-transcribes the entire accumulated buffer, emitting the
/// result as a partial. On finalize, one final transcribe of the
/// full buffer is the confirmed result.
///
/// Concurrency: a single in-flight flag prevents overlapping
/// transcribes — if a tick fires while one is running, the tick
/// is skipped. Audio appends are serialized via the bufferLock.
final class ParakeetStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { 3.0 }
    var trailingAudioGraceSeconds: TimeInterval { 0.2 }

    /// How often to fire a partial transcribe. 0.7s is the sweet
    /// spot: feels responsive but doesn't pin the ANE.
    private let partialIntervalSeconds: TimeInterval = 0.7

    private let asr: AsrManager
    /// v15p4bu: optional boosted-final engine. When present, finalize
    /// returns its boosted transcript instead of the fast path's.
    private let boostedFinal: SlidingWindowAsrManager?
    private let audioConverter = AudioConverter()
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let bufferLock = NSLock()
    private var samples: [Float] = []   // 16 kHz mono Float32

    /// v15p4ca (2026-05-30): leading-audio guard window. The PTT
    /// key-press click is captured as a sharp transient at t≈0, and
    /// Parakeet's whole-buffer transcribe turns it into a phantom
    /// first word even when Steph says nothing. Drop the first
    /// `leadingTrimSamples` of captured 16 kHz audio so the click
    /// never reaches either the fast or boosted engine. 120 ms is
    /// well below the reaction-time gap between pressing the hotkey
    /// and articulating the first phoneme, so real speech is never
    /// clipped. Tunable if a fast talker ever clips.
    private static let leadingTrimSamples = 1_920  // 120 ms @ 16 kHz
    private var leadingSamplesDropped = 0

    /// v15p4ci (2026-05-30): silence gate v2 — lexical, not pure energy.
    /// Pure energy gating (v15p4cb/cc) kept eating real QUIET speech:
    /// "yes please fix them all" landed at peak ~0.033, just under the
    /// 0.035 cutoff, and got dropped. The threshold fundamentally
    /// collides with softly-spoken short phrases. New approach:
    ///   1. HARD silence floor (peak < hardSilencePeak AND rms <
    ///      hardSilenceRMS) → suppress pre-transcribe. This is dead
    ///      silence, far below any real speech (~0.033+), so it never
    ///      clips real audio.
    ///   2. Otherwise transcribe, then suppress ONLY if the result is
    ///      empty or a LONE FILLER ("uh"/"yeah"/"mm") AND the audio was
    ///      quiet (peak < fillerSuppressPeak). Real phrases contain
    ///      content words, so they never match filler-only and always
    ///      pass, no matter how softly spoken.
    /// All thresholds tunable from the rms/peak logged on every finalize.
    private static let hardSilencePeak: Float = 0.020
    private static let hardSilenceRMS: Float = 0.004
    private static let fillerSuppressPeak: Float = 0.045
    private static let silenceFillerTokens: Set<String> = [
        "uh", "uhh", "um", "umm", "mm", "mmm", "hmm", "hmmm", "mhm", "mhmm",
        "er", "err", "ah", "ahh", "eh", "huh", "yeah", "yea", "yep",
        "okay", "ok", "you", "thank", "thanks", "bye", "so"
    ]

    /// True when every word in `text` is a filler token (or text is
    /// empty) — i.e. there's no real content to lose by suppressing.
    private static func isFillerOnly(_ text: String) -> Bool {
        let scalars = text.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) ? Character($0) : " "
        }
        let tokens = String(scalars).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { silenceFillerTokens.contains($0) }
    }

    /// RMS + peak amplitude of a 16 kHz mono Float buffer.
    private static func audioEnergy(_ buf: [Float]) -> (rms: Float, peak: Float) {
        guard !buf.isEmpty else { return (0, 0) }
        var sumSq: Float = 0
        var peak: Float = 0
        for s in buf {
            sumSq += s * s
            let a = abs(s)
            if a > peak { peak = a }
        }
        return (sqrt(sumSq / Float(buf.count)), peak)
    }

    private var partialTimer: Timer?
    private var inFlight = false
    private var hasFinalizedOrCancelled = false
    private var lastPartialText = ""

    /// v15p4bs (2026-05-29): Parakeet emits verbatim ("um", "uh"
    /// etc), where Deepgram and AssemblyAI strip them by default.
    /// This regex matches standalone filler tokens, optionally
    /// followed by trailing punctuation/whitespace, and collapses
    /// adjacent spaces left behind.
    private static let fillerRegex: NSRegularExpression = {
        // Standalone tokens — word boundary on both sides. Avoid
        // matching "umbrella", "uhhuh", etc.
        let pattern = #"\b(?:um+|uh+|uhm+|umm+|hmm+|er+|ah+|huh)\b[,.]?\s?"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func stripFillers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = fillerRegex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
        // Collapse any double-spaces left by the strip + trim edges.
        let collapsed = stripped.replacingOccurrences(
            of: "  ", with: " ", options: .literal, range: nil
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// v15p4bv (2026-05-29): post-process alias map for proper-noun
    /// mishearings the vocab boost can't reliably catch (where the
    /// misheard word is itself a plausible English word with high TDT
    /// confidence — Lucas vs Lukas, Shipmunk vs Shipmonk).
    ///
    /// Source: keyterms.json rationale field. Each entry there
    /// documents the exact mishearing this rescues. Conservative —
    /// only includes terms where the wrong form is (a) very unlikely
    /// to be what Steph actually meant in normal use, and (b)
    /// confirmed to mis-fire on Parakeet even after vocab boost.
    private static let aliasReplacements: [(pattern: NSRegularExpression, replacement: String)] = {
        let mappings: [(String, String)] = [
            ("Lucas", "Lukas"),
            ("Shipmunk", "Shipmonk"),
            // v15p4cf (2026-05-30): after disabling the boosted engine,
            // these proper-noun mishearings fell through. Added the exact
            // lowercase/variant forms the fast engine produced in testing.
            ("shipmunk", "Shipmonk"),
            ("Shitmunk", "Shipmonk"),
            ("shitmunk", "Shipmonk"),
            ("Gamnetic", "Glamnetic"),
            ("Glam Netic", "Glamnetic"),
            ("Glamnet", "Glamnetic"),
            ("Glam Net", "Glamnetic"),
            ("Hersheika", "Harshika"),
            ("hersheika", "Harshika"),
            // Steph confirmed he never dictates "Hershey" in work context.
            ("Hershey", "Harshika"),
            ("hershey", "Harshika"),
            // NOTE: "Ulta" (standalone) is intentionally NOT auto-corrected
            // from "Ultra"/"alter" — those are real words Steph uses. He'll
            // hand-fix the occasional standalone "Ulta" miss. ("Ulta sheet"
            // variants below are safe because they aren't real phrases.)
            // v15p4by (2026-05-30): caught during edge-case test —
            // Parakeet hears "kombo" as "combo" reliably.
            ("Combo Ventures", "Kombo Ventures"),
            ("ComboVentures", "KomboVentures"),
            ("comboventures", "komboventures"),
            // v15p4cj (2026-05-30): test run produced lowercase "combo
            // ventures" (didn't match the capitalized form above). The
            // two-word phrase is safe — "combo" alone (combo meal) is
            // untouched.
            ("combo ventures", "Kombo Ventures"),
            ("Combo ventures", "Kombo Ventures"),
            // v15p4by: "Ulta sheet" is a common Steph phrase that all
            // three engines struggle with — single-word, lowercased
            // forms keep coming through.
            ("ultasheet", "Ulta sheet"),
            ("Ultasheet", "Ulta sheet"),
            ("altasheet", "Ulta sheet"),
            ("Ultashii", "Ulta sheet"),
            ("ultashee", "Ulta sheet"),
            ("Ulta shii", "Ulta sheet"),
            ("Septr", "Sceptre"),
            ("Septre", "Sceptre"),
            ("Scepter", "Sceptre"),
            ("Boonhang", "Bunheng"),
            ("Bunhang", "Bunheng"),
            // v16 (2026-06-04): Scribe heard "Bunheng" as two words
            // "Boon Hang". Patterns are case-SENSITIVE — cover the forms seen.
            ("Boon Hang", "Bunheng"),
            ("Boon hang", "Bunheng"),
            ("boon hang", "Bunheng"),
            // Scribe produces "Boon Heng" (different vowel) — 2026-06-04.
            ("Boon Heng", "Bunheng"),
            ("Boon heng", "Bunheng"),
            ("boon heng", "Bunheng"),
            ("Boonheng", "Bunheng"),
            ("Maren", "Marin"),
            ("Marion", "Marin"),
            ("Bodie", "Bodhi"),
            ("Caitlyn", "Caitlin"),
            ("Cider", "Sider"),
            // v15p4dz (2026-06-03): Steph says "D to C" / "D two C"
            // (direct-to-consumer) and wants it written DTC, not "D to C"
            // or "D2C". Cover the connector + capitalization variants the
            // engines produce. Safe — these phrases have no other meaning.
            ("D to C", "DTC"),
            ("D To C", "DTC"),
            ("d to c", "DTC"),
            ("D two C", "DTC"),
            ("D Two C", "DTC"),
            ("d two c", "DTC"),
            ("D 2 C", "DTC"),
            ("D2C", "DTC"),
            // Concatenated forms the engine actually emits (no spaces).
            ("DToC", "DTC"),
            ("DTOC", "DTC"),
            ("DtoC", "DTC"),
            ("Dtoc", "DTC"),
            ("dtoc", "DTC"),
            ("DTwoC", "DTC"),
            ("DtwoC", "DTC"),
        ]
        return mappings.map { (wrong, right) in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
            return (try! NSRegularExpression(pattern: pattern, options: []), right)
        }
    }()

    private static func applyAliasReplacements(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in aliasReplacements {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: replacement
            )
        }
        return result
    }

    /// v15p4bw (2026-05-29): light ITN (Inverse Text Normalization)
    /// for common spoken-form patterns Parakeet doesn't normalize on
    /// its own. Conservative — only catches patterns where the wrong
    /// form is virtually never what Steph would prefer in normal use.
    private static let percentRegex = try! NSRegularExpression(
        pattern: #"\b(\d+(?:\.\d+)?)\s+percent\b"#,
        options: [.caseInsensitive]
    )
    private static let quarterRegex = try! NSRegularExpression(
        pattern: #"\bQ\s+(One|Two|Three|Four)\b"#,
        options: [.caseInsensitive]
    )
    private static let quarterDigitMap: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4"
    ]

    private static func applyITN(_ text: String) -> String {
        var result = text

        // "19 percent" / "19.5 percent" → "19%" / "19.5%"
        let percentRange = NSRange(result.startIndex..., in: result)
        result = percentRegex.stringByReplacingMatches(
            in: result, options: [], range: percentRange, withTemplate: "$1%"
        )

        // "Q One" / "Q Two" / etc. → "Q1" / "Q2" / etc.
        let nsResult = result as NSString
        let qRange = NSRange(location: 0, length: nsResult.length)
        let matches = quarterRegex.matches(in: result, options: [], range: qRange)
        // Reverse-iterate so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let wordRange = match.range(at: 1)
            let wordNS = (result as NSString).substring(with: wordRange).lowercased()
            guard let digit = quarterDigitMap[wordNS] else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: "Q\(digit)")
        }

        return result
    }

    /// v15p4cg (2026-05-30): phonetic name matching. The exact alias
    /// map requires hand-listing every mishearing; this generalizes by
    /// matching a token's CONSONANT SKELETON against a curated set of
    /// proper nouns, so novel mishearings of the same name are caught
    /// without adding a line. Scoped DELIBERATELY to names with no
    /// common-word homophone — Ulta / Marin / Kombo are excluded
    /// because "alter/ultra", "marine", "combo" are real words Steph
    /// uses. Fires only on EXACT key equality (not fuzzy distance) to
    /// keep false positives near zero. Pure local string ops — no LLM,
    /// VTT stays instant + offline.
    private static let phoneticNameTargets: [String] = [
        "Glamnetic", "Shipmonk", "Harshika", "Bunheng"
    ]
    private static let phoneticTokenRegex = try! NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z']*", options: []
    )

    /// Consonant-skeleton key: lowercase letters, keep the first, drop
    /// vowels after it, fold only the safe consonant equivalences
    /// (c/k/q, s/z), collapse adjacent duplicates. Two words with the
    /// same key sound alike.
    private static func phoneticKey(_ s: String) -> String {
        let letters = s.lowercased().filter { $0.isLetter }
        guard let first = letters.first else { return "" }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        func equiv(_ c: Character) -> Character {
            switch c {
            case "c", "k", "q": return "k"
            case "s", "z": return "s"
            default: return c
            }
        }
        var key = String(equiv(first))
        for c in letters.dropFirst() {
            if vowels.contains(c) { continue }
            let e = equiv(c)
            if key.last == e { continue }
            key.append(e)
        }
        return key
    }

    private static let phoneticTargetKeys: [(name: String, key: String)] =
        phoneticNameTargets.map { ($0, phoneticKey($0)) }

    private static func applyPhoneticNameMatch(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = phoneticTokenRegex.matches(in: text, options: [], range: full)
        var result = text
        // Replace in reverse so earlier ranges stay valid as we mutate.
        for m in matches.reversed() {
            let token = ns.substring(with: m.range)
            guard token.count >= 5 else { continue }
            // Already one of the target names? leave it.
            if phoneticNameTargets.contains(where: {
                $0.caseInsensitiveCompare(token) == .orderedSame
            }) { continue }
            let tokenKey = phoneticKey(token)
            guard tokenKey.count >= 4 else { continue }
            if let hit = phoneticTargetKeys.first(where: { $0.key == tokenKey }) {
                result = (result as NSString)
                    .replacingCharacters(in: m.range, with: hit.name)
            }
        }
        return result
    }

    /// Compose: aliases → phonetic names → ITN → fillers (order
    /// matters; aliases run case-sensitive before any case-altering
    /// pass; phonetic catches mishearings the alias list doesn't;
    /// ITN catches spoken-form numbers; fillers strip last).
    /// v15p4cl (2026-05-30): shared name-correction (alias + phonetic).
    /// Lives here but is the single source of truth used by BOTH
    /// Parakeet's own post-process AND the provider-agnostic paste path,
    /// so EVERY active engine (Deepgram, AssemblyAI, Parakeet) gets the
    /// same name fixes — not just Parakeet. Idempotent, so a second pass
    /// on already-corrected text is a no-op.
    static func correctNames(_ text: String) -> String {
        applyPhoneticNameMatch(applyAliasReplacements(text))
    }

    private static func postProcess(_ text: String) -> String {
        let named = correctNames(text)
        let normalized = applyITN(named)
        return stripFillers(normalized)
    }

    /// v15p4bz (2026-05-30): finalize diag log. One line per
    /// transcription session showing both engine outputs + which one
    /// won + drop detection state. Lets Steph review drops after the
    /// fact since the dropped audio never makes it to Obsidian.
    ///
    /// Path: /tmp/clicky_parakeet_finalize.log
    private static let finalizeDiagPath = "/tmp/clicky_parakeet_finalize.log"
    private static let finalizeDiagFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func appendFinalizeDiag(
        fast: String, boosted: String, chosen: String, error: String?,
        livePreview: String = "", finalText: String = ""
    ) {
        let ts = finalizeDiagFormatter.string(from: Date())
        // Cap each transcript at 400 chars in the log so a long
        // dictation doesn't blow the file size; full text is what
        // got pasted/logged elsewhere anyway.
        let fastPreview = fast.count > 400 ? String(fast.prefix(400)) + "…" : fast
        let boostedPreview = boosted.count > 400 ? String(boosted.prefix(400)) + "…" : boosted
        // v15p4cd (2026-05-30): also record the last live-preview
        // (partial) text. The on-screen preview is otherwise discarded,
        // and it's frequently MORE correct than the final wrap-up — so
        // logging it lets us tell a listening error from a finalize error.
        let livePrev = livePreview.count > 400 ? String(livePreview.prefix(400)) + "…" : livePreview
        let finalPrev = finalText.count > 400 ? String(finalText.prefix(400)) + "…" : finalText
        let line = "[\(ts)] chosen=\(chosen) fast_len=\(fast.count) boosted_len=\(boosted.count) preview_len=\(livePreview.count) boosted_err=\(error ?? "nil")\n  PREVIEW: \(livePrev)\n  FAST: \(fastPreview)\n  BOOSTED: \(boostedPreview)\n  FINAL: \(finalPrev)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: finalizeDiagPath) {
                if let handle = FileHandle(forWritingAtPath: finalizeDiagPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: finalizeDiagPath))
            }
        }
    }

    init(
        asr: AsrManager,
        boostedFinal: SlidingWindowAsrManager?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.asr = asr
        self.boostedFinal = boostedFinal
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func startPartialTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.partialTimer?.invalidate()
            self.partialTimer = Timer.scheduledTimer(
                withTimeInterval: self.partialIntervalSeconds,
                repeats: true
            ) { [weak self] _ in
                self?.firePartialTranscribe()
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasFinalizedOrCancelled else { return }
        // v15p4ca (2026-05-30): true while this buffer falls entirely
        // inside the leading guard window — used to keep the boosted
        // path's leading trim in lockstep with the fast path so the
        // key-press click is dropped from both engines.
        var bufferFullyTrimmed = false
        // Fast partial path — buffer for re-transcribe.
        do {
            let resampled = try audioConverter.resampleBuffer(audioBuffer)
            bufferLock.lock()
            if leadingSamplesDropped < Self.leadingTrimSamples {
                let remaining = Self.leadingTrimSamples - leadingSamplesDropped
                if resampled.count <= remaining {
                    // Entire buffer is still inside the guard window — drop it.
                    leadingSamplesDropped += resampled.count
                    bufferFullyTrimmed = true
                } else {
                    // This buffer straddles the end of the guard window —
                    // keep only the tail (past the click region).
                    leadingSamplesDropped = Self.leadingTrimSamples
                    samples.append(contentsOf: resampled[remaining...])
                }
            } else {
                samples.append(contentsOf: resampled)
            }
            bufferLock.unlock()
        } catch {
            NSLog("[parakeet] resample failed: \(error.localizedDescription)")
        }
        // Boosted final path — feed the SlidingWindow engine in
        // parallel so it has the full audio ready to transcribe on
        // finalize. Nonblocking — its internal AsyncStream handles
        // backpressure. Skip buffers fully inside the guard window so
        // the click is trimmed from the boosted engine too.
        if let sw = boostedFinal, !bufferFullyTrimmed {
            Task { await sw.streamAudio(audioBuffer) }
        }
    }

    private func firePartialTranscribe() {
        guard !hasFinalizedOrCancelled, !inFlight else { return }
        bufferLock.lock()
        let snapshot = samples
        bufferLock.unlock()
        // Need ~0.5s of audio before transcribe is useful.
        guard snapshot.count > 8_000 else { return }
        // v15p4cb (2026-05-30): silence gate for partials — don't flash
        // hallucinated filler in the live preview before finalize.
        let partialEnergy = Self.audioEnergy(snapshot)
        // v15p4ci: hard-silence floor only, so quiet real speech still
        // shows in the live preview (matches the finalize gate).
        guard !(partialEnergy.peak < Self.hardSilencePeak && partialEnergy.rms < Self.hardSilenceRMS) else { return }
        inFlight = true
        Task { [weak self, asr] in
            guard let self else { return }
            do {
                var decoderState = try TdtDecoderState()
                let result = try await asr.transcribe(
                    snapshot, decoderState: &decoderState, language: nil
                )
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = Self.postProcess(raw)
                if !text.isEmpty, text != self.lastPartialText {
                    self.lastPartialText = text
                    self.onTranscriptUpdate(text)
                }
            } catch {
                NSLog("[parakeet] partial transcribe failed: \(error.localizedDescription)")
            }
            self.inFlight = false
        }
    }

    func requestFinalTranscript() {
        guard !hasFinalizedOrCancelled else { return }
        hasFinalizedOrCancelled = true
        DispatchQueue.main.async { [weak self] in
            self?.partialTimer?.invalidate()
            self?.partialTimer = nil
        }
        bufferLock.lock()
        let snapshot = samples
        bufferLock.unlock()

        // v15p4ci (2026-05-30): HARD-silence floor only — suppress
        // pre-transcribe just for dead silence (far below real speech).
        // Quiet real speech (peak ~0.033) clears this and gets
        // transcribed; the lone-filler check below catches phantoms.
        let energy = Self.audioEnergy(snapshot)
        if energy.peak < Self.hardSilencePeak && energy.rms < Self.hardSilenceRMS {
            Self.appendFinalizeDiag(
                fast: "", boosted: "",
                chosen: "silence_gate(hard) rms=\(energy.rms) peak=\(energy.peak)",
                error: nil,
                livePreview: lastPartialText
            )
            Task { [asr, boostedFinal] in
                asr.cleanup()
                if let sw = boostedFinal {
                    await sw.cancel()
                    await sw.cleanup()
                }
            }
            onFinalTranscriptReady("")
            return
        }

        // Prefer the boosted SlidingWindow finalize when available.
        // Falls back to the fast-path transcribe if SlidingWindow
        // errors or isn't configured.
        // v15p4bz (2026-05-30): drop-detection. Run BOTH engines on
        // finalize and compare. If the boosted result is significantly
        // shorter than the fast result (>30% drop), the boosted path
        // lost audio — fall back to fast path. Always log both to
        // /tmp/clicky_parakeet_finalize.log so Steph can review
        // divergence patterns after the fact, since the dropped
        // sentences never reach Obsidian.
        Task { [weak self, asr, boostedFinal] in
            guard let self else { return }

            // Always run fast-path transcribe so we have a baseline
            // to compare against, even when boosted succeeds.
            var fastText: String = ""
            do {
                var decoderState = try TdtDecoderState()
                let result = try await asr.transcribe(
                    snapshot, decoderState: &decoderState, language: nil
                )
                fastText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                NSLog("[parakeet] fast finalize transcribe failed: \(error.localizedDescription)")
            }

            // v15p4ci (2026-05-30): lone-filler silence check. Suppress
            // only when there's nothing real to lose — empty result, or
            // every word is a filler ("uh"/"yeah"/"mm") AND the audio was
            // quiet. Real phrases contain content words, so a softly
            // spoken "yes please fix them all" always survives here.
            if fastText.isEmpty ||
                (Self.isFillerOnly(fastText) && energy.peak < Self.fillerSuppressPeak) {
                Self.appendFinalizeDiag(
                    fast: fastText, boosted: "",
                    chosen: "filler_gate rms=\(energy.rms) peak=\(energy.peak)",
                    error: nil, livePreview: self.lastPartialText, finalText: ""
                )
                asr.cleanup()
                if let sw = boostedFinal {
                    await sw.cancel()
                    await sw.cleanup()
                }
                self.onFinalTranscriptReady("")
                return
            }

            // Run boosted-path finish if available.
            var boostedText: String = ""
            var boostedError: String?
            if let sw = boostedFinal {
                do {
                    boostedText = try await sw.finish()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    boostedError = error.localizedDescription
                }
                await sw.cleanup()
            }
            asr.cleanup()

            // Drop-detection: pick the right transcript.
            let chosen: String
            let chosenSource: String
            if !boostedText.isEmpty, boostedError == nil {
                // Boosted ran. Did it lose audio? Heuristic: if boosted
                // is <70% the length of fast and fast is non-trivial,
                // the boosted path dropped content.
                let dropDetected = !fastText.isEmpty &&
                    fastText.count > 30 &&
                    Double(boostedText.count) < Double(fastText.count) * 0.70
                if dropDetected {
                    chosen = fastText
                    chosenSource = "fast (drop_detected boosted=\(boostedText.count) fast=\(fastText.count))"
                } else {
                    // v16: guarded merge instead of wholesale boosted —
                    // keeps fast's real words, adopts boosted only for
                    // non-dictionary (proper-noun) tokens.
                    chosen = await Self.guardedMerge(fast: fastText, boosted: boostedText)
                    chosenSource = "boosted_guarded"
                }
            } else if !fastText.isEmpty {
                chosen = fastText
                chosenSource = "fast (boosted_unavailable err=\(boostedError ?? "n/a"))"
            } else {
                self.onError(NSError(
                    domain: "Parakeet", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "both fast and boosted transcribes failed"]
                ))
                return
            }

            // Diag log so Steph can review drop patterns. v15p4cg:
            // also log the post-processed FINAL (alias + phonetic name
            // matching applied) so name corrections are verifiable.
            let finalText = Self.postProcess(chosen)
            Self.appendFinalizeDiag(
                fast: fastText, boosted: boostedText,
                chosen: "\(chosenSource) rms=\(energy.rms) peak=\(energy.peak)",
                error: boostedError,
                livePreview: self.lastPartialText,
                finalText: finalText
            )

            self.onFinalTranscriptReady(finalText)
        }
    }

    /// v16 guard for the boosted (vocab-boost) engine. Boosted can fix
    /// mistranscribed proper nouns (Gamnetic→Glamnetic) but also
    /// over-corrects common words (both→Bodhi). Keep the fast transcript
    /// as the base; adopt a boosted word ONLY when the fast word is NOT a
    /// valid English word (a likely proper-noun mishearing). If word
    /// counts diverge (misalignment), keep fast wholesale (safe).
    @MainActor
    static func guardedMerge(fast: String, boosted: String) -> String {
        let fastWords = fast.split(separator: " ").map(String.init)
        let boostedWords = boosted.split(separator: " ").map(String.init)
        guard !fastWords.isEmpty, fastWords.count == boostedWords.count else {
            return fast
        }
        let checker = NSSpellChecker.shared
        var merged: [String] = []
        merged.reserveCapacity(fastWords.count)
        for (f, b) in zip(fastWords, boostedWords) {
            if f.caseInsensitiveCompare(b) == .orderedSame {
                merged.append(f)
                continue
            }
            let core = f.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if core.isEmpty {
                merged.append(f)
                continue
            }
            let misspell = checker.checkSpelling(of: core, startingAt: 0)
            let fastIsRealWord = (misspell.location == NSNotFound)
            // Real word → keep fast (don't overwrite). Not a real word →
            // adopt boosted's keyterm candidate.
            merged.append(fastIsRealWord ? f : b)
        }
        return merged.joined(separator: " ")
    }

    func cancel() {
        guard !hasFinalizedOrCancelled else { return }
        hasFinalizedOrCancelled = true
        DispatchQueue.main.async { [weak self] in
            self?.partialTimer?.invalidate()
            self?.partialTimer = nil
        }
        Task { [asr, boostedFinal] in
            asr.cleanup()
            if let sw = boostedFinal {
                await sw.cancel()
                await sw.cleanup()
            }
        }
    }
}
