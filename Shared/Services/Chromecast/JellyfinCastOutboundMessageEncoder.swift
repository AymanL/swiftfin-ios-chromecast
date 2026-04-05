//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Builds JSON text for `urn:x-cast:com.connectsdk` messages (jellyfin-web `sendMessage` shape).
enum JellyfinCastOutboundMessageEncoder {

    struct SenderContext: Equatable {
        var userId: String
        var deviceId: String
        var accessToken: String
        var serverAddress: String
        var serverId: String
        var serverVersion: String?
        var receiverName: String?
    }

    /// `Identify` after session connect (jellyfin-web `onSessionConnected`).
    static func identifyJSON(context: SenderContext) throws -> String {
        try jsonString(command: "Identify", options: [:], context: context)
    }

    /// `Pause` / `Unpause` / `Seek` (jellyfin-web `chromecastPlayer` → receiver `commandHandler`).
    static func transportCommandJSON(command: String, options: [String: Any] = [:], context: SenderContext) throws -> String {
        try jsonString(command: command, options: options, context: context)
    }

    /// `PlayNow` with trimmed item stubs (jellyfin-web `loadMedia` + `sendMessage`).
    static func playNowJSON(
        baseItem: BaseItemDto,
        mediaSource: MediaSourceInfo,
        audioStreamIndex: Int,
        subtitleStreamIndex: Int,
        startPositionTicks: Int? = nil,
        context: SenderContext
    ) throws -> String {
        let options = try playOptionsDictionary(
            baseItem: baseItem,
            mediaSource: mediaSource,
            fallbackServerId: context.serverId,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            startPositionTicks: startPositionTicks
        )
        return try jsonString(command: "PlayNow", options: options, context: context)
    }

    static func playOptionsDictionary(
        baseItem: BaseItemDto,
        mediaSource: MediaSourceInfo,
        fallbackServerId: String,
        audioStreamIndex: Int,
        subtitleStreamIndex: Int,
        startPositionTicks: Int? = nil
    ) throws -> [String: Any] {
        guard let itemId = baseItem.id else {
            throw ErrorMessage("Missing item id for Chromecast load.")
        }

        let stub = try itemStubDictionary(from: baseItem, fallbackServerId: fallbackServerId)

        let startTicks = startPositionTicks ?? baseItem.userData?.playbackPositionTicks ?? 0
        let mediaSourceId = mediaSource.id ?? itemId

        return [
            "items": [stub],
            "startPositionTicks": startTicks,
            "mediaSourceId": mediaSourceId,
            "audioStreamIndex": audioStreamIndex,
            "subtitleStreamIndex": subtitleStreamIndex,
            "startIndex": 0,
        ]
    }

    static func itemStubDictionary(from item: BaseItemDto, fallbackServerId: String) throws -> [String: Any] {
        guard let id = item.id else {
            throw ErrorMessage("Missing item id for Chromecast item stub.")
        }

        var dict: [String: Any] = [
            "Id": id,
            "ServerId": item.serverID ?? fallbackServerId,
            "Name": item.name ?? "",
            "IsFolder": item.isFolder ?? false,
        ]

        if let type = item.type {
            dict["Type"] = type.rawValue
        }

        if let mediaType = item.mediaType {
            dict["MediaType"] = mediaType.rawValue
        }

        return dict
    }

    static func jsonString(
        command: String,
        options: [String: Any],
        context: SenderContext
    ) throws -> String {
        var root: [String: Any] = [
            "command": command,
            "options": options,
            "userId": context.userId,
            "deviceId": context.deviceId,
            "serverAddress": context.serverAddress,
            "serverId": context.serverId,
            "accessToken": context.accessToken,
        ]

        if let version = context.serverVersion {
            root["serverVersion"] = version
        }

        if let name = context.receiverName {
            root["receiverName"] = name
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ErrorMessage("Unable to encode Chromecast message.")
        }
        return string
    }
}
