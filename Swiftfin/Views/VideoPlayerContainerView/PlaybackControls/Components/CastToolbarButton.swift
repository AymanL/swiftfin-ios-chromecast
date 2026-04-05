//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import GoogleCast
import SwiftUI

/// Google Cast device picker entry point (Phase 2). Uses the SDK default expanded controller.
struct CastToolbarButton: UIViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: .zero)
        button.tintColor = .white
        // After a receiver drops off the network (e.g. TV power cycle), the device list can stay stale
        // until discovery runs again; nudge before the SDK presents the Cast dialog.
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.touchDownRefreshDiscovery),
            for: .touchDown
        )
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}

    final class Coordinator: NSObject {
        @objc
        func touchDownRefreshDiscovery() {
            GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
        }
    }
}
