//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI

extension MediaPlayerItem {

    /// Jellyfin Cast calls `PlaybackInfo` with `AudioStreamIndex` / `SubtitleStreamIndex` as **API** `MediaStream.Index` values.
    /// `selectedAudioStreamIndex` / `selectedSubtitleStreamIndex` often hold **VLC-adjusted** indices (see `adjustedTrackIndexes`), which
    /// must be mapped before `PlayNow`.
    var chromecastAudioStreamIndexForPlaybackInfo: Int {
        Self.chromecastStreamIndexForPlaybackInfo(
            selectedIndex: selectedAudioStreamIndex,
            playbackStreams: audioStreams,
            originalStreams: mediaSource.mediaStreams,
            streamType: .audio,
            defaultIndex: mediaSource.defaultAudioStreamIndex
        )
    }

    var chromecastSubtitleStreamIndexForPlaybackInfo: Int {
        Self.chromecastStreamIndexForPlaybackInfo(
            selectedIndex: selectedSubtitleStreamIndex,
            playbackStreams: subtitleStreams,
            originalStreams: mediaSource.mediaStreams,
            streamType: .subtitle,
            defaultIndex: mediaSource.defaultSubtitleStreamIndex
        )
    }

    static func chromecastStreamIndexForPlaybackInfo(
        selectedIndex: Int?,
        playbackStreams: [MediaStream],
        originalStreams: [MediaStream]?,
        streamType: MediaStreamType,
        defaultIndex: Int?
    ) -> Int {
        let selected = selectedIndex ?? -1

        guard let originals = originalStreams, !originals.isEmpty else {
            if selected >= 0 { return selected }
            return defaultIndex ?? -1
        }

        if selected < 0 {
            return defaultIndex ?? -1
        }

        let internalStreams = originals.filter { !($0.isExternal ?? false) && $0.type == streamType }
        let externalStreams = originals.filter { ($0.isExternal ?? false) && $0.type == streamType }
        let ordered = internalStreams + externalStreams

        // Picker tags always use adjusted `MediaStream.index` from `playbackStreams`. Prefer mapping by row first,
        // because an adjusted index can collide with a different stream’s API index (e.g. second track is adjusted `2`
        // while another stream’s Jellyfin index is also `2`).
        if let position = playbackStreams.firstIndex(where: { $0.index == selected }) {
            if position < ordered.count, let apiIndex = ordered[position].index {
                return apiIndex
            }

            if playbackStreams.count == 1, let only = playbackStreams.first,
               let match = ordered.first(where: { streamsMatchForChromecast($0, only) }),
               let apiIndex = match.index
            {
                return apiIndex
            }
        }

        if originals.contains(where: { $0.type == streamType && $0.index == selected }) {
            return selected
        }

        return defaultIndex ?? -1
    }

    private static func streamsMatchForChromecast(_ original: MediaStream, _ adjustedCopy: MediaStream) -> Bool {
        original.type == adjustedCopy.type
            && original.codec == adjustedCopy.codec
            && original.language == adjustedCopy.language
            && original.channelLayout == adjustedCopy.channelLayout
            && original.displayTitle == adjustedCopy.displayTitle
            && original.isDefault == adjustedCopy.isDefault
    }
}
