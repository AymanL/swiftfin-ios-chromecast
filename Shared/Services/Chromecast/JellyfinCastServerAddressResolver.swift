//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Picks a server base URL the Chromecast can reach (parity: jellyfin-web `sendMessage` localhost handling).
enum JellyfinCastServerAddressResolver {

    /// Returns a base URL string (no trailing slash) for the Cast receiver to call the Jellyfin API.
    static func serverURLStringForChromecast(
        client: JellyfinClient,
        server: ServerState
    ) async throws -> String {
        let base = client.configuration.url
        let absolute = base.absoluteString.trimmingSuffix("/")

        guard let host = base.host else {
            return absolute
        }

        let loopback = isLoopbackHost(host)

        if !loopback {
            return absolute
        }

        let info = try await server.getPublicSystemInfo()
        let local = info.localAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !local.isEmpty, URL(string: local)?.host != nil else {
            throw ErrorMessage(
                "Chromecast cannot use a localhost server URL. Add a LAN or HTTPS server address in Swiftfin, or ensure Jellyfin reports a valid LocalAddress."
            )
        }

        return local.trimmingSuffix("/")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host == "[::1]" { return true }
        if host.hasPrefix("127.") { return true }
        return false
    }
}
