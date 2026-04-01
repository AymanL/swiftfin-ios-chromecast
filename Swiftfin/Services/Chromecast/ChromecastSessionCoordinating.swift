//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation

/// Abstraction over Google Cast session lifecycle for UI and tests (Phase 2).
@MainActor
protocol ChromecastSessionCoordinating: AnyObject, ObservableObject {

    /// User-facing message from the last session failure, if any.
    var sessionErrorMessage: String? { get }

    /// Whether a Cast session is currently active (connected or connecting).
    var isCastSessionActive: Bool { get }

    func clearSessionError()

    /// End Cast when the video player is dismissed (Phase 2: no LOAD yet; avoid orphan sessions).
    func endCastSessionWhenDismissingPlayer()
}
