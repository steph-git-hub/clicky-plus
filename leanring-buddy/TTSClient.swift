//
//  TTSClient.swift
//  leanring-buddy
//
//  Protocol + factory for swappable TTS backends.
//
//  Current providers:
//    • ElevenLabs (via Cloudflare Worker /tts)
//    • Grok / xAI  (via Cloudflare Worker /tts-grok)
//
//  The active provider is chosen from UserDefaults key "TTSProvider".
//  Valid values: "elevenlabs" or "grok". Default: "grok".
//
//  Swap back from Terminal (use the ACTUAL runtime bundle id, not the
//  legacy one — UserDefaults.standard reads from com.stephenpierson.clickyplus):
//    defaults write com.stephenpierson.clickyplus TTSProvider elevenlabs
//    (then relaunch the app)
//
//  Swap forward:
//    defaults write com.stephenpierson.clickyplus TTSProvider grok
//

import AVFoundation
import Foundation

@MainActor
protocol TTSClient: AnyObject {
    func speakText(_ text: String) async throws
    var isPlaying: Bool { get }
    func stopPlayback()
}

// MARK: - LocalVoiceboxTTSClient
//
// TTS client backed by Voicebox.app, an open-source local-first voice
// synthesis app (https://github.com/jamiepine/voicebox). Voicebox runs
// a REST API on localhost:17493 with 7 bundled TTS engines (Kokoro,
// Qwen3-TTS, Chatterbox, etc.) and 50+ preset voices.
//
// Compared to ElevenLabs/Grok TTS:
//   • Free (no per-character cost or subscription)
//   • Private (audio never leaves the Mac, no network round-trip)
//   • Offline-capable (no internet required)
//   • Roughly comparable speed for short utterances (~1.5s for ~10s of
//     audio via Kokoro on Apple Silicon) — no streaming chunks like
//     ElevenLabs, so longer replies may feel slower
//
// Hard dependency: Voicebox.app must be running for this client to work.
// If it's not running, speakText throws and the caller's error path
// (in CompanionManager) handles it. Swap back to ElevenLabs via:
//   defaults write com.stephenpierson.clickyplus TTSProvider elevenlabs

@MainActor
final class LocalVoiceboxTTSClient: NSObject, TTSClient, AVAudioPlayerDelegate {

    /// Endpoint that returns synthesized audio bytes synchronously
    /// (instead of the async-job pattern of /speak). Voicebox's docs:
    /// "Generate speech and stream the WAV audio directly without
    /// saving to disk."
    private let voiceboxStreamSpeechEndpointURL: URL

    /// Voicebox profile id to use for synthesis. Voicebox stores
    /// profiles as UUIDs after the user creates them in the app's UI.
    /// Steph picked "Heart" 2026-04-26 with id 19339383-1422-4181-b858-f8985a0e8925.
    private let voiceboxProfileId: String

    /// TTS engine name. Profiles in Voicebox are tied to a specific
    /// engine (e.g. Kokoro presets only support kokoro). The default
    /// API engine is qwen, so we pass this explicitly to override.
    private let voiceboxEngineName: String

    /// Active audio player for the most recent synthesis. Held so we
    /// can stop playback mid-stream when a new interaction starts.
    private var currentAudioPlayer: AVAudioPlayer?

    /// Continuation that resolves when AVAudioPlayer finishes playing
    /// the current utterance. speakText awaits this so callers can
    /// chain async behavior on completion.
    private var currentPlaybackContinuation: CheckedContinuation<Void, Error>?

    var isPlaying: Bool {
        return currentAudioPlayer?.isPlaying ?? false
    }

    init(baseURL: String, profileId: String, engineName: String = "kokoro") {
        // Defensive URL construction — if the configured base URL is
        // malformed, fall back to localhost so we don't crash at init.
        let resolvedURL = URL(string: "\(baseURL)/generate/stream")
            ?? URL(string: "http://127.0.0.1:17493/generate/stream")!
        self.voiceboxStreamSpeechEndpointURL = resolvedURL
        self.voiceboxProfileId = profileId
        self.voiceboxEngineName = engineName
        super.init()
    }

    func speakText(_ text: String) async throws {
        // Default end-to-end path: fetch + play. Streaming TTS in
        // CompanionManager pre-fetches via synthesizeAudio() and then
        // calls playAudio() directly when ready, bypassing this combined
        // call to eliminate the gap between sentences in long responses.
        let audioData = try await synthesizeAudio(text: text)
        try await playAudio(audioData)
    }

    /// Hits Voicebox's /generate/stream and returns raw WAV bytes.
    /// Does NOT play. Used by streaming TTS in CompanionManager to
    /// pre-fetch TTS#2's audio while TTS#1 is still playing — closes
    /// the gap-between-sentences for multi-sentence responses (which
    /// otherwise would be ~5-10s of dead air for longer remainders).
    func synthesizeAudio(text: String) async throws -> Data {
        var request = URLRequest(url: voiceboxStreamSpeechEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30

        let voiceboxRequestPayload: [String: Any] = [
            "text": text,
            "profile_id": voiceboxProfileId,
            "engine": voiceboxEngineName,
            "language": "en"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: voiceboxRequestPayload)

        let synthesisStartedAt = Date()
        let (audioData, response) = try await URLSession.shared.data(for: request)
        let synthesisDurationSeconds = Date().timeIntervalSince(synthesisStartedAt)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: audioData, encoding: .utf8) ?? "<binary>"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "LocalVoiceboxTTSError",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Voicebox returned status \(statusCode): \(bodyText)"]
            )
        }

        print("🔊 Voicebox TTS: \(audioData.count / 1024)KB audio synthesized in \(String(format: "%.2f", synthesisDurationSeconds))s")
        return audioData
    }

    /// Plays already-synthesized audio bytes. Stops any current playback,
    /// installs a new AVAudioPlayer, and awaits delegate completion.
    /// Used by streaming TTS to play pre-fetched audio with zero network gap.
    func playAudio(_ audioData: Data) async throws {
        stopPlayback()

        try await withCheckedThrowingContinuation { (playbackCompletionContinuation: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(data: audioData)
                player.delegate = self
                self.currentAudioPlayer = player
                self.currentPlaybackContinuation = playbackCompletionContinuation
                player.prepareToPlay()
                player.play()
            } catch {
                playbackCompletionContinuation.resume(throwing: error)
            }
        }
    }

    func stopPlayback() {
        currentAudioPlayer?.stop()
        currentAudioPlayer = nil
        if let continuation = currentPlaybackContinuation {
            currentPlaybackContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully didFinishSuccessfully: Bool
    ) {
        Task { @MainActor in
            self.currentAudioPlayer = nil
            if let continuation = self.currentPlaybackContinuation {
                self.currentPlaybackContinuation = nil
                continuation.resume()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor in
            self.currentAudioPlayer = nil
            if let continuation = self.currentPlaybackContinuation {
                self.currentPlaybackContinuation = nil
                continuation.resume(
                    throwing: error ?? NSError(
                        domain: "LocalVoiceboxTTSError",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer decode error"]
                    )
                )
            }
        }
    }
}

enum TTSProvider: String {
    case elevenlabs
    case grok
    case voicebox
}

@MainActor
enum TTSClientFactory {
    static let userDefaultsKey = "TTSProvider"

    /// UserDefaults keys for Voicebox-specific config. Profile id is the
    /// UUID Voicebox creates when the user picks/creates a voice in its
    /// UI. Base URL defaults to Voicebox's standard 17493 port.
    static let voiceboxProfileIdUserDefaultsKey = "VoiceboxProfileId"
    static let voiceboxBaseURLUserDefaultsKey = "VoiceboxBaseURL"
    static let defaultVoiceboxBaseURL = "http://127.0.0.1:17493"

    /// Default to Grok TTS so Steph's "try Grok first" preference is honored
    /// on a clean install. Can be overridden via `defaults write ... TTSProvider elevenlabs`.
    static let defaultProvider: TTSProvider = .grok

    static func make(workerBaseURL: String) -> any TTSClient {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultProvider.rawValue
        let provider = TTSProvider(rawValue: raw) ?? defaultProvider

        switch provider {
        case .elevenlabs:
            print("🔊 TTS provider: ElevenLabs")
            return ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
        case .grok:
            print("🔊 TTS provider: Grok (xAI)")
            return GrokTTSClient(proxyURL: "\(workerBaseURL)/tts-grok")
        case .voicebox:
            // Voicebox needs a profile id from the user's local Voicebox
            // app. If none is configured, fall back to ElevenLabs so
            // Clicky's voice doesn't go silent — better to tell the user
            // via log than to crash mid-speech.
            let voiceboxBaseURL = UserDefaults.standard.string(forKey: voiceboxBaseURLUserDefaultsKey)
                ?? defaultVoiceboxBaseURL
            let voiceboxProfileId = UserDefaults.standard.string(forKey: voiceboxProfileIdUserDefaultsKey) ?? ""

            guard !voiceboxProfileId.isEmpty else {
                print("🔊 TTS provider: voicebox selected but no \(voiceboxProfileIdUserDefaultsKey) UserDefaults set — falling back to ElevenLabs. Set it via: defaults write com.stephenpierson.clickyplus VoiceboxProfileId <uuid-from-voicebox>")
                return ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
            }

            print("🔊 TTS provider: Voicebox (local) at \(voiceboxBaseURL), profile \(voiceboxProfileId)")
            return LocalVoiceboxTTSClient(baseURL: voiceboxBaseURL, profileId: voiceboxProfileId)
        }
    }
}
