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

    private static let loopbackHostname = "localhost"
    private static let loopbackIPv6 = "[::1]"
    private static let loopbackIPv4Prefix = "127."

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
            throw ErrorMessage(L10n.castLocalhostServerError)
        }

        let resolved = local.trimmingSuffix("/")
        return resolved
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == loopbackHostname
            || host == loopbackIPv6
            || host.hasPrefix(loopbackIPv4Prefix)
    }
}
