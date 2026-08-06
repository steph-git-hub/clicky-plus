//
//  verify_scribe_fatal_classifier.swift
//  v16r20 (2026-08-06)
//
//  Exercises the SHIPPED classifier — this script is compiled together
//  with leanring-buddy/ScribeFatalMessageClassifier.swift, so there is no
//  transcribed copy that can drift from the app.
//
//  Run:
//    swift leanring-buddy/ScribeFatalMessageClassifier.swift \
//          scripts/verify_scribe_fatal_classifier.swift
//
//  Part 1 is offline and deterministic. Part 2 opens a REAL socket to
//  ElevenLabs and replays a spent single-use token, which the server
//  refuses — proving the classifier is matched against the actual wire
//  format rather than an assumption about it. That assumption is what
//  failed on 2026-08-06.
//

import Foundation

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// MARK: - Part 1: offline classification

print("\n=== Part 1: classification ===")

let quotaFrame = #"{"message_type":"quota_exceeded","error":"You have exceeded your quota."}"#
let quota = ScribeFatalMessageClassifier.classify(quotaFrame)
check("quota_exceeded is detected", quota != nil)
check("quota_exceeded is account-fatal", quota?.isAccountFatal == true)
check(
    "quota reason is the server's own wording",
    quota?.reason == "You have exceeded your quota.",
    "got: \(quota?.reason ?? "nil")"
)

let authFrame = #"{"message_type":"auth_error","error":"You must be authenticated to use this endpoint."}"#
let auth = ScribeFatalMessageClassifier.classify(authFrame)
check("auth_error is account-fatal", auth?.isAccountFatal == true)

// These must NOT be fatal. session_started arrives immediately before a
// quota refusal — misclassifying it would kill every healthy session.
for frame in [
    #"{"message_type":"session_started","session_id":"abc"}"#,
    #"{"message_type":"partial_transcript","text":"hello"}"#,
    #"{"message_type":"committed_transcript","text":"hello"}"#,
    #"{"message_type":"committed_transcript_with_timestamps","text":"hi"}"#,
] {
    let type = frame.split(separator: "\"")[3]
    check("\(type) is NOT fatal", ScribeFatalMessageClassifier.classify(frame) == nil)
}

// Unknown *_error types escalate (never silent) but don't cost the user
// their chosen engine.
let transient = ScribeFatalMessageClassifier.classify(
    #"{"message_type":"transient_error","message":"try again"}"#
)
check("unknown *_error still escalates", transient != nil)
check("unknown *_error is NOT account-fatal", transient?.isAccountFatal == false)

check("malformed JSON is ignored", ScribeFatalMessageClassifier.classify("not json") == nil)

// MARK: - Part 2: live wire-format check

print("\n=== Part 2: live refusal from api.elevenlabs.io ===")

func mintToken() -> String? {
    var request = URLRequest(
        url: URL(string: "https://clicky-proxy.sapierso.workers.dev/scribe-token")!
    )
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    var token: String?
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
        defer { semaphore.signal() }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        token = json["token"] as? String
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return token
}

/// Opens a real Scribe socket and returns the text frames received.
/// Sends silence, because account checks only fire once audio arrives —
/// an idle socket stays open and looks perfectly healthy. That gap is
/// precisely why the original diagnosis took hours.
func collectFrames(token: String, seconds: Int) -> [String] {
    var components = URLComponents(
        string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    )!
    components.queryItems = [
        URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
        URLQueryItem(name: "token", value: token),
        URLQueryItem(name: "commit_strategy", value: "manual"),
        URLQueryItem(name: "include_timestamps", value: "false"),
    ]

    let task = URLSession(configuration: .default)
        .webSocketTask(with: URLRequest(url: components.url!))
    task.resume()

    let payload: [String: Any] = [
        "message_type": "input_audio_chunk",
        "audio_base_64": Data(count: 3200).base64EncodedString(),
        "sample_rate": 16000,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let string = String(data: data, encoding: .utf8) {
        task.send(.string(string)) { _ in }
    }

    var frames: [String] = []
    let done = DispatchSemaphore(value: 0)
    func receiveNext() {
        task.receive { result in
            switch result {
            case .success(let message):
                if case .string(let text) = message { frames.append(text) }
                receiveNext()
            case .failure:
                done.signal()  // socket closed — expected on refusal
            }
        }
    }
    receiveNext()
    _ = done.wait(timeout: .now() + .seconds(seconds))
    task.cancel(with: .goingAway, reason: nil)
    return frames
}

guard let token = mintToken() else {
    print("  ⚠️  could not mint a token (offline?) — skipping live check")
    print("\n\(failures == 0 ? "ALL OFFLINE CHECKS PASSED" : "\(failures) FAILURE(S)")")
    exit(failures == 0 ? 0 : 1)
}

print("  minted token \(token.prefix(16))…")
_ = collectFrames(token: token, seconds: 6)   // first use spends it
let replayFrames = collectFrames(token: token, seconds: 6)  // replay is refused

if replayFrames.isEmpty {
    print("  ⚠️  no frames received — skipping live assertions")
} else {
    for frame in replayFrames {
        print("  server said: \(frame.prefix(140))")
    }
    let classified = replayFrames.compactMap(ScribeFatalMessageClassifier.classify)
    check(
        "live refusal frame is classified as fatal",
        !classified.isEmpty,
        "wire format may have changed"
    )
    check(
        "live refusal is account-fatal",
        classified.contains { $0.isAccountFatal }
    )
}

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
