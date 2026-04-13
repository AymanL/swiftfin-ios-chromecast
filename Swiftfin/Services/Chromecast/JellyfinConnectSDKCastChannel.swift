//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import GoogleCast

/// Custom Cast namespace for Jellyfin (`urn:x-cast:com.connectsdk`).
final class JellyfinConnectSDKCastChannel: GCKCastChannel {

    weak var owner: GoogleCastSessionCoordinator?

    init(owner: GoogleCastSessionCoordinator) {
        self.owner = owner
        super.init(namespace: JellyfinCastConnectSDK.namespace)
    }

    override func didChangeWritableState(_ isWritable: Bool) {
        super.didChangeWritableState(isWritable)
        guard isWritable else { return }
        Task { @MainActor in
            await owner?.connectSDKChannelBecameWritable()
        }
    }

    override func didReceiveTextMessage(_ message: String) {
        super.didReceiveTextMessage(message)
        Task { @MainActor in
            owner?.handleConnectSDKInboundText(message)
        }
    }

    override func didDisconnect() {
        super.didDisconnect()
        Task { @MainActor in
            owner?.connectSDKChannelDidDisconnect()
        }
    }
}
