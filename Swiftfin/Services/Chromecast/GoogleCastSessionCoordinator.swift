//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import GoogleCast

/// Observes `GCKSessionManager` and surfaces errors for SwiftUI; tears down session when leaving the player.
@MainActor
final class GoogleCastSessionCoordinator: NSObject, ChromecastSessionCoordinating, ObservableObject {

    static let shared = GoogleCastSessionCoordinator()

    @Published
    private(set) var sessionErrorMessage: String?

    @Published
    private(set) var isCastSessionActive: Bool = false

    private var sessionManager: GCKSessionManager {
        GCKCastContext.sharedInstance().sessionManager
    }

    override private init() {
        super.init()
        sessionManager.add(self)
        refreshConnectionState()
    }

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSessionWhenDismissingPlayer() {
        let manager = sessionManager
        guard manager.connectionState == .connected || manager.connectionState == .connecting else { return }
        _ = manager.endSessionAndStopCasting(true)
        refreshConnectionState()
    }

    private func refreshConnectionState() {
        let state = sessionManager.connectionState
        switch state {
        case .connecting, .connected:
            isCastSessionActive = true
        default:
            isCastSessionActive = false
        }
    }

    private func mapError(_ error: Error) -> String {
        let ns = error as NSError
        let description = error.localizedDescription
        if ns.domain == NSURLErrorDomain || description.localizedCaseInsensitiveContains("network") {
            return "\(description)\n\nIf Cast devices are missing, check Wi‑Fi and allow Local Network access for this app in Settings."
        }
        return description
    }
}

extension GoogleCastSessionCoordinator: @preconcurrency GCKSessionManagerListener {

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in
            self.refreshConnectionState()
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        Task { @MainActor in
            self.refreshConnectionState()
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor in
            self.refreshConnectionState()
            if let error {
                self.sessionErrorMessage = self.mapError(error)
            }
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        Task { @MainActor in
            self.refreshConnectionState()
            self.sessionErrorMessage = self.mapError(error)
        }
    }
}
