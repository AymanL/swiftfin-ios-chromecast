//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(iOS)
import JellyfinAPI

extension MediaPlayerItem {

    /// Jellyfin Cast calls `PlaybackInfo` with `AudioStreamIndex` / `SubtitleStreamIndex` as API `MediaStream.Index` values.
    /// `selectedAudioStreamIndex` / `selectedSubtitleStreamIndex` often hold VLC-adjusted indices (see `adjustedTrackIndexes`), which must be mapped before `PlayNow`.
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

    /// Maps a VLC-adjusted track index to the Jellyfin API `MediaStream.Index` required by `PlayNow`.
    ///
    /// VLC renumbers tracks internally, so the picker’s stored index is often wrong for the Cast receiver.
    /// Tries four strategies in order: row-position mapping, single-track fuzzy match, direct passthrough,
    /// then server default.
    static func chromecastStreamIndexForPlaybackInfo(
        selectedIndex: Int?,
        playbackStreams: [MediaStream],
        originalStreams: [MediaStream]?,
        streamType: MediaStreamType,
        defaultIndex: Int?
    ) -> Int {
        let selected = selectedIndex ?? -1

        // No stream list from the server — nothing to map against. Pass through whatever we have.
        guard let originals = originalStreams, !originals.isEmpty else {
            if selected >= 0 { return selected }
            return defaultIndex ?? -1
        }

        // -1 means the user disabled this stream type (e.g. subtitles off). Nothing to map.
        if selected < 0 {
            return defaultIndex ?? -1
        }

        // Reconstruct the ordering VLC uses: internal streams first, then external (e.g. sidecar .srt files).
        // This ordering must match what VLC reports so that row-position lookup below is correct.
        let internalStreams = originals.filter { !($0.isExternal ?? false) && $0.type == streamType }
        let externalStreams = originals.filter { ($0.isExternal ?? false) && $0.type == streamType }
        let ordered = internalStreams + externalStreams

        // Strategy 1 — row-position mapping.
        // Picker tags always use adjusted `MediaStream.index` from `playbackStreams`. Prefer mapping by row first,
        // because an adjusted index can collide with a different stream’s API index (e.g. second track is adjusted `2`
        // while another stream’s Jellyfin index is also `2`).
        if let position = playbackStreams.firstIndex(where: { $0.index == selected }) {
            if position < ordered.count, let apiIndex = ordered[position].index {
                return apiIndex
            }

            // Strategy 2 — single-track fuzzy match.
            // Row mapping failed (ordered.count mismatch), but there is only one stream in the picker.
            // Identify it in the original list by its fingerprint (codec + language + layout + title).
            if playbackStreams.count == 1, let only = playbackStreams.first,
               let match = ordered.first(where: { streamsMatchForChromecast($0, only) }),
               let apiIndex = match.index
            {
                return apiIndex
            }
        }

        // Strategy 3 — direct passthrough.
        // The selected index already matches a Jellyfin API index (no VLC adjustment occurred for this file).
        if originals.contains(where: { $0.type == streamType && $0.index == selected }) {
            return selected
        }

        // Strategy 4 — give up, use the server default.
        return defaultIndex ?? -1
    }

    /// Fuzzy-matches two stream descriptors by codec, language, layout, title, and default flag.
    /// Used as a fallback when only one stream exists in the picker and row-position mapping fails.
    private static func streamsMatchForChromecast(_ original: MediaStream, _ adjustedCopy: MediaStream) -> Bool {
        original.type == adjustedCopy.type
            && original.codec == adjustedCopy.codec
            && original.language == adjustedCopy.language
            && original.channelLayout == adjustedCopy.channelLayout
            && original.displayTitle == adjustedCopy.displayTitle
            && original.isDefault == adjustedCopy.isDefault
    }
}
#endif
