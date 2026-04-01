//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
@testable import Swiftfin_iOS
import XCTest

@MainActor
final class FakeChromecastSessionCoordinator: ChromecastSessionCoordinating, ObservableObject {

    @Published
    var sessionErrorMessage: String?

    @Published
    var isCastSessionActive: Bool = false

    private(set) var endDismissPlayerCallCount = 0

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSessionWhenDismissingPlayer() {
        endDismissPlayerCallCount += 1
    }
}

@MainActor
final class ChromecastCoordinatorTests: XCTestCase {

    func testClearSessionErrorClearsMessage() {
        let fake = FakeChromecastSessionCoordinator()
        fake.sessionErrorMessage = "test"
        fake.clearSessionError()
        XCTAssertNil(fake.sessionErrorMessage)
    }

    func testEndCastSessionWhenDismissingPlayerIsRecorded() {
        let fake = FakeChromecastSessionCoordinator()
        fake.endCastSessionWhenDismissingPlayer()
        fake.endCastSessionWhenDismissingPlayer()
        XCTAssertEqual(fake.endDismissPlayerCallCount, 2)
    }
}
