//
//  GrokTTSClient.swift
//  leanring-buddy
//
//  Sends text to the Cloudflare Worker's /tts-grok endpoint, which
//  proxies to xAI's TTS API (https://api.x.ai/v1/tts) and returns
//  MP3 audio bytes. Plays back via AVAudioPlayer — same pattern as
//  the ElevenLabs client so they're plug-compatible through TTSClient.
//
//  Voice selection lives server-side (Worker env var XAI_VOICE_ID)
//  to keep API keys and voice choice out of the client.
//

import AVFoundation
import Foundation

@MainActor
final class GrokTTSClient: TTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// Kept alive so audio finishes playing even if the caller drops us.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to Grok TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        // Minimal payload — the Worker fills in voice_id + language
        // from env vars so we can retune without rebuilding the app.
        let body: [String: Any] = [
            "text": text
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GrokTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GrokTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Grok TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 Grok TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
