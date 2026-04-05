//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Parsed receiver → sender custom message (`urn:x-cast:com.connectsdk`), aligned with jellyfin-chromecast `broadcastToMessageBus` /
/// jellyfin-web `messageListener`.
enum JellyfinCastInboundMessage: Equatable {

    /// `playbackprogress` — `data` includes `PlayState` with Jellyfin ticks and pause flag.
    case playbackProgress(positionTicks: Int, isPaused: Bool?)

    /// `playstatechange` — same payload shape as progress in practice.
    case playStateChange(positionTicks: Int?, isPaused: Bool?)

    /// `playbackstart` / similar — treat like progress when `PlayState` present.
    case playbackStart(positionTicks: Int?, isPaused: Bool?)

    /// `playbackstop` — TV stopped current item.
    case playbackStop

    /// `playbackerror` — `data` is often an error code string.
    case playbackError(codeOrMessage: String?)

    /// `connectionerror` or `error` with optional message.
    case connectionError(detail: String?)

    /// Known type we do not map yet (e.g. `volumechange`, `repeatmodechange`).
    case ignored(type: String)

    static func parse(jsonString: String) -> JellyfinCastInboundMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return parse(jsonData: data)
    }

    static func parse(jsonData: Data) -> JellyfinCastInboundMessage? {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = root["type"] as? String
        else {
            return nil
        }

        let dataPayload = root["data"]
        let messagePayload = root["message"] as? String

        switch type {
        case "playbackprogress":
            let (ticks, paused) = Self.extractPlayState(from: dataPayload)
            guard let ticks else { return .ignored(type: type) }
            return .playbackProgress(positionTicks: ticks, isPaused: paused)

        case "playstatechange":
            let (ticks, paused) = Self.extractPlayState(from: dataPayload)
            return .playStateChange(positionTicks: ticks, isPaused: paused)

        case "playbackstart":
            let (ticks, paused) = Self.extractPlayState(from: dataPayload)
            return .playbackStart(positionTicks: ticks, isPaused: paused)

        case "playbackstop":
            return .playbackStop

        case "playbackerror":
            if let code = dataPayload as? String {
                return .playbackError(codeOrMessage: code)
            }
            return .playbackError(codeOrMessage: messagePayload)

        case "connectionerror":
            return .connectionError(detail: messagePayload)

        case "error":
            return .connectionError(detail: messagePayload ?? (dataPayload as? String))

        default:
            return .ignored(type: type)
        }
    }

    /// `data` from receiver is usually `getSenderReportingData`: top-level `PlayState` is `PlaybackProgressInfo` (PositionTicks, IsPaused,
    /// …).
    private static func extractPlayState(from data: Any?) -> (ticks: Int?, isPaused: Bool?) {
        guard let dict = data as? [String: Any] else { return (nil, nil) }

        let playState = (dict["PlayState"] as? [String: Any]) ?? dict

        let ticks = (playState["PositionTicks"] as? NSNumber)?.intValue
            ?? playState["PositionTicks"] as? Int

        let paused: Bool? = if let b = playState["IsPaused"] as? Bool {
            b
        } else if let n = playState["IsPaused"] as? NSNumber {
            n.boolValue
        } else {
            nil
        }

        return (ticks, paused)
    }
}
