//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Google Cast application IDs registered by the Jellyfin project with Google.
///
/// These IDs identify which Cast receiver app runs on the Chromecast device when
/// a session is started. The canonical source for these values is jellyfin-web
/// (`src/plugins/chromecastPlayer/plugin.js`); the receiver itself is hosted at
/// https://github.com/jellyfin/jellyfin-chromecast.
///
/// Parity: `jellyfin-web` and server playback settings use the same values for
/// stable vs unstable receivers. `Info.plist` lists `_F007D354._googlecast._tcp` and
/// `_6F511C87._googlecast._tcp` under `NSBonjourServices` for discovery.
enum JellyfinCastReceiverID {

    /// Production Web Receiver — use this in release builds.
    static let stable = "F007D354"

    /// Development Web Receiver built from the main branch — use this for testing unreleased receiver changes.
    static let unstable = "6F511C87"
}
