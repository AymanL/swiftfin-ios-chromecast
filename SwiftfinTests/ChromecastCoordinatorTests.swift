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

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSession() {}
}

@MainActor
final class ChromecastCoordinatorTests: XCTestCase {

    // MARK: clearSessionError

    func testClearSessionErrorClearsMessage() {
        let fake = FakeChromecastSessionCoordinator()
        fake.sessionErrorMessage = "test"
        fake.clearSessionError()
        XCTAssertNil(fake.sessionErrorMessage)
    }

    func testClearSessionErrorOnNilMessageDoesNotCrash() {
        let fake = FakeChromecastSessionCoordinator()
        XCTAssertNil(fake.sessionErrorMessage)
        fake.clearSessionError() // must not crash
        XCTAssertNil(fake.sessionErrorMessage)
    }

    // MARK: isCastSessionActive

    func testIsCastSessionActiveDefaultsFalse() {
        let fake = FakeChromecastSessionCoordinator()
        XCTAssertFalse(fake.isCastSessionActive)
    }

    func testIsCastSessionActiveCanBeSetTrue() {
        let fake = FakeChromecastSessionCoordinator()
        fake.isCastSessionActive = true
        XCTAssertTrue(fake.isCastSessionActive)
    }
}
