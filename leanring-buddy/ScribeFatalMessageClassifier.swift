//
//  ScribeFatalMessageClassifier.swift
//  leanring-buddy
//
//  v16r20 (2026-08-06).
//
//  Decides whether a frame from the Scribe realtime socket means the
//  session is over. Deliberately isolated in its own Foundation-only
//  file, with no dependency on the provider, AVFoundation, or app state,
//  so it can be compiled and exercised standalone against the live
//  ElevenLabs socket. The point is that the SHIPPED code gets verified —
//  not a copy of it transcribed into a test.
//
//  Why this exists: on 2026-08-06 ElevenLabs answered every Scribe
//  session with
//      {"message_type":"quota_exceeded","error":"You have exceeded your quota."}
//  delivered immediately after `session_started`, then closed the socket.
//  The provider escalated only frames whose `message_type` CONTAINED the
//  substring "error". `quota_exceeded` contains neither "error" nor
//  "auth", so it fell into the informational no-op branch and was thrown
//  away. The user saw the engage chime, a live teal indicator, a halo
//  tracking their voice — and no transcript, with no explanation
//  anywhere. The server had stated the problem in plain English on the
//  first frame.
//
//  Hours of debugging went into transport-layer theories (tokens,
//  handshakes, reconnects) for something the server had already
//  explained. A provider refusing to work is information; it belongs in
//  front of the user.
//

import Foundation

enum ScribeFatalMessageClassifier {

    /// Frame types meaning the ACCOUNT is the problem, not the connection.
    /// Retrying or reconnecting cannot help — only a change outside the
    /// app (top-up, new key, billing) will.
    ///
    /// Enumerated rather than pattern-matched precisely because the
    /// pattern-matching approach is what failed: `quota_exceeded` matches
    /// no obvious substring. Anything here triggers an engine fallback.
    static let accountFatalMessageTypes: Set<String> = [
        "quota_exceeded",
        "auth_error",
        "unauthorized",
        "forbidden",
        "invalid_token",
        "subscription_expired",
        "rate_limit_exceeded",
    ]

    struct Classification: Equatable {
        /// The provider's own wording where available — usually directly
        /// actionable ("You have exceeded your quota.").
        let reason: String
        /// True when switching engines is the right response.
        let isAccountFatal: Bool
    }

    private struct Envelope: Decodable {
        let message_type: String
        let message: String?
        let error: String?
        let reason: String?
    }

    /// Returns nil for ordinary informational frames (`session_started`,
    /// `partial_transcript`, keepalives) — those must never be treated as
    /// fatal, since `session_started` immediately precedes a quota
    /// refusal and misclassifying it would kill every healthy session.
    static func classify(_ rawJSON: String) -> Classification? {
        guard let data = rawJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }

        let messageType = envelope.message_type.lowercased()
        let isAccountFatal = accountFatalMessageTypes.contains(messageType)

        // The substring check stays as a net for refusal types we haven't
        // observed yet — escalated so they're never silent, but not
        // account-fatal, so a transient server error doesn't cost the
        // user their chosen engine.
        guard isAccountFatal || messageType.contains("error") else { return nil }

        let reason = envelope.message
            ?? envelope.error
            ?? envelope.reason
            ?? "Scribe error (\(envelope.message_type))."
        return Classification(reason: reason, isAccountFatal: isAccountFatal)
    }
}
