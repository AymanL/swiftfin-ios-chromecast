//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

/// Abstracts Chromecast play/pause routing so `MediaPlayerManager` (Shared) has no
/// direct dependency on the iOS-only `GoogleCastSessionCoordinator`.
@MainActor
protocol ChromecastPlaybackRouting: AnyObject {

    /// Returns true when play/pause actions should be forwarded to the Cast receiver.
    func routesPlaybackControls() -> Bool

    /// Forwards a play/pause state change to the Cast receiver.
    func mirrorPlaybackRequest(_ status: MediaPlayerManager.PlaybackRequestStatus) async
}
