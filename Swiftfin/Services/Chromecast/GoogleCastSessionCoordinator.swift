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
import JellyfinAPI

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
    private var seekDebounceTask: Task<Void, Never>?
    private static let seekDebounceInterval: Duration = .milliseconds(300)
    private var cancellables: Set<AnyCancellable> = []

    /// True after a `PlayNow` was sent for this Cast session; phone controls should target the TV.
    var routesPlaybackControlsToChromecast: Bool {
        isCastSessionActive && lastPlayNowSignature != nil
    }

    override private init() {
        super.init()
        sessionManager.add(self)
        refreshConnectionState()

        // Register as the play/pause router for MediaPlayerManager.
        MediaPlayerManager.chromecastRouter = self

        // Track the active playback item so PlayNow can fire when Cast connects (replaces
        // VideoPlayer's onReceive(manager.$playbackItem) Chromecast block).
        Container.shared.mediaPlayerManager().$playbackItem
            .sink { [weak self] item in
                guard let self, item?.baseItem.id != nil else { return }
                guard self.isCastSessionActive else { return }
                self.loadChromecastItem(item)
            }
            .store(in: &cancellables)
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
        seekDebounceTask?.cancel()
        seekDebounceTask = nil

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

    func loadChromecastItem(_ playbackItem: MediaPlayerItem?) {
        pendingChromecastPlaybackItem = playbackItem
        Task { await flushChromecastMessagesIfReady() }
    }

    func connectSDKChannelBecameWritable() async {
        await flushChromecastMessagesIfReady()
    }

    func connectSDKChannelDidDisconnect() {
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
            sessionErrorMessage = L10n.castChannelRegistrationError
        }
    }

    private func flushChromecastMessagesIfReady() async {
        guard isCastSessionActive,
              let channel = connectSDKChannel,
              channel.isWritable,
              let session = sessionManager.currentCastSession
        else { return }

        do {
            let context = try await makeSenderContext(castSession: session)

            if !sentIdentifyThisConnection {
                let json = try JellyfinCastOutboundMessageEncoder.identifyJSON(context: context)
                try postJSON(json)
                sentIdentifyThisConnection = true
            }

            guard let item = pendingChromecastPlaybackItem else { return }

            let signature = "\(item.baseItem.id ?? "")-\(item.playSessionID)"
            if lastPlayNowSignature == signature { return }

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


    /// Schedules a debounced `Seek` to the TV. Rapid calls (e.g. repeated jump taps) coalesce
    /// into one send after 300 ms of inactivity, preventing Cast channel saturation.
    func sendChromecastSeekWhenControlling(positionSeconds: Double) {
        seekDebounceTask?.cancel()
        guard routesPlaybackControlsToChromecast else { return }
        let clamped = max(0, positionSeconds)
        seekDebounceTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.seekDebounceInterval) } catch { return }
            await self?.flushDebouncedSeek(positionSeconds: clamped)
        }
    }

    private func flushDebouncedSeek(positionSeconds: Double) async {
        guard routesPlaybackControlsToChromecast,
              isCastSessionActive,
              connectSDKChannel?.isWritable == true,
              let castSession = sessionManager.currentCastSession
        else { return }
        do {
            let context = try await makeSenderContext(castSession: castSession)
            let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(
                command: .seek,
                options: ["position": positionSeconds],
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
            throw ErrorMessage(L10n.castChannelNotReady)
        }

        var gckError: GCKError?
        let ok = channel.sendTextMessage(json, error: &gckError)
        if !ok {
            throw gckError ?? ErrorMessage(L10n.castMessageSendError)
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
            throw ErrorMessage(L10n.castSessionLoadError)
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
        // The string check is locale-dependent and may miss non-English errors; NSURLErrorDomain is the reliable path.
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
            // Pick up whichever item is currently loaded (replaces VideoPlayer's
            // onReceive(coordinator.$isCastSessionActive) block).
            let currentItem = Container.shared.mediaPlayerManager().playbackItem
            if currentItem?.baseItem.id != nil {
                self.loadChromecastItem(currentItem)
            }
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
            self.seekDebounceTask?.cancel()
            self.seekDebounceTask = nil
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

// MARK: - ChromecastPlaybackRouting

extension GoogleCastSessionCoordinator: ChromecastPlaybackRouting {

    func routesPlaybackControls() -> Bool {
        routesPlaybackControlsToChromecast
    }

    func mirrorPlaybackRequest(_ status: MediaPlayerManager.PlaybackRequestStatus) async {
        guard routesPlaybackControlsToChromecast,
              isCastSessionActive,
              connectSDKChannel?.isWritable == true,
              let castSession = sessionManager.currentCastSession
        else { return }

        do {
            let context = try await makeSenderContext(castSession: castSession)
            let command: JellyfinCastOutboundMessageEncoder.TransportCommand = switch status {
            case .paused: .pause
            case .playing: .unpause
            }
            let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(command: command, context: context)
            try postJSON(json)
        } catch {
            // Avoid alert spam for transport; user still has local controls if Cast ignores a message.
        }
    }
}

// MARK: - ChromecastVideoPlayerCoordinating

extension GoogleCastSessionCoordinator: ChromecastVideoPlayerCoordinating { }
