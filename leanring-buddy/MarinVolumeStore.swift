//
//  MarinVolumeStore.swift
//  leanring-buddy
//
//  v15p3hs (2026-05-19): NEW. Persisted output-volume control for
//  Marin's TTS playback. Backs the panel slider and gets applied to
//  whichever realtime provider's outputPlayerNode is active.
//
//  Persistence: UserDefaults key `clicky.marin.outputVolume`, default
//  1.0 (no attenuation). Range 0.0 ... 1.0 — AVAudioPlayerNode's
//  native volume range, so we can pipe the stored value straight in.
//
//  Wiring: when the slider changes, the panel calls `setVolume(_:)`,
//  which (1) writes to UserDefaults and (2) posts
//  `.marinVolumeDidChange`. The Gemini and OpenAI realtime managers
//  observe the notification and apply the new volume to their own
//  `outputPlayerNode` immediately, so changes take effect mid-turn.
//

import AVFoundation
import Foundation

extension Notification.Name {
    static let marinVolumeDidChange = Notification.Name("clicky.marin.volumeDidChange")
}

enum MarinVolumeStore {
    private static let userDefaultsKey = "clicky.marin.outputVolume"
    private static let defaultVolume: Float = 1.0

    /// Current stored volume, 0.0 ... 1.0. Defaults to 1.0 if unset.
    static var volume: Float {
        let raw = UserDefaults.standard.object(forKey: userDefaultsKey) as? Float
        let value = raw ?? defaultVolume
        return min(max(value, 0.0), 1.0)
    }

    /// Set the volume, persist it, and broadcast the change so any
    /// active Marin player nodes apply it immediately.
    static func setVolume(_ newValue: Float) {
        let clamped = min(max(newValue, 0.0), 1.0)
        UserDefaults.standard.set(clamped, forKey: userDefaultsKey)
        NotificationCenter.default.post(
            name: .marinVolumeDidChange,
            object: nil,
            userInfo: ["volume": clamped]
        )
    }
}
