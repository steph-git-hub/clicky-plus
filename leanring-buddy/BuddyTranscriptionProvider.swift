//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    /// v15p3gx (2026-05-18): hold the mic tap open for up to this many
    /// seconds after key release, gated by audio-power-level silence
    /// detection in BuddyDictationManager. Default 0 (immediate cleanup).
    /// Providers whose final transcript drops trailing audio when the
    /// tap is cut mid-word (Deepgram) override this. AssemblyAI's
    /// ForceEndpoint is aggressive enough that 0 works there.
    var trailingAudioGraceSeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

extension BuddyStreamingTranscriptionSession {
    var trailingAudioGraceSeconds: TimeInterval { 0 }
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession

    /// v15p3bk (2026-05-12): optionally pre-open a streaming session in
    /// the background so the next engage can skip the handshake. Default
    /// is a no-op for providers that don't support pre-warming (Apple
    /// Speech, OpenAI Whisper batch). Only the AssemblyAI streaming
    /// provider currently implements this.
    func prewarmSession(keyterms: [String])
}

extension BuddyTranscriptionProvider {
    func prewarmSession(keyterms: [String]) {
        // Default: no-op. Providers that support pre-warming override.
    }
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }

            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")

            if openAIProvider.isConfigured {
                print("⚠️ Transcription: using OpenAI as fallback")
                return openAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return openAIProvider
            }

            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")

            if assemblyAIProvider.isConfigured {
                print("⚠️ Transcription: using AssemblyAI as fallback")
                return assemblyAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }

        if openAIProvider.isConfigured {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }
}
