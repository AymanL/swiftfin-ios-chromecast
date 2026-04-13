//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import Swiftfin_iOS
import XCTest

final class JellyfinCastInboundMessageTests: XCTestCase {

    func testPlaybackProgress_nestedPlayState_ticksAndPause() {
        let json = """
        {"type":"playbackprogress","data":{"PlayState":{"PositionTicks":500000000,"IsPaused":true}}}
        """
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .playbackProgress(ticks, paused) = msg else {
            return XCTFail("expected playbackProgress, got \(String(describing: msg))")
        }
        XCTAssertEqual(ticks, 500_000_000)
        XCTAssertEqual(paused, true)
    }

    func testPlaybackProgress_flatPlayState_ignoredWithoutTicks() {
        let json = """
        {"type":"playbackprogress","data":{"IsPaused":true}}
        """
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .ignored(type) = msg else {
            return XCTFail("expected ignored, got \(String(describing: msg))")
        }
        XCTAssertEqual(type, "playbackprogress")
    }

    func testPlayStateChange_onlyPause() {
        let json = """
        {"type":"playstatechange","data":{"PlayState":{"IsPaused":false}}}
        """
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .playStateChange(ticks, paused) = msg else {
            return XCTFail("expected playStateChange, got \(String(describing: msg))")
        }
        XCTAssertNil(ticks)
        XCTAssertEqual(paused, false)
    }

    func testPlaybackStart_nestedPlayState_ticksAndPause() {
        let json = """
        {"type":"playbackstart","data":{"PlayState":{"PositionTicks":120000000,"IsPaused":false}}}
        """
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .playbackStart(ticks, paused) = msg else {
            return XCTFail("expected playbackStart, got \(String(describing: msg))")
        }
        XCTAssertEqual(ticks, 120_000_000)
        XCTAssertEqual(paused, false)
    }

    // JSONSerialization deserialises JSON numbers as NSNumber, not Int. The flat-data
    // shape (PositionTicks directly inside `data`, no nested PlayState) exercises the
    // NSNumber → Int coercion path in extractPlayState. This test guards against
    // regressions where a plain `as? Int` cast on an NSNumber would silently return nil.
    func testPlaybackStart_flatPayloadShape_ticksAndPause() {
        let json = """
        {"type":"playbackstart","data":{"PositionTicks":99,"IsPaused":true}}
        """
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .playbackStart(ticks, paused) = msg else {
            return XCTFail("expected playbackStart, got \(String(describing: msg))")
        }
        XCTAssertEqual(ticks, 99)
        XCTAssertEqual(paused, true)
    }

    func testPlaybackStop() {
        let json = #"{"type":"playbackstop","data":null}"#
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        XCTAssertEqual(msg, .playbackStop)
    }

    func testPlaybackError_stringData() {
        let json = #"{"type":"playbackerror","data":"noCompatibleStream"}"#
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .playbackError(code) = msg else {
            return XCTFail("expected playbackError, got \(String(describing: msg))")
        }
        XCTAssertEqual(code, "noCompatibleStream")
    }

    func testConnectionError_usesMessageField() {
        let json = #"{"type":"connectionerror","message":"Receiver closed"}"#
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .connectionError(detail) = msg else {
            return XCTFail("expected connectionError, got \(String(describing: msg))")
        }
        XCTAssertEqual(detail, "Receiver closed")
    }

    func testError_type_mapsToConnectionError() {
        let json = #"{"type":"error","message":"network"}"#
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .connectionError(detail) = msg else {
            return XCTFail("expected connectionError, got \(String(describing: msg))")
        }
        XCTAssertEqual(detail, "network")
    }

    func testUnknownType_returnsIgnored() {
        let json = #"{"type":"volumechange","data":{}}"#
        let msg = JellyfinCastInboundMessage.parse(jsonString: json)
        guard case let .ignored(type) = msg else {
            return XCTFail("expected ignored, got \(String(describing: msg))")
        }
        XCTAssertEqual(type, "volumechange")
    }

    func testInvalidJSON_returnsNil() {
        XCTAssertNil(JellyfinCastInboundMessage.parse(jsonString: "not-json"))
    }

    func testMissingTypeField_returnsNil() {
        let json = #"{"data":{"PositionTicks":100}}"#
        XCTAssertNil(JellyfinCastInboundMessage.parse(jsonString: json))
    }

    func testTypeFieldNotString_returnsNil() {
        // `type` must be a String; a numeric type must not produce a spurious match.
        let json = #"{"type":42,"data":{}}"#
        XCTAssertNil(JellyfinCastInboundMessage.parse(jsonString: json))
    }
}
