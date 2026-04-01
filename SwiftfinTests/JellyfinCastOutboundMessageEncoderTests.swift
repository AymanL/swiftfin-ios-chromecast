//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
@testable import Swiftfin_iOS
import XCTest

final class JellyfinCastOutboundMessageEncoderTests: XCTestCase {

    private let sampleContext = JellyfinCastOutboundMessageEncoder.SenderContext(
        userId: "user-1",
        deviceId: "device-1",
        accessToken: "token-1",
        serverAddress: "https://jelly.example",
        serverId: "server-1",
        serverVersion: "10.9.0",
        receiverName: "Living Room TV"
    )

    func testTransportCommandPause_includesCommandAndEmptyOptions() throws {
        let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(command: "Pause", context: sampleContext)
        let root = try decodeObject(json)
        XCTAssertEqual(root["command"] as? String, "Pause")
        let options = try XCTUnwrap(root["options"] as? [String: Any])
        XCTAssertTrue(options.isEmpty)
    }

    func testTransportCommandSeek_includesPositionSeconds() throws {
        let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(
            command: "Seek",
            options: ["position": 125.5],
            context: sampleContext
        )
        let root = try decodeObject(json)
        XCTAssertEqual(root["command"] as? String, "Seek")
        let options = try XCTUnwrap(root["options"] as? [String: Any])
        XCTAssertEqual(options["position"] as? Double, 125.5)
    }

    func testIdentifyJSON_sortedKeysAndShape() throws {
        let json = try JellyfinCastOutboundMessageEncoder.identifyJSON(context: sampleContext)

        let root = try decodeObject(json)
        XCTAssertEqual(root["command"] as? String, "Identify")
        XCTAssertEqual(root["userId"] as? String, "user-1")
        XCTAssertEqual(root["deviceId"] as? String, "device-1")
        XCTAssertEqual(root["accessToken"] as? String, "token-1")
        XCTAssertEqual(root["serverAddress"] as? String, "https://jelly.example")
        XCTAssertEqual(root["serverId"] as? String, "server-1")
        XCTAssertEqual(root["serverVersion"] as? String, "10.9.0")
        XCTAssertEqual(root["receiverName"] as? String, "Living Room TV")
        let options = try XCTUnwrap(root["options"] as? [String: Any])
        XCTAssertTrue(options.isEmpty)

        XCTAssertEqual(root.count, 9)
        XCTAssertTrue(
            json.hasPrefix("{\"accessToken\":"),
            "JSONSerialization sortedKeys should emit accessToken first at the root."
        )
    }

    func testPlayNowJSON_itemStubAndPlayOptions() throws {
        var base = BaseItemDto()
        base.id = "item-movie-1"
        base.serverID = "server-1"
        base.name = "Test Movie"
        base.type = .movie
        base.mediaType = .video
        base.isFolder = false
        base.userData = UserItemDataDto(playbackPositionTicks: 50_000_000)

        var source = MediaSourceInfo()
        source.id = "media-source-1"

        let json = try JellyfinCastOutboundMessageEncoder.playNowJSON(
            baseItem: base,
            mediaSource: source,
            audioStreamIndex: 1,
            subtitleStreamIndex: -1,
            context: sampleContext
        )

        let root = try decodeObject(json)
        XCTAssertEqual(root["command"] as? String, "PlayNow")

        let options = try XCTUnwrap(root["options"] as? [String: Any])
        XCTAssertEqual(options["startPositionTicks"] as? Int, 50_000_000)
        XCTAssertEqual(options["mediaSourceId"] as? String, "media-source-1")
        XCTAssertEqual(options["audioStreamIndex"] as? Int, 1)
        XCTAssertEqual(options["subtitleStreamIndex"] as? Int, -1)
        XCTAssertEqual(options["startIndex"] as? Int, 0)

        let items = try XCTUnwrap(options["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let stub = try XCTUnwrap(items.first)
        XCTAssertEqual(stub["Id"] as? String, "item-movie-1")
        XCTAssertEqual(stub["ServerId"] as? String, "server-1")
        XCTAssertEqual(stub["Name"] as? String, "Test Movie")
        XCTAssertEqual(stub["IsFolder"] as? Bool, false)
        XCTAssertEqual(stub["Type"] as? String, BaseItemKind.movie.rawValue)
        XCTAssertEqual(stub["MediaType"] as? String, MediaType.video.rawValue)
    }

    func testPlayNowUsesItemIdWhenMediaSourceIdNil() throws {
        var base = BaseItemDto()
        base.id = "fallback-id"
        base.serverID = "server-1"
        base.name = "X"
        base.type = .movie
        base.mediaType = .video

        let source = MediaSourceInfo()

        let json = try JellyfinCastOutboundMessageEncoder.playNowJSON(
            baseItem: base,
            mediaSource: source,
            audioStreamIndex: 0,
            subtitleStreamIndex: -1,
            context: sampleContext
        )

        let root = try decodeObject(json)
        let options = try XCTUnwrap(root["options"] as? [String: Any])
        XCTAssertEqual(options["mediaSourceId"] as? String, "fallback-id")
    }

    func testPlayOptionsThrowsWhenItemIdMissing() {
        let base = BaseItemDto()
        let source = MediaSourceInfo()
        XCTAssertThrowsError(
            try JellyfinCastOutboundMessageEncoder.playOptionsDictionary(
                baseItem: base,
                mediaSource: source,
                fallbackServerId: "server-1",
                audioStreamIndex: 0,
                subtitleStreamIndex: -1
            )
        ) { error in
            XCTAssertTrue(error is ErrorMessage)
        }
    }

    private func decodeObject(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let any = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(any as? [String: Any])
    }
}
