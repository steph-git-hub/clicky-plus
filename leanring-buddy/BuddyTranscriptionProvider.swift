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

/// v16r20 (2026-08-06): marks an error as "this provider will not work
/// until something changes OUTSIDE the app" — an exhausted quota, a
/// revoked key, a billing lapse — as distinct from a transient network
/// fault where retrying is the right move.
///
/// Incident 2026-08-06: ElevenLabs began answering every Scribe session
/// with `{"message_type":"quota_exceeded","error":"You have exceeded your
/// quota."}` immediately after `session_started`. The provider only
/// escalated messages whose `message_type` CONTAINED the substring
/// "error", so `quota_exceeded` fell through to the informational no-op
/// branch and was discarded. The server stated the problem in plain
/// English and the app threw it away — the user saw an engage sound, a
/// live indicator, and no transcript, with nothing to act on. Hours went
/// into chasing tokens and transport bugs for what the first frame had
/// already explained.
///
/// The lesson encoded here: a provider telling us it refuses to work is
/// information, and it belongs in front of the user.
protocol BuddyProviderFatalError: Error {
    /// False for ordinary transport failures from the same error type —
    /// only an account-level refusal should trigger an engine switch.
    var isProviderFatal: Bool { get }
    /// Human-readable reason, ideally the provider's own wording.
    var providerFatalReason: String { get }
    /// Short provider label for the message ("Scribe", "Deepgram").
    var providerFatalLabel: String { get }
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
