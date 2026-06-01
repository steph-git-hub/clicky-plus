//
//  ClickySoundEngine.swift
//  leanring-buddy
//
//  v15p3cu (2026-05-14): native synthesized interface sounds.
//
//  Plays short tonal feedback for the 9 user-visible events Clicky+
//  cares about: VTT start / success / error, Marin engage / disengage,
//  Polish start / done, Vision capture, and any other generic failure.
//
//  Design notes:
//
//   - Four families are pre-rendered to PCM buffers at launch (tactile
//     snap, pencil tap, single tones, chord stabs — Steph's curated
//     shortlist as of v15p3cw, 2026-05-15) so playback latency is
//     essentially zero (~one buffer schedule).
//
//   - Synthesis recipes match the JS Web Audio prototypes that Steph
//     auditioned in the cowork preview widget — same envelopes, same
//     bandpass settings, same note frequencies. The Swift port is
//     deterministic so what plays here matches what Steph heard.
//
//   - All four families respond to the same 9 ClickySoundID cases;
//     switching families is just swapping the active buffer
//     dictionary — no resynthesis at runtime.
//
//   - Engine starts once and stays running. Each play() does a single
//     scheduleBuffer() on an AVAudioPlayerNode, which is the lowest-
//     latency path in AVAudioEngine. Total ~2MB of PCM memory for the
//     full 4-family set; trivial vs. the rest of the app.
//
//   - User preferences (enabled flag + active family) persist via
//     UserDefaults under `clicky.sounds.enabled` and `clicky.sounds.family`.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Each user-visible event Clicky+ plays a sound for.
enum ClickySoundID: String, CaseIterable, Codable {
    case vttStart
    case vttSuccess
    case vttError
    case marinEngage
    case marinDisengage
    case polishStart
    case polishDone
    case visionCapture
    case genericError
}

/// Built-in synthesized sound families.
///
/// v15p3cw (2026-05-15): originally tactile snap, pencil tap, single
/// tones, chord stabs.
/// v15p3cx (2026-05-15): dropped pencil tap (effectively identical to
/// tactile snap to listeners) and chord stabs (Steph's preference).
/// v15p3de (2026-05-15): dropped single tones too — Steph wants the
/// built-in list minimal so custom sample families have the spotlight.
/// Only tactile snap remains as a synthesized fallback. Persisted
/// "single_tones" raw values fall back to tactile snap via the loader's
/// rawValue match check.
enum ClickySoundFamily: String, CaseIterable, Codable, Identifiable {
    case tactileSnap = "tactile_snap"

    var id: String { rawValue }

    /// Human-readable label shown in the panel UI.
    var displayName: String {
        switch self {
        case .tactileSnap: return "Tactile snap"
        }
    }
}

/// Unified family identifier — either a built-in synthesized family or
/// a user-supplied sample family discovered on disk.
///
/// v15p3cx (2026-05-15): introduced so the picker can offer both kinds
/// in a single list, and `activeFamily` can refer to either without
/// awkward dual-flag bookkeeping. Persists as a string in UserDefaults:
/// built-ins use their enum rawValue; custom families use the prefix
/// "custom:" followed by the family name (the source filename stem).
enum ActiveSoundFamily: Hashable, Codable {
    case builtin(ClickySoundFamily)
    case custom(String)

    var displayName: String {
        switch self {
        case .builtin(let f): return f.displayName
        case .custom(let name): return name
        }
    }

    /// Persistence key — round-trips through UserDefaults.
    var persistedID: String {
        switch self {
        case .builtin(let f): return f.rawValue
        case .custom(let name): return "custom:" + name
        }
    }

    /// Reverse of `persistedID`. Returns nil if the string doesn't match
    /// a known built-in case AND doesn't start with "custom:". Caller
    /// is responsible for verifying the custom family actually exists.
    static func from(persistedID: String) -> ActiveSoundFamily? {
        if persistedID.hasPrefix("custom:") {
            let name = String(persistedID.dropFirst("custom:".count))
            return .custom(name)
        }
        if let f = ClickySoundFamily(rawValue: persistedID) {
            return .builtin(f)
        }
        return nil
    }
}

@MainActor
final class ClickySoundEngine: ObservableObject {

    // MARK: - Singleton + preferences

    static let shared = ClickySoundEngine()

    /// User-visible on/off toggle. False = play() is a no-op.
    /// Persists in UserDefaults so the choice survives relaunch.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    /// Currently active sound family. Either a built-in or one of the
    /// user-supplied sample families discovered from the sounds folder.
    /// Switching is instant for both kinds — all variants are pre-
    /// rendered at init.
    @Published var activeFamily: ActiveSoundFamily {
        didSet {
            UserDefaults.standard.set(activeFamily.persistedID, forKey: Self.familyDefaultsKey)
        }
    }

    /// All families currently available — built-ins followed by any
    /// user samples discovered in the sounds folder. Recomputed when
    /// `reloadCustomSampleFamilies()` is called.
    @Published private(set) var allFamilies: [ActiveSoundFamily] = []

    /// Master volume for all sounds (0.0 ... 1.0). Defaults to 0.62
    /// which mirrors the preview-widget volume slider's default.
    @Published var masterVolume: Float {
        didSet {
            mixerNode.outputVolume = masterVolume
            UserDefaults.standard.set(masterVolume, forKey: Self.volumeDefaultsKey)
        }
    }

    private static let enabledDefaultsKey = "clicky.sounds.enabled"
    private static let familyDefaultsKey = "clicky.sounds.family"
    private static let volumeDefaultsKey = "clicky.sounds.volume"

    // MARK: - Audio plumbing

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode: AVAudioMixerNode
    private let sampleRate: Double = 48_000

    // v15p4cu (2026-06-01): idle-stop on Bluetooth output. A continuously
    // running output AVAudioEngine forces CoreAudio to open a Bluetooth
    // headset (AirPods) in HFP/call mode, which enables sidetone (Steph hears
    // his own voice fed back) and drops the AirPods to call-quality audio —
    // even when Clicky is idle and making no sound. Fix: when output is
    // Bluetooth, don't hold the engine warm. Start it on demand in play()
    // (already lazy) and stop it after a short idle window so the AirPods fall
    // back to A2DP. On built-in / wired output we keep the engine warm exactly
    // as before (no latency change where there was no problem).
    private var idleStopWorkItem: DispatchWorkItem?
    private static let bluetoothIdleStopDelaySeconds: Double = 2.5

    /// Built-in synthesized buffers — one set per built-in family.
    private var buffers: [ClickySoundFamily: [ClickySoundID: AVAudioPCMBuffer]] = [:]

    /// Custom sample-based buffers — outer key is the family name, inner
    /// maps a target frequency (Hz) to the resampled PCM. Custom
    /// families play by scheduling 1–N of these buffers at offsets
    /// defined by `customFamilyPatterns` (see end of file).
    private var customBuffers: [String: [Float: AVAudioPCMBuffer]] = [:]

    /// Audio format used for all pre-rendered buffers. Held so the
    /// custom-family reload path can re-render at the same rate/channels
    /// without re-deriving the format.
    private var audioFormat: AVAudioFormat!

    /// Public URL of the folder users drop sample files into. Created
    /// at engine init if missing; surfaced to the panel UI via a
    /// "Show sounds folder" button.
    let customSoundsDirectoryURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Clicky/Sounds")
    }()

    private init() {
        // Read persisted preferences (with sensible defaults).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledDefaultsKey) != nil {
            self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        } else {
            self.isEnabled = true
        }
        // Active-family selection — built-in OR custom. If a previously
        // saved custom family is now missing (file deleted between runs)
        // we silently fall back to tactile snap; the check happens after
        // custom families are loaded below.
        if let raw = defaults.string(forKey: Self.familyDefaultsKey),
           let parsed = ActiveSoundFamily.from(persistedID: raw) {
            self.activeFamily = parsed
        } else {
            self.activeFamily = .builtin(.tactileSnap)
        }
        if defaults.object(forKey: Self.volumeDefaultsKey) != nil {
            self.masterVolume = defaults.float(forKey: Self.volumeDefaultsKey)
        } else {
            self.masterVolume = 0.62
        }

        // Set up engine graph.
        self.mixerNode = engine.mainMixerNode
        engine.attach(playerNode)

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) ?? engine.outputNode.outputFormat(forBus: 0)
        self.audioFormat = format
        engine.connect(playerNode, to: mixerNode, format: format)

        mixerNode.outputVolume = masterVolume

        // Pre-render every built-in family×sound combination. ~30ms total
        // on an M-series Mac; happens off the critical path because this
        // is invoked during app delegate setup, not first sound playback.
        for family in ClickySoundFamily.allCases {
            var inner: [ClickySoundID: AVAudioPCMBuffer] = [:]
            for id in ClickySoundID.allCases {
                inner[id] = renderBuffer(family: family, id: id, format: format)
            }
            buffers[family] = inner
        }

        // Custom sample families — scan the sounds folder for .wav/.aif/
        // .aiff/.caf/.m4a files and render pitched variants for each.
        // Creates the folder if missing so users have a target to drop
        // files into.
        ensureCustomSoundsDirectoryExists()
        reloadCustomSampleFamilies()

        // If the persisted active family points to a custom family that
        // no longer exists on disk, fall back to tactile snap so we
        // don't silently play nothing.
        if case .custom(let name) = activeFamily, customBuffers[name] == nil {
            activeFamily = .builtin(.tactileSnap)
        }

        // Compute the unified families list — built-ins followed by
        // custom samples in alphabetical order.
        recomputeAllFamilies()

        // v15p4cu (2026-06-01): only hold the engine warm at launch when
        // output is NOT Bluetooth. On AirPods, a running engine pins HFP/call
        // mode (sidetone). play() lazy-starts the engine on demand, so leaving
        // it stopped here just means the first click on AirPods pays a small
        // start cost — acceptable to kill the constant feedback.
        if Self.defaultOutputDeviceUsesBluetoothTransport() {
            print("🔇 ClickySoundEngine: Bluetooth output at launch — engine left stopped (idle-stop mode)")
        } else {
            do {
                try engine.start()
                playerNode.play()
            } catch {
                print("⚠️ ClickySoundEngine: failed to start engine — \(error)")
            }
        }
    }

    /// v15p4cu (2026-06-01): true when the current default OUTPUT device is a
    /// Bluetooth transport (AirPods etc.). Mirrors the input-side check in
    /// BuddyDictationManager. Used to decide whether to idle-stop the engine.
    private static func defaultOutputDeviceUsesBluetoothTransport() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceIDStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceIDAddr, 0, nil, &deviceIDSize, &deviceID
        )
        guard deviceIDStatus == noErr, deviceID != 0 else { return false }

        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport
        )
        guard transportStatus == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// v15p4cu (2026-06-01): after a sound plays on Bluetooth output, schedule
    /// the engine to stop after a short idle window so the AirPods drop back to
    /// A2DP (killing sidetone). Any new play() within the window cancels and
    /// reschedules. No-op on non-Bluetooth output (engine stays warm).
    private func scheduleIdleStopIfBluetooth() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        guard Self.defaultOutputDeviceUsesBluetoothTransport() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.playerNode.isPlaying { self.playerNode.stop() }
            if self.engine.isRunning { self.engine.stop() }
        }
        idleStopWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bluetoothIdleStopDelaySeconds,
            execute: work
        )
    }

    // MARK: - Public API

    /// Play a sound effect for the given event. No-op when disabled or
    /// when audio engine setup failed. Thread-safe to call from the
    /// main actor; scheduleBuffer is non-blocking.
    ///
    /// For built-in families this schedules a single pre-rendered
    /// buffer. For custom families it schedules 1–N resampled variants
    /// at offsets defined in `Self.customFamilyPatterns`, using
    /// DispatchQueue.main.asyncAfter for the tiny inter-event delays
    /// (sub-100ms; perceptually identical to sample-accurate scheduling
    /// for interface sounds).
    func play(_ id: ClickySoundID) {
        guard isEnabled else { return }
        // v15p4cu: a new sound cancels any pending idle-stop so the engine
        // stays up across a burst of clicks.
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        if !engine.isRunning {
            try? engine.start()
            if !playerNode.isPlaying { playerNode.play() }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        defer { scheduleIdleStopIfBluetooth() }
        // v15p3dc (2026-05-15): use .interrupts on the FIRST buffer of
        // each play() call so rapid retriggers replace the current
        // playback instead of queueing behind it. Without this, clicking
        // a Marin engage cell three times in two seconds would queue
        // three buffers and play them serially over ~600ms — perceived
        // as "many sounds spread out really far." Subsequent events
        // within the same pattern (when a custom family ever uses
        // multi-event patterns again) use default [] options so they
        // layer correctly on top of the first event.
        switch activeFamily {
        case .builtin(let family):
            guard let buffer = buffers[family]?[id] else { return }
            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        case .custom(let name):
            guard let variants = customBuffers[name],
                  let pattern = Self.customFamilyPatterns[id] else { return }
            for (index, event) in pattern.enumerated() {
                guard let buf = variants[event.frequency] else { continue }
                let opts: AVAudioPlayerNodeBufferOptions = (index == 0) ? .interrupts : []
                if event.offsetMs <= 0 {
                    playerNode.scheduleBuffer(buf, at: nil, options: opts, completionHandler: nil)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (event.offsetMs / 1000.0)) { [weak self] in
                        self?.playerNode.scheduleBuffer(buf, at: nil, options: opts, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Preview a (family, sound) combination directly without changing
    /// the active family. Used by the Sound Preview matrix window so
    /// users can audition each family×moment cell from one place.
    ///
    /// Behavior matches `play(_:)` exactly otherwise — same scheduling,
    /// same custom-pattern dispatch, same enable-flag short-circuit.
    func preview(family: ActiveSoundFamily, id: ClickySoundID) {
        guard isEnabled else { return }
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        if !engine.isRunning {
            try? engine.start()
            if !playerNode.isPlaying { playerNode.play() }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        defer { scheduleIdleStopIfBluetooth() }
        // v15p3dc (2026-05-15): same .interrupts semantics as play().
        // The matrix preview window often gets rapid clicks while the
        // user A/B's families; .interrupts ensures each click replaces
        // the previous sound rather than queueing.
        switch family {
        case .builtin(let f):
            guard let buffer = buffers[f]?[id] else { return }
            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        case .custom(let name):
            guard let variants = customBuffers[name],
                  let pattern = Self.customFamilyPatterns[id] else { return }
            for (index, event) in pattern.enumerated() {
                guard let buf = variants[event.frequency] else { continue }
                let opts: AVAudioPlayerNodeBufferOptions = (index == 0) ? .interrupts : []
                if event.offsetMs <= 0 {
                    playerNode.scheduleBuffer(buf, at: nil, options: opts, completionHandler: nil)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (event.offsetMs / 1000.0)) { [weak self] in
                        self?.playerNode.scheduleBuffer(buf, at: nil, options: opts, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Re-scan the custom sounds folder and rebuild the variants for any
    /// changed/new/removed sample files. Called once at init and any
    /// time the user clicks "Reload" in the panel.
    func reloadCustomSampleFamilies() {
        customBuffers.removeAll(keepingCapacity: true)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: customSoundsDirectoryURL,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else {
            recomputeAllFamilies()
            return
        }
        let supportedExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
        for fileURL in contents.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let baseName = prettifySampleName(fileURL.deletingPathExtension().lastPathComponent)
            // v15p3cy (2026-05-15): a single source file can yield
            // multiple regions if it contains discrete events separated
            // by silence (light switch on+off, double-tap, etc.). Each
            // region becomes its own family in the picker; single-region
            // files keep their original base name with an empty suffix.
            guard let regionResults = renderCustomVariants(from: fileURL) else {
                print("⚠️ ClickySoundEngine: failed to load custom sample at \(fileURL.path)")
                continue
            }
            for result in regionResults {
                let familyName = baseName + result.suffix
                customBuffers[familyName] = result.variants
            }
        }
        // If the active family pointed at a now-missing custom, fall back.
        if case .custom(let name) = activeFamily, customBuffers[name] == nil {
            activeFamily = .builtin(.tactileSnap)
        }
        recomputeAllFamilies()
    }

    /// Open the custom sounds folder in Finder. Used by the panel
    /// "Show sounds folder" button so users can find the drop target
    /// without navigating into ~/Library by hand.
    func revealCustomSoundsFolderInFinder() {
        ensureCustomSoundsDirectoryExists()
        NSWorkspace.shared.activateFileViewerSelecting([customSoundsDirectoryURL])
    }

    // MARK: - Custom sample loading

    private func ensureCustomSoundsDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: customSoundsDirectoryURL.path) {
            try? fm.createDirectory(at: customSoundsDirectoryURL,
                                    withIntermediateDirectories: true,
                                    attributes: nil)
        }
    }

    private func recomputeAllFamilies() {
        let builtins = ClickySoundFamily.allCases.map { ActiveSoundFamily.builtin($0) }
        let customs = customBuffers.keys.sorted().map { ActiveSoundFamily.custom($0) }
        allFamilies = builtins + customs
    }

    /// "my-glass-tap" → "My glass tap". Cleans up filenames downloaded
    /// from stock libraries so they read nicely in the family picker.
    ///
    /// v15p3da (2026-05-15): added stock-suffix stripping and a length
    /// cap. Library files often end with IDs like
    /// "...-button-click-sound-463065" or "...-sound-effect-12345" —
    /// these get aggressive trimming so the picker doesn't blow out
    /// the panel width.
    ///
    /// Pipeline:
    ///   1. Replace separators (_, -) with spaces.
    ///   2. Drop trailing all-digit "tokens" (IDs like 463065).
    ///   3. Drop trailing stock-marketing words ("sound", "effect", "fx",
    ///      "audio", "sfx") that don't add meaning.
    ///   4. Trim whitespace, collapse double-spaces.
    ///   5. Cap at 30 chars with a trailing ellipsis.
    ///   6. Capitalize the first letter of the result.
    private func prettifySampleName(_ stem: String) -> String {
        var cleaned = stem.replacingOccurrences(of: "_", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "-", with: " ")
        var tokens = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let stockTrailingWords: Set<String> = [
            "sound", "sounds", "effect", "effects",
            "fx", "audio", "sfx", "loop", "wav",
            "sample", "clip"
        ]
        // 2 + 3. Strip trailing junk tokens (digit-only IDs OR stock words).
        while let last = tokens.last {
            let lower = last.lowercased()
            if lower.allSatisfy({ $0.isNumber }) {
                tokens.removeLast()
                continue
            }
            if stockTrailingWords.contains(lower) {
                tokens.removeLast()
                continue
            }
            break
        }
        var joined = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse any accidental double-spaces.
        while joined.contains("  ") {
            joined = joined.replacingOccurrences(of: "  ", with: " ")
        }
        // Length cap — 30 chars + ellipsis is enough for two-three words.
        let maxLen = 30
        if joined.count > maxLen {
            let cutoff = joined.index(joined.startIndex, offsetBy: maxLen)
            joined = String(joined[..<cutoff]).trimmingCharacters(in: .whitespaces) + "…"
        }
        guard !joined.isEmpty else { return stem }
        let first = joined.prefix(1).uppercased()
        let rest = joined.dropFirst()
        return first + rest
    }

    /// Load the audio file at `url`, mix to mono, split into regions
    /// (auto-detecting silence gaps so multi-event samples like a light
    /// switch's on+off recording become separate sub-samples), and
    /// render pitched variants for each region. Returns one entry per
    /// region — single-region files yield a single entry with empty
    /// suffix; multi-region files yield " 1", " 2", etc.
    ///
    /// Returns nil if the file can't be decoded.
    private func renderCustomVariants(from url: URL) -> [(suffix: String, variants: [Float: AVAudioPCMBuffer])]? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let srcFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return nil
        }
        do { try audioFile.read(into: srcBuffer) } catch { return nil }

        // Mix down to mono. Sample rate is preserved here; SR matching
        // happens in `resample()` below.
        guard let monoSource = mixToMono(srcBuffer) else { return nil }
        let sourceSR = srcFormat.sampleRate

        // v15p3cy (2026-05-15): auto-split files containing multiple
        // non-silent regions. Light-switch-style recordings (on-click,
        // gap, off-click) become two separate sub-samples — each
        // becomes its own family in the picker.
        let regions = splitIntoRegions(monoSource, sampleRate: sourceSR)
        guard !regions.isEmpty else { return nil }

        var output: [(suffix: String, variants: [Float: AVAudioPCMBuffer])] = []
        for (index, region) in regions.enumerated() {
            // Empty suffix when there's only one region — preserves the
            // pre-v15p3cy display name for the common case.
            let suffix: String = regions.count == 1 ? "" : " \(index + 1)"
            if let variants = renderVariants(from: region, sourceSampleRate: sourceSR) {
                output.append((suffix: suffix, variants: variants))
            }
        }
        return output.isEmpty ? nil : output
    }

    /// Render the 8 pitched variants of a single mono buffer. Pulled
    /// out of `renderCustomVariants` so it can be reused per-region
    /// after the splitter runs.
    private func renderVariants(from monoSource: AVAudioPCMBuffer,
                                sourceSampleRate: Double) -> [Float: AVAudioPCMBuffer]? {
        let targetFrequencies = Set<Float>(
            Self.customFamilyPatterns.values.flatMap { $0 }.map { $0.frequency }
        )
        let baseFrequency: Float = 523.25
        var variants: [Float: AVAudioPCMBuffer] = [:]
        for targetFreq in targetFrequencies {
            let pitchRatio = targetFreq / baseFrequency
            let combinedRatio = Float(sourceSampleRate / sampleRate) * pitchRatio
            if let resampled = resample(source: monoSource,
                                        rate: combinedRatio,
                                        targetFormat: audioFormat) {
                variants[targetFreq] = resampled
            }
        }
        return variants.isEmpty ? nil : variants
    }

    /// Split a mono buffer into non-silent regions. Used for sample
    /// files that contain multiple discrete events (e.g., a light-switch
    /// recording has the on-click + a pause + the off-click; this returns
    /// two buffers, one per click).
    ///
    /// Algorithm:
    ///   1. Find global peak amplitude.
    ///   2. Threshold: 2% of peak (conservative; -34 dBFS-equivalent).
    ///   3. For each 10ms window, mark loud iff its peak abs > threshold.
    ///   4. Group adjacent loud windows separated by < 150ms silence.
    ///   5. Each group is a region. Require ≥30ms length AND at least
    ///      one window above 10% of global peak (filters out decay tails
    ///      that briefly rise back above the 2% floor).
    ///   6. If a single region results, return [original]. If multiple,
    ///      slice each region into its own buffer with leading/trailing
    ///      silence trimmed.
    private func splitIntoRegions(_ buffer: AVAudioPCMBuffer,
                                  sampleRate sourceSR: Double) -> [AVAudioPCMBuffer] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        // 1. Global peak
        var peak: Float = 0
        for i in 0..<frames {
            let a = Swift.abs(data[i])
            if a > peak { peak = a }
        }
        // Silent / near-silent file → nothing to extract.
        guard peak > 0.01 else { return [] }

        let silenceThreshold = peak * 0.02
        let regionPeakThreshold = peak * 0.10

        // 2-3. Per-window max abs
        let windowSamples = Swift.max(1, Int(0.010 * sourceSR))  // 10ms
        let nWindows = frames / windowSamples
        guard nWindows > 0 else {
            // File shorter than 10ms — treat as single region.
            return [buffer]
        }
        var windowMaxAbs = [Float](repeating: 0, count: nWindows)
        for w in 0..<nWindows {
            let start = w * windowSamples
            let end = Swift.min(start + windowSamples, frames)
            var m: Float = 0
            for i in start..<end {
                let a = Swift.abs(data[i])
                if a > m { m = a }
            }
            windowMaxAbs[w] = m
        }

        // 4. Group adjacent loud windows separated by < 150ms silence.
        let minSilentWindows = Swift.max(1, Int(0.150 * sourceSR / Double(windowSamples)))
        let minRegionWindows = Swift.max(1, Int(0.030 * sourceSR / Double(windowSamples)))

        var regions: [(start: Int, end: Int, regionPeak: Float)] = []
        var i = 0
        while i < nWindows {
            // Skip leading silence
            while i < nWindows && windowMaxAbs[i] < silenceThreshold { i += 1 }
            if i >= nWindows { break }
            let regionStart = i
            var regionPeak: Float = 0
            // Extend region until we see ≥ minSilentWindows of silence
            while i < nWindows {
                if windowMaxAbs[i] >= silenceThreshold {
                    if windowMaxAbs[i] > regionPeak { regionPeak = windowMaxAbs[i] }
                    i += 1
                } else {
                    // Check whether silence here is long enough to end the region
                    var j = i
                    while j < nWindows && windowMaxAbs[j] < silenceThreshold {
                        j += 1
                    }
                    let silentRun = j - i
                    if silentRun >= minSilentWindows || j >= nWindows {
                        // Long silence (or end of file) — end region here
                        break
                    } else {
                        // Short silence inside the region — absorb and continue
                        i = j
                    }
                }
            }
            let regionEnd = i  // exclusive (first window past the region)
            if regionEnd - regionStart >= minRegionWindows && regionPeak >= regionPeakThreshold {
                regions.append((start: regionStart, end: regionEnd, regionPeak: regionPeak))
            }
        }

        // 5. Single region → return original buffer as-is (avoids
        // unnecessary copying for normal samples).
        if regions.count <= 1 { return [buffer] }

        // 6. Slice each region into its own buffer
        var out: [AVAudioPCMBuffer] = []
        for region in regions {
            let startFrame = region.start * windowSamples
            let endFrame = Swift.min(region.end * windowSamples, frames)
            let regionFrames = endFrame - startFrame
            if regionFrames < 100 { continue }
            guard let regionBuf = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: AVAudioFrameCount(regionFrames)
            ) else { continue }
            regionBuf.frameLength = AVAudioFrameCount(regionFrames)
            let outData = regionBuf.floatChannelData![0]
            for k in 0..<regionFrames {
                outData[k] = data[startFrame + k]
            }
            out.append(regionBuf)
        }
        return out.isEmpty ? [buffer] : out
    }

    /// Mix down to mono. For stereo files this averages L+R; for already-
    /// mono files it just returns the input. The returned buffer uses
    /// the SOURCE format (not the engine format) — sample-rate matching
    /// happens later in `resample()`.
    private func mixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let srcData = buffer.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if channels == 1 { return buffer }
        // Build a mono format at the SAME sample rate as the source.
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: buffer.format.sampleRate,
            channels: 1
        ),
        let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                   frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        out.frameLength = buffer.frameLength
        let outData = out.floatChannelData![0]
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += srcData[c][i] }
            outData[i] = sum / Float(channels)
        }
        return out
    }

    /// Resample `source` by reading samples at a non-integer rate.
    /// `rate > 1.0` shortens (pitch up); `rate < 1.0` lengthens (pitch
    /// down). Linear interpolation — fine for short percussive samples,
    /// would want sinc/polyphase for long melodic pitched material but
    /// that's overkill here.
    private func resample(source: AVAudioPCMBuffer,
                          rate: Float,
                          targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard rate > 0,
              let srcData = source.floatChannelData?[0] else { return nil }
        let srcLen = Int(source.frameLength)
        let outLen = max(1, Int(Float(srcLen) / rate))
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(outLen)) else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(outLen)
        let outData = out.floatChannelData![0]
        for i in 0..<outLen {
            let srcPos = Float(i) * rate
            let srcIdx = Int(srcPos)
            let frac = srcPos - Float(srcIdx)
            if srcIdx + 1 < srcLen {
                outData[i] = srcData[srcIdx] * (1 - frac) + srcData[srcIdx + 1] * frac
            } else if srcIdx < srcLen {
                outData[i] = srcData[srcIdx]
            } else {
                outData[i] = 0
            }
        }
        return out
    }

    /// 9-moment pattern for custom sample families.
    ///
    /// v15p3cz (2026-05-15): switched from pair-based (C5+E5, C5+G5,
    /// etc.) to single-event-per-moment. For SYNTHESIZED tones, pair
    /// patterns are melodically pleasing — you hear two notes from the
    /// same voice. For SAMPLE sounds, pair patterns played the user's
    /// recorded file TWICE in quick succession at different pitches,
    /// which doesn't read as "two notes" but as "the file repeated
    /// itself." Steph reported this as "I hear both sounds" while
    /// using a single-click sample.
    ///
    /// New design: each moment fires the sample ONCE at a moment-
    /// specific pitch. Identity comes from frequency assignment
    /// alone — same idea as the "single tones" built-in family.
    /// Frequencies span ~3 octaves (C3 to B5) so low-thud errors and
    /// bright-high success chimes still feel distinct from each other.
    private static let customFamilyPatterns: [ClickySoundID: [(frequency: Float, offsetMs: Double)]] = [
        .vttStart:        [(523.25, 0)],    // C5  — neutral mid
        .vttSuccess:      [(783.99, 0)],    // G5  — higher / brighter
        .vttError:        [(196.00, 0)],    // G3  — low / dim
        .marinEngage:     [(659.25, 0)],    // E5  — engaged mid-high
        .marinDisengage:  [(440.00, 0)],    // A4  — settled lower
        .polishStart:     [(523.25, 0)],    // C5  — start of polish
        .polishDone:      [(987.77, 0)],    // B5  — bright completion
        .visionCapture:   [(130.81, 0)],    // C3  — low, weighty shutter
        .genericError:    [(220.00, 0)]     // A3  — low error
    ]

    // MARK: - Synthesis dispatch

    /// Top-level renderer — picks the right family-specific helper and
    /// composes the 9 patterns into a single PCM buffer per (family, id).
    private func renderBuffer(
        family: ClickySoundFamily,
        id: ClickySoundID,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        // 300ms is enough headroom for the longest pattern in any
        // family (currently ~210ms for plucked string Marin engage).
        let totalSamples = AVAudioFrameCount(0.30 * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalSamples)!
        buffer.frameLength = totalSamples
        let out = buffer.floatChannelData![0]
        let totalLen = Int(totalSamples)
        for i in 0..<totalLen { out[i] = 0 }

        switch family {
        case .tactileSnap: renderTactileSnap(into: out, totalLen: totalLen, id: id)
        }

        // Soft clip to keep mixed sums in [-1, 1] just in case
        // pattern math overshoots (unlikely with our gains, but cheap).
        for i in 0..<totalLen {
            let s = out[i]
            if s > 1.0 { out[i] = 1.0 }
            else if s < -1.0 { out[i] = -1.0 }
        }
        return buffer
    }

    // MARK: - Note frequencies (shared across families)

    private struct Note {
        static let C3: Float = 130.81
        static let G3: Float = 196.00
        static let A3: Float = 220.00
        static let C5: Float = 523.25
        static let E5: Float = 659.25
        static let G5: Float = 783.99
        static let A5: Float = 880.00
        static let C6: Float = 1046.50
    }

    // MARK: - Tactile snap family

    private func renderTactileSnap(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 55)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.035, freq: Note.E5, decayMs: 75)
        case .vttSuccess:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.E5, decayMs: 55)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.035, freq: Note.C5, decayMs: 85)
        case .vttError:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G3, decayMs: 110, gain: 0.36)
        case .marinEngage:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 60)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.G5, decayMs: 100)
        case .marinDisengage:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 60)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.C5, decayMs: 100)
        case .polishStart:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 80)
        case .polishDone:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A5, decayMs: 50)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.035, freq: Note.C6, decayMs: 80)
        case .visionCapture:
            bandpassedNoise(into: out, totalLen: totalLen, startSec: 0,
                            durMs: 14, freq: 2200, q: 2.0, gain: 0.16)
            tactileNote(into: out, totalLen: totalLen, startSec: 0.003,
                        freq: Note.C3, decayMs: 45, gain: 0.18)
        case .genericError:
            tactileNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A3, decayMs: 110, gain: 0.34)
        }
    }

    /// Tactile-snap voice: 11ms bandpassed noise transient + sine body
    /// with linear attack + exponential decay. Mirrors the JS recipe
    /// `tactileNote()` from the preview widget.
    private func tactileNote(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        freq: Float,
        decayMs: Float,
        gain: Float = 0.34
    ) {
        let startSample = Int(startSec * sampleRate)
        // Noise transient (11ms shaped with (1-t)^2 envelope, bandpassed at min(freq*3, 3200), Q=2.8)
        let noiseDurSec = 0.011
        let noiseLen = Int(noiseDurSec * sampleRate)
        var noise = [Float](repeating: 0, count: noiseLen)
        for i in 0..<noiseLen {
            let t = Float(i) / Float(noiseLen)
            let env = pow(1.0 - t, Float(2.0))
            noise[i] = Float.random(in: -1...1) * env
        }
        let bpFreq = min(freq * 3, 3200)
        let filtered = biquadBandpass(noise, freq: bpFreq, q: 2.8)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: 0.22)

        // Sine body — starts 5ms after the transient
        let bodyOffsetSamples = Int(0.005 * sampleRate)
        renderSineExpEnv(
            into: out,
            totalLen: totalLen,
            startSample: startSample + bodyOffsetSamples,
            freq: freq,
            attackMs: 1,
            decayMs: decayMs,
            peakGain: gain
        )
    }

    // MARK: - Pencil tap family
    //
    // v15p3cw (2026-05-15): same 9-pattern musical skeleton as tactile
    // snap, but with a tighter, drier voice — much smaller noise
    // transient (4ms vs 11ms) and a quieter sine body. Reads as the
    // "single-event sibling" of tactile snap, which is exactly the
    // texture Steph picked from the browse widget.

    private func renderPencilTap(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 70)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.040, freq: Note.E5, decayMs: 90)
        case .vttSuccess:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.E5, decayMs: 70)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.040, freq: Note.C5, decayMs: 100)
        case .vttError:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G3, decayMs: 130, gain: 0.38)
        case .marinEngage:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 75)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.G5, decayMs: 110)
        case .marinDisengage:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 75)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.C5, decayMs: 110)
        case .polishStart:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 90)
        case .polishDone:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A5, decayMs: 60)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.040, freq: Note.C6, decayMs: 90)
        case .visionCapture:
            bandpassedNoise(into: out, totalLen: totalLen, startSec: 0,
                            durMs: 6, freq: 2800, q: 2.5, gain: 0.18)
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0.003,
                          freq: Note.C3, decayMs: 50, gain: 0.20)
        case .genericError:
            pencilTapNote(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A3, decayMs: 130, gain: 0.38)
        }
    }

    /// Pencil-tap voice — small 4ms bandpassed noise transient + sine
    /// body. The transient lives near 2800Hz (the "tap" character);
    /// the body uses the standard sine + exp-decay envelope.
    private func pencilTapNote(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        freq: Float,
        decayMs: Float,
        gain: Float = 0.34
    ) {
        let startSample = Int(startSec * sampleRate)
        // 4ms shaped noise transient — much shorter than tactile snap's
        // 11ms — gives the "pencil on desk" character.
        let noiseLen = Int(0.004 * sampleRate)
        var noise = [Float](repeating: 0, count: noiseLen)
        for i in 0..<noiseLen {
            let t = Float(i) / Float(noiseLen)
            let env = pow(1.0 - t, Float(2.0))
            noise[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadBandpass(noise, freq: 2800, q: 2.5)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: 0.26)
        // Pitched body, 2ms after the tap
        let bodyOffsetSamples = Int(0.002 * sampleRate)
        renderSineExpEnv(
            into: out,
            totalLen: totalLen,
            startSample: startSample + bodyOffsetSamples,
            freq: freq,
            attackMs: 1,
            decayMs: decayMs,
            peakGain: gain
        )
    }

    // MARK: - Single tones family
    //
    // v15p3cw (2026-05-15): one pure sine note per moment. No pairs,
    // no chords, no transients. Distinct frequency per moment carries
    // the semantic identity. Minimalist UI-sound design — closest to
    // Notion / Arc aesthetic.

    private func renderSingleTones(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:        singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.C5,  decayMs: 90,  gain: 0.42)
        case .vttSuccess:      singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G5,  decayMs: 110, gain: 0.42)
        case .vttError:        singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G3,  decayMs: 160, gain: 0.36)
        case .marinEngage:     singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.E5,  decayMs: 130, gain: 0.44)
        case .marinDisengage:  singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 440,      decayMs: 130, gain: 0.44)  // A4
        case .polishStart:     singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 370,      decayMs: 100, gain: 0.40)  // F#4
        case .polishDone:      singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 988,      decayMs: 100, gain: 0.42)  // B5
        case .visionCapture:
            bandpassedNoise(into: out, totalLen: totalLen, startSec: 0,
                            durMs: 20, freq: 2200, q: 2.0, gain: 0.18)
        case .genericError:    singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.A3,  decayMs: 160, gain: 0.36)
        }
    }

    /// One pure sine note, attack 2ms, exp decay. Used by both
    /// single-tones (one per moment) and chord-stabs (stacked).
    private func singleSine(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        freq: Float,
        decayMs: Float,
        gain: Float
    ) {
        let startSample = Int(startSec * sampleRate)
        renderSineExpEnv(
            into: out,
            totalLen: totalLen,
            startSample: startSample,
            freq: freq,
            attackMs: 2,
            decayMs: decayMs,
            peakGain: gain
        )
    }

    // MARK: - Chord stabs family
    //
    // v15p3cw (2026-05-15): simultaneous sine stacks. Each moment is a
    // chord (major, minor, dim, open fifth, etc.) — harmony carries
    // identity rather than melodic motion. Notes ring together, not in
    // sequence.

    private func renderChordStabs(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            // C major (C-E-G)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.C5, decayMs: 110, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.E5, decayMs: 110, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G5, decayMs: 110, gain: 0.30)
        case .vttSuccess:
            // Cmaj7 (C-E-G-B) — brighter resolution chord
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.C5, decayMs: 130, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.E5, decayMs: 130, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G5, decayMs: 130, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 988,     decayMs: 130, gain: 0.24)  // B5
        case .vttError:
            // A3 + C4 minor third — small dark interval
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 220, decayMs: 180, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 262, decayMs: 180, gain: 0.28)
        case .marinEngage:
            // G-C-E open voicing — engaged, lifted
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 392,     decayMs: 150, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.C5, decayMs: 150, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.E5, decayMs: 150, gain: 0.28)
        case .marinDisengage:
            // Same chord, octave lower — resolves down
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G3, decayMs: 150, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 262,     decayMs: 150, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 330,     decayMs: 150, gain: 0.28)
        case .polishStart:
            // E-G open third
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.E5, decayMs: 120, gain: 0.32)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.G5, decayMs: 120, gain: 0.32)
        case .polishDone:
            // F-A-C bright major
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 698,      decayMs: 120, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.A5,  decayMs: 120, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: Note.C6,  decayMs: 120, gain: 0.28)
        case .visionCapture:
            bandpassedNoise(into: out, totalLen: totalLen, startSec: 0,
                            durMs: 18, freq: 1800, q: 2.0, gain: 0.16)
            singleSine(into: out, totalLen: totalLen, startSec: 0.002,
                       freq: Note.C3, decayMs: 60, gain: 0.20)
        case .genericError:
            // B-D-F diminished — tense
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 247, decayMs: 180, gain: 0.30)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 294, decayMs: 180, gain: 0.28)
            singleSine(into: out, totalLen: totalLen, startSec: 0, freq: 349, decayMs: 180, gain: 0.28)
        }
    }

    // MARK: - Retired families (drum / mouth click / plucked string)
    //
    // v15p3cw (2026-05-15): removed. Steph never gravitated to these
    // during the family-picker browse arc; the four families above
    // (tactile snap, pencil tap, single tones, chord stabs) are his
    // curated shortlist. Old UserDefaults raw values silently fall
    // back to tactile snap via the loader's rawValue match check.

    // (Drum / mouth click / plucked string renderers removed — see retirement note above.)
    // The orphaned block below is no longer referenced from anywhere. Kept commented
    // out in source history via git; deleted from the live file for clarity.
    /* RETIRED v15p3cw — DO NOT REINSTATE WITHOUT ADDING ENUM CASES BACK
    private func _retired_renderDrumPercussion(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            hat(into: out, totalLen: totalLen, startSec: 0,     decayMs: 22)
            kick(into: out, totalLen: totalLen, startSec: 0.030, decayMs: 70, startFreq: 150, endFreq: 50)
        case .vttSuccess:
            kick(into: out, totalLen: totalLen, startSec: 0,     decayMs: 70, startFreq: 150, endFreq: 50)
            hat(into: out, totalLen: totalLen, startSec: 0.040, decayMs: 22)
        case .vttError:
            kick(into: out, totalLen: totalLen, startSec: 0,     decayMs: 160, startFreq: 90, endFreq: 35, gain: 0.55)
        case .marinEngage:
            kick(into: out, totalLen: totalLen, startSec: 0,     decayMs: 80, startFreq: 130, endFreq: 45)
            snap(into: out, totalLen: totalLen, startSec: 0.060, decayMs: 60, gain: 0.30)
        case .marinDisengage:
            snap(into: out, totalLen: totalLen, startSec: 0,     decayMs: 60, gain: 0.30)
            kick(into: out, totalLen: totalLen, startSec: 0.060, decayMs: 80, startFreq: 130, endFreq: 45)
        case .polishStart:
            snap(into: out, totalLen: totalLen, startSec: 0,     decayMs: 70, gain: 0.32)
        case .polishDone:
            hat(into: out, totalLen: totalLen, startSec: 0,     decayMs: 30)
            hat(into: out, totalLen: totalLen, startSec: 0.050, decayMs: 25)
        case .visionCapture:
            hat(into: out, totalLen: totalLen, startSec: 0,     decayMs: 18)
        case .genericError:
            kick(into: out, totalLen: totalLen, startSec: 0,     decayMs: 200, startFreq: 75, endFreq: 30, gain: 0.50)
        }
    }

    /// Kick drum — sine with exponential pitch sweep + amplitude decay.
    private func kick(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        decayMs: Float,
        startFreq: Float,
        endFreq: Float,
        gain: Float = 0.5
    ) {
        let startSample = Int(startSec * sampleRate)
        let decaySec = Double(decayMs) / 1000
        let bodyLen = Int((decaySec + 0.02) * sampleRate)
        let tauSec = decaySec / 5.0
        let pitchSweepEnd = startSec + decaySec * 0.7

        var phase: Float = 0
        for i in 0..<bodyLen {
            let t = Double(i) / sampleRate
            // Exponential pitch sweep from startFreq to endFreq over 70% of decay
            let elapsedSec = t
            let sweepProgress = min(1.0, elapsedSec / (decaySec * 0.7))
            let freq: Float
            if sweepProgress < 1.0 {
                let ratio = endFreq / startFreq
                freq = startFreq * pow(ratio, Float(sweepProgress))
            } else {
                freq = endFreq
            }
            let phaseInc = 2 * Float.pi * freq / Float(sampleRate)
            // Amplitude envelope (instant attack, exp decay)
            let env = gain * Float(exp(-t / tauSec))
            let idx = startSample + i
            if idx >= 0 && idx < totalLen {
                out[idx] += sin(phase) * env
            }
            phase += phaseInc
        }
        _ = pitchSweepEnd  // suppress unused-var on bodyLen-shortened cases
    }

    /// Snare-like "snap" — bandpassed noise burst around 2800Hz.
    private func snap(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        decayMs: Float,
        gain: Float = 0.30
    ) {
        let startSample = Int(startSec * sampleRate)
        let lenSamples = Int(Double(decayMs) / 1000 * sampleRate)
        var noise = [Float](repeating: 0, count: lenSamples)
        for i in 0..<lenSamples {
            let t = Float(i) / Float(lenSamples)
            let env = exp(-t * 5.0)  // exponential decay
            noise[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadBandpass(noise, freq: 2800, q: 2.0)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: gain)
    }

    /// Hi-hat — highpassed noise burst (essentially the high-frequency portion only).
    private func hat(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        decayMs: Float,
        gain: Float = 0.22
    ) {
        let startSample = Int(startSec * sampleRate)
        let lenSamples = Int(Double(decayMs) / 1000 * sampleRate)
        var noise = [Float](repeating: 0, count: lenSamples)
        for i in 0..<lenSamples {
            let t = Float(i) / Float(lenSamples)
            let env = exp(-t * 6.0)
            noise[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadHighpass(noise, freq: 7000, q: 0.7)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: gain)
    }

    // MARK: - Mouth click family

    private func renderMouthClick(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 2400, pitch: 600, pitchEnd: 800, decayMs: 60)
        case .vttSuccess:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 2400, pitch: 800, pitchEnd: 600, decayMs: 70)
        case .vttError:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 1100, pitch: 280, pitchEnd: 200, decayMs: 130, gain: 0.42)
        case .marinEngage:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0,     clickFreq: 1800, pitch: 500, decayMs: 55)
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0.060, clickFreq: 2400, pitch: 700, pitchEnd: 950, decayMs: 90)
        case .marinDisengage:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0,     clickFreq: 2400, pitch: 950, pitchEnd: 700, decayMs: 70)
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0.060, clickFreq: 1800, pitch: 500, decayMs: 90)
        case .polishStart:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 2200, pitch: 700, decayMs: 70)
        case .polishDone:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0,     clickFreq: 2800, pitch: 900, decayMs: 40)
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0.050, clickFreq: 2600, pitch: 800, decayMs: 55)
        case .visionCapture:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 3000, pitch: 1100, decayMs: 35, gain: 0.30)
        case .genericError:
            mouthClickEvent(into: out, totalLen: totalLen, startSec: 0, clickFreq: 900, pitch: 220, pitchEnd: 160, decayMs: 150, gain: 0.42)
        }
    }

    /// Sharp 7ms bandpassed noise click + tiny pitched sine body. The
    /// click frequency controls the "k/t/p" character; the body adds
    /// just enough resonance to feel like a mouth cavity.
    private func mouthClickEvent(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        clickFreq: Float,
        pitch: Float,
        pitchEnd: Float? = nil,
        decayMs: Float,
        gain: Float = 0.36
    ) {
        let startSample = Int(startSec * sampleRate)

        // 7ms click transient
        let clickLen = Int(0.007 * sampleRate)
        var clickNoise = [Float](repeating: 0, count: clickLen)
        for i in 0..<clickLen {
            let t = Float(i) / Float(clickLen)
            let env = pow(1.0 - t, Float(1.8))
            clickNoise[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadBandpass(clickNoise, freq: clickFreq, q: 3.5)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: 0.32)

        // Pitched body — starts 4ms after click
        let bodyOffsetSamples = Int(0.004 * sampleRate)
        renderSineExpEnvGlide(
            into: out,
            totalLen: totalLen,
            startSample: startSample + bodyOffsetSamples,
            pitchStart: pitch,
            pitchEnd: pitchEnd ?? pitch,
            attackMs: 2,
            decayMs: decayMs,
            peakGain: gain
        )
    }

    // MARK: - Plucked string family

    private func renderPluckedString(into out: UnsafeMutablePointer<Float>, totalLen: Int, id: ClickySoundID) {
        switch id {
        case .vttStart:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 130)
            pluckEvent(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.E5, decayMs: 160)
        case .vttSuccess:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.E5, decayMs: 130)
            pluckEvent(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.C5, decayMs: 180)
        case .vttError:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G3, decayMs: 240, gain: 0.40)
        case .marinEngage:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C5, decayMs: 140)
            pluckEvent(into: out, totalLen: totalLen, startSec: 0.070, freq: Note.G5, decayMs: 200)
        case .marinDisengage:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 140)
            pluckEvent(into: out, totalLen: totalLen, startSec: 0.070, freq: Note.C5, decayMs: 200)
        case .polishStart:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.G5, decayMs: 180)
        case .polishDone:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A5, decayMs: 120)
            pluckEvent(into: out, totalLen: totalLen, startSec: 0.050, freq: Note.C6, decayMs: 180)
        case .visionCapture:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.C6, decayMs: 80, gain: 0.35)
        case .genericError:
            pluckEvent(into: out, totalLen: totalLen, startSec: 0,     freq: Note.A3, decayMs: 240, gain: 0.40)
        }
    }

    /// Plucked-string voice — short bandpassed noise transient (the
    /// "pluck") + sine + 2nd + triangle 3rd harmonic body with a
    /// two-stage envelope (fast initial decay then slow tail).
    private func pluckEvent(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        freq: Float,
        decayMs: Float,
        gain: Float = 0.42
    ) {
        let startSample = Int(startSec * sampleRate)

        // 8ms pluck transient through bandpass at freq * 4
        let pluckLen = Int(0.008 * sampleRate)
        var pluck = [Float](repeating: 0, count: pluckLen)
        for i in 0..<pluckLen {
            let t = Float(i) / Float(pluckLen)
            let env = pow(1.0 - t, Float(2.0))
            pluck[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadBandpass(pluck, freq: freq * 4, q: 3.0)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: 0.22)

        // Stacked body — sine fundamental + 2nd harmonic sine + 3rd
        // harmonic triangle. Two-stage envelope: fast 4ms attack to
        // peak, fast 28ms decay to 35%, then slow exp decay over
        // decayMs to silence.
        let bodyDecaySec = Double(decayMs) / 1000
        let bodyLen = Int((bodyDecaySec + 0.04) * sampleRate)
        let attackSec = 0.004
        let earlyDecaySec = 0.028
        let earlyPeakRatio: Float = 0.35
        let tailTauSec = bodyDecaySec / 5.0
        let phaseInc1 = 2 * Float.pi * freq / Float(sampleRate)
        let phaseInc2 = 2 * Float.pi * (freq * 2) / Float(sampleRate)
        let phaseInc3 = 2 * Float.pi * (freq * 3) / Float(sampleRate)
        var p1: Float = 0, p2: Float = 0, p3: Float = 0
        let amp1: Float = 1.0
        let amp2: Float = 0.55
        let amp3: Float = 0.12
        for i in 0..<bodyLen {
            let t = Double(i) / sampleRate
            let envCore: Float
            if t < attackSec {
                envCore = Float(t / attackSec)
            } else if t < attackSec + earlyDecaySec {
                let progress = Float((t - attackSec) / earlyDecaySec)
                envCore = 1.0 - progress * (1.0 - earlyPeakRatio)
            } else {
                let dt = t - attackSec - earlyDecaySec
                envCore = earlyPeakRatio * Float(exp(-dt / tailTauSec))
            }
            let env = envCore * gain
            let triangle3 = (2.0 / Float.pi) * asin(sin(p3))
            let sample = sin(p1) * amp1 + sin(p2) * amp2 + triangle3 * amp3
            // Cheap lowpass approximation: just leave as-is; harmonics
            // are already moderate-amplitude. Saves a per-sample IIR
            // pass with negligible audible difference for this voice.
            let idx = startSample + i
            if idx >= 0 && idx < totalLen {
                // Normalize body sum back into roughly [-1, 1] before applying env
                out[idx] += (sample / (amp1 + amp2 + amp3)) * env
            }
            p1 += phaseInc1
            p2 += phaseInc2
            p3 += phaseInc3
        }
    }
    END RETIRED v15p3cw */

    // MARK: - Shared helpers

    /// Renders sin(2π·freq·t) with a linear-attack / exponential-decay
    /// envelope mirroring Web Audio's `exponentialRampToValueAtTime`
    /// pair (epsilon → peak in attackMs, peak → epsilon over decayMs).
    private func renderSineExpEnv(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSample: Int,
        freq: Float,
        attackMs: Float,
        decayMs: Float,
        peakGain: Float
    ) {
        let attackSec = Double(attackMs) / 1000
        let decaySec = Double(decayMs) / 1000
        let bodyLen = Int((attackSec + decaySec + 0.04) * sampleRate)
        let tauSec = decaySec / 5.0
        let phaseInc = 2 * Float.pi * freq / Float(sampleRate)
        var phase: Float = 0
        for i in 0..<bodyLen {
            let t = Double(i) / sampleRate
            let env: Float
            if t < attackSec {
                env = peakGain * Float(t / attackSec)
            } else {
                env = peakGain * Float(exp(-(t - attackSec) / tauSec))
            }
            let idx = startSample + i
            if idx >= 0 && idx < totalLen {
                out[idx] += sin(phase) * env
            }
            phase += phaseInc
        }
    }

    /// Same as `renderSineExpEnv` but with a frequency glide from
    /// `pitchStart` to `pitchEnd` over the full decay window.
    /// Used by the mouth-click voice for its pitched body's micro-bend.
    private func renderSineExpEnvGlide(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSample: Int,
        pitchStart: Float,
        pitchEnd: Float,
        attackMs: Float,
        decayMs: Float,
        peakGain: Float
    ) {
        let attackSec = Double(attackMs) / 1000
        let decaySec = Double(decayMs) / 1000
        let bodyLen = Int((attackSec + decaySec + 0.04) * sampleRate)
        let tauSec = decaySec / 5.0
        var phase: Float = 0
        let totalGlideSec = attackSec + decaySec
        for i in 0..<bodyLen {
            let t = Double(i) / sampleRate
            let progress = min(1.0, t / totalGlideSec)
            let ratio = pitchEnd / pitchStart
            let freq = pitchStart * pow(ratio, Float(progress))
            let phaseInc = 2 * Float.pi * freq / Float(sampleRate)
            let env: Float
            if t < attackSec {
                env = peakGain * Float(t / attackSec)
            } else {
                env = peakGain * Float(exp(-(t - attackSec) / tauSec))
            }
            let idx = startSample + i
            if idx >= 0 && idx < totalLen {
                out[idx] += sin(phase) * env
            }
            phase += phaseInc
        }
    }

    /// Standalone bandpassed noise burst (used for vision-capture shutter).
    private func bandpassedNoise(
        into out: UnsafeMutablePointer<Float>,
        totalLen: Int,
        startSec: Double,
        durMs: Float,
        freq: Float,
        q: Float,
        gain: Float
    ) {
        let startSample = Int(startSec * sampleRate)
        let lenSamples = Int(Double(durMs) / 1000 * sampleRate)
        var noise = [Float](repeating: 0, count: lenSamples)
        for i in 0..<lenSamples {
            let t = Float(i) / Float(lenSamples)
            let env = pow(1.0 - t, Float(1.5))
            noise[i] = Float.random(in: -1...1) * env
        }
        let filtered = biquadBandpass(noise, freq: freq, q: q)
        mix(filtered, into: out, at: startSample, totalLen: totalLen, gain: gain)
    }

    /// Adds an input buffer into the output buffer at a given offset,
    /// scaled by `gain`. Clamps to output bounds to avoid overruns.
    private func mix(
        _ input: [Float],
        into out: UnsafeMutablePointer<Float>,
        at startSample: Int,
        totalLen: Int,
        gain: Float
    ) {
        for i in 0..<input.count {
            let idx = startSample + i
            if idx >= 0 && idx < totalLen {
                out[idx] += input[i] * gain
            }
        }
    }

    /// Single-pass biquad bandpass (RBJ cookbook constant-skirt form).
    private func biquadBandpass(_ input: [Float], freq: Float, q: Float) -> [Float] {
        let omega = 2 * Float.pi * freq / Float(sampleRate)
        let cosO = cos(omega)
        let sinO = sin(omega)
        let alpha = sinO / (2 * q)
        let b0 = alpha
        let b2 = -alpha
        let a0 = 1 + alpha
        let a1 = -2 * cosO
        let a2 = 1 - alpha
        let nb0 = b0 / a0
        let nb2 = b2 / a0
        let na1 = a1 / a0
        let na2 = a2 / a0
        var out = [Float](repeating: 0, count: input.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = nb0 * x0 + nb2 * x2 - na1 * y1 - na2 * y2
            out[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return out
    }

    /// Single-pass biquad highpass (RBJ cookbook).
    private func biquadHighpass(_ input: [Float], freq: Float, q: Float) -> [Float] {
        let omega = 2 * Float.pi * freq / Float(sampleRate)
        let cosO = cos(omega)
        let sinO = sin(omega)
        let alpha = sinO / (2 * q)
        let b0 = (1 + cosO) / 2
        let b1 = -(1 + cosO)
        let b2 = (1 + cosO) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosO
        let a2 = 1 - alpha
        let nb0 = b0 / a0
        let nb1 = b1 / a0
        let nb2 = b2 / a0
        let na1 = a1 / a0
        let na2 = a2 / a0
        var out = [Float](repeating: 0, count: input.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<input.count {
            let x0 = input[i]
            let y0 = nb0 * x0 + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            out[i] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return out
    }
}
