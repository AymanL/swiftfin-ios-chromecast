//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Foundation
import GoogleCast

/// Observes `GCKSessionManager`, drives Jellyfin `com.connectsdk` messages, and surfaces errors for SwiftUI.
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

    private var connectSDKChannel: JellyfinConnectSDKCastChannel?
    private var sentIdentifyThisConnection = false
    private var pendingChromecastPlaybackItem: MediaPlayerItem?
    private var lastPlayNowSignature: String?

    private static var didInstallMediaPlayerChromecastHooks = false

    /// True after a `PlayNow` was sent for this Cast session; phone controls should target the TV.
    var routesPlaybackControlsToChromecast: Bool {
        isCastSessionActive && lastPlayNowSignature != nil
    }

    override private init() {
        super.init()
        sessionManager.add(self)
        refreshConnectionState()
        Self.installMediaPlayerChromecastHooksIfNeeded()
    }

    private static func installMediaPlayerChromecastHooksIfNeeded() {
        guard !didInstallMediaPlayerChromecastHooks else { return }
        didInstallMediaPlayerChromecastHooks = true
        MediaPlayerManager.chromecastRoutesPlaybackControls = {
            GoogleCastSessionCoordinator.shared.routesPlaybackControlsToChromecast
        }
        MediaPlayerManager.chromecastMirrorPlaybackRequest = { status in
            await GoogleCastSessionCoordinator.shared.mirrorPlaybackRequestToChromecast(status)
        }
    }

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSession() {
        let manager = sessionManager
        if let session = manager.currentCastSession, let channel = connectSDKChannel {
            _ = session.remove(channel)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil

        guard manager.connectionState == .connected || manager.connectionState == .connecting else { return }
        // Return value is false if the request could not be submitted (e.g. no active session).
        // The guard above already covers the common case; log unexpected failures for diagnostics.
        let submitted = manager.endSessionAndStopCasting(true)
        if !submitted {
            assertionFailure("endSessionAndStopCasting returned false despite active connection state")
        }
        // Do NOT call refreshConnectionState() here — the session teardown is async.
        // isCastSessionActive will be updated by the sessionManager(_:didEnd:withError:) delegate callback.
    }

    /// Called when `playbackItem` changes or Cast becomes active (Phase 3 LOAD).
    func queueChromecastLoad(playbackItem: MediaPlayerItem?) {
        pendingChromecastPlaybackItem = playbackItem
        Task { await flushChromecastMessagesIfReady() }
    }

    func handleConnectSDKChannelBecameWritable() async {
        await flushChromecastMessagesIfReady()
    }

    func handleConnectSDKChannelDisconnected() {
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
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

    private func setupConnectChannel(for session: GCKCastSession) {
        if let oldChannel = connectSDKChannel, let existing = sessionManager.currentCastSession {
            _ = existing.remove(oldChannel)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil

        let channel = JellyfinConnectSDKCastChannel(owner: self)
        connectSDKChannel = channel
        if !session.add(channel) {
            sessionErrorMessage = "Unable to register Chromecast control channel."
        }
    }

    private func flushChromecastMessagesIfReady() async {
        guard isCastSessionActive,
              let channel = connectSDKChannel,
              channel.isWritable,
              let session = sessionManager.currentCastSession
        else { return }

        do {
            if !sentIdentifyThisConnection {
                let context = try await makeSenderContext(castSession: session)
                let json = try JellyfinCastOutboundMessageEncoder.identifyJSON(context: context)
                try postJSON(json)
                sentIdentifyThisConnection = true
            }

            guard let item = pendingChromecastPlaybackItem else { return }

            let signature = "\(item.baseItem.id ?? "")-\(item.playSessionID)"
            if lastPlayNowSignature == signature { return }

            let context = try await makeSenderContext(castSession: session)
            let audioIndex = item.chromecastAudioStreamIndexForPlaybackInfo
            let subtitleIndex = item.chromecastSubtitleStreamIndexForPlaybackInfo
            let startTicks = Container.shared.mediaPlayerManager().seconds.ticks
            let json = try JellyfinCastOutboundMessageEncoder.playNowJSON(
                baseItem: item.baseItem,
                mediaSource: item.mediaSource,
                audioStreamIndex: audioIndex,
                subtitleStreamIndex: subtitleIndex,
                startPositionTicks: startTicks,
                context: context
            )
            try postJSON(json)
            lastPlayNowSignature = signature
            pauseLocalPlaybackWhileChromecastPlays()
        } catch {
            sessionErrorMessage = mapError(error)
        }
    }

    /// Forwards play/pause to the Jellyfin receiver (`Pause` / `Unpause`).
    func mirrorPlaybackRequestToChromecast(_ status: MediaPlayerManager.PlaybackRequestStatus) async {
        guard routesPlaybackControlsToChromecast,
              isCastSessionActive,
              connectSDKChannel?.isWritable == true,
              let castSession = sessionManager.currentCastSession
        else { return }

        do {
            let context = try await makeSenderContext(castSession: castSession)
            let command: String = switch status {
            case .paused: "Pause"
            case .playing: "Unpause"
            }
            let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(command: command, context: context)
            try postJSON(json)
        } catch {
            // Avoid alert spam for transport; user still has local controls if Cast ignores a message.
        }
    }

    /// Seeks the TV to `positionSeconds` (receiver `Seek` command; position is seconds).
    func sendChromecastSeekWhenControlling(positionSeconds: Double) async {
        guard routesPlaybackControlsToChromecast,
              isCastSessionActive,
              connectSDKChannel?.isWritable == true,
              let castSession = sessionManager.currentCastSession
        else { return }

        let clamped = max(0, positionSeconds)

        do {
            let context = try await makeSenderContext(castSession: castSession)
            let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(
                command: "Seek",
                options: ["position": clamped],
                context: context
            )
            try postJSON(json)
        } catch {}
    }

    private func pauseLocalPlaybackWhileChromecastPlays() {
        Container.shared.mediaPlayerManager().proxy?.pause()
    }

    private func postJSON(_ json: String) throws {
        guard let channel = connectSDKChannel else {
            throw ErrorMessage("Chromecast channel is not ready.")
        }

        var gckError: GCKError?
        let ok = channel.sendTextMessage(json, error: &gckError)
        if !ok {
            throw gckError ?? ErrorMessage("Failed to send Chromecast message.")
        }
    }

    private func makeSenderContext(castSession: GCKCastSession) async throws -> JellyfinCastOutboundMessageEncoder.SenderContext {
        var userSession = Container.shared.currentUserSession()
        if userSession == nil {
            // Factory caches `nil` if it was first resolved before sign-in; refresh for Cast.
            Container.shared.currentUserSession.reset()
            userSession = Container.shared.currentUserSession()
        }

        guard let userSession else {
            throw ErrorMessage(
                "Swiftfin could not load your Jellyfin session for Cast. Return to the library, confirm you are signed in, then try Cast again."
            )
        }

        let serverAddress = try await JellyfinCastServerAddressResolver.serverURLStringForChromecast(
            client: userSession.client,
            server: userSession.server
        )

        let publicInfo = StoredValues[.Server.publicInfo(id: userSession.server.id)]

        return JellyfinCastOutboundMessageEncoder.SenderContext(
            userId: userSession.user.id,
            deviceId: userSession.client.configuration.deviceID,
            accessToken: userSession.user.accessToken,
            serverAddress: serverAddress,
            serverId: userSession.server.id,
            serverVersion: publicInfo.version,
            receiverName: castSession.device.friendlyName
        )
    }

    private func mapError(_ error: Error) -> String {
        let ns = error as NSError
        let description = error.localizedDescription
        // Heuristic: NSURLErrorDomain or "network" in the message suggests a connectivity problem.
        // Append a Wi-Fi / Local Network hint so the user knows where to look first.
        if ns.domain == NSURLErrorDomain || description.localizedCaseInsensitiveContains("network") {
            return "\(description)\n\n\(L10n.castNetworkErrorHint)"
        }
        return description
    }
}

extension GoogleCastSessionCoordinator: @preconcurrency GCKSessionManagerListener {

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in
            self.setupConnectChannel(for: session)
            self.refreshConnectionState()
            await self.flushChromecastMessagesIfReady()
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        Task { @MainActor in
            if self.connectSDKChannel == nil {
                self.setupConnectChannel(for: session)
            }
            self.refreshConnectionState()
            await self.flushChromecastMessagesIfReady()
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor in
            if let ch = self.connectSDKChannel {
                _ = session.remove(ch)
            }
            self.connectSDKChannel = nil
            self.sentIdentifyThisConnection = false
            self.lastPlayNowSignature = nil
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
