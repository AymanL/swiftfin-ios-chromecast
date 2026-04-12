//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// Abstracts Cast control for `VideoPlayer` (Shared) so the view has no direct
/// dependency on the iOS-only `GoogleCastSessionCoordinator`.
@MainActor
protocol ChromecastVideoPlayerCoordinating: AnyObject {

    /// Called when the video player view disappears; ends the Cast session unless one is active.
    func handleVideoPlayerDisappear()

    /// Schedules a debounced `Seek` on the Cast receiver.
    func sendChromecastSeekWhenControlling(positionSeconds: Double)
}

// MARK: - Environment

private struct ChromecastVideoPlayerCoordinatorKey: EnvironmentKey {
    static let defaultValue: (any ChromecastVideoPlayerCoordinating)? = nil
}

extension EnvironmentValues {
    var chromecastVideoPlayerCoordinator: (any ChromecastVideoPlayerCoordinating)? {
        get { self[ChromecastVideoPlayerCoordinatorKey.self] }
        set { self[ChromecastVideoPlayerCoordinatorKey.self] = newValue }
    }
}
