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

@MainActor
final class MediaPlayerItemChromecastStreamMappingTests: XCTestCase {

    func testAdjustedAudioSelectionMapsToJellyfinAPIIndex() {
        var video = MediaStream()
        video.index = 0
        video.type = .video

        var audioEng = MediaStream()
        audioEng.index = 2
        audioEng.type = .audio
        audioEng.codec = "aac"
        audioEng.language = "eng"

        var audioSpa = MediaStream()
        audioSpa.index = 5
        audioSpa.type = .audio
        audioSpa.codec = "aac"
        audioSpa.language = "spa"

        let originals = [video, audioEng, audioSpa]

        var adjEng = audioEng
        adjEng.index = 1
        var adjSpa = audioSpa
        adjSpa.index = 2
        let playbackAudios = [adjEng, adjSpa]

        let mapped = MediaPlayerItem.chromecastStreamIndexForPlaybackInfo(
            selectedIndex: 2,
            playbackStreams: playbackAudios,
            originalStreams: originals,
            streamType: .audio,
            defaultIndex: 2
        )
        XCTAssertEqual(mapped, 5)
    }

    func testWhenSelectedMatchesAPIIndexItIsPassedThrough() {
        var audio = MediaStream()
        audio.index = 3
        audio.type = .audio
        audio.codec = "aac"

        let originals = [audio]
        var adj = audio
        adj.index = 0
        let mapped = MediaPlayerItem.chromecastStreamIndexForPlaybackInfo(
            selectedIndex: 3,
            playbackStreams: [adj],
            originalStreams: originals,
            streamType: .audio,
            defaultIndex: 3
        )
        XCTAssertEqual(mapped, 3)
    }

    func testNegativeSelectionUsesDefault() {
        let mapped = MediaPlayerItem.chromecastStreamIndexForPlaybackInfo(
            selectedIndex: -1,
            playbackStreams: [],
            originalStreams: [],
            streamType: .audio,
            defaultIndex: 7
        )
        XCTAssertEqual(mapped, 7)
    }
}
