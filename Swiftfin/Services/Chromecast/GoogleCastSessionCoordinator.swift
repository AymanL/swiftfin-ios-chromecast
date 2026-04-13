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
#if os(iOS)
import UIKit
#endif

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

    private var isFlushingChromecastMessages: Bool = false
    private var flushRequestedWhileInProgress: Bool = false

    private var lastChromecastInboundProgressTime: CFAbsoluteTime = 0
    private let chromecastInboundProgressMinInterval: CFTimeInterval = 0.25
    private var lastChromecastInboundPositionTicks: Int?

    private var seekDebounceTask: Task<Void, Never>?
    private static let seekDebounceInterval: Duration = .milliseconds(300)
    private var cancellables: Set<AnyCancellable> = []

    #if os(iOS)
    private var foregroundDiscoveryObserver: NSObjectProtocol?
    #endif

    /// True after a `PlayNow` was sent for this Cast session; phone controls should target the TV.
    var routesPlaybackControlsToChromecast: Bool {
        isCastSessionActive && lastPlayNowSignature != nil
    }

    override private init() {
        super.init()
        sessionManager.add(self)
        refreshConnectionState()

        // Register as the play/pause and seek router for MediaPlayerManager.
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

        #if os(iOS)
        registerForegroundCastDiscoveryRefreshIfNeeded()
        #endif
    }

    #if os(iOS)
    private func registerForegroundCastDiscoveryRefreshIfNeeded() {
        guard foregroundDiscoveryObserver == nil else { return }
        foregroundDiscoveryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
        }
    }
    #endif

    /// Hands off the last TV-reported position before clearing Cast state, then pauses local playback.
    private func notifyMediaPlayerChromecastSessionEnded() {
        let lastTicks = lastChromecastInboundPositionTicks
        lastChromecastInboundPositionTicks = nil
        Container.shared.mediaPlayerManager().applyChromecastSessionEndedFromReceiver(lastTVPositionTicks: lastTicks)
    }

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSession() {
        tearDownCastSession()
    }

    func stopCastingFromPlayer() {
        tearDownCastSession()
    }

    /// Removes the Cast channel, clears all session state, and submits an end-session request
    /// when a GCK connection is active. Also notifies the media player manager so it can hand
    /// off the last TV-reported position before resuming local playback.
    ///
    /// - Note: Do NOT call `refreshConnectionState()` after this — GCK teardown is async.
    ///   `isCastSessionActive` is updated by the `sessionManager(_:didEnd:withError:)` delegate callback.
    private func tearDownCastSession() {
        let wasChromecastPlayback = lastPlayNowSignature != nil
        let manager = sessionManager
        if let session = manager.currentCastSession, let channel = connectSDKChannel {
            _ = session.remove(channel)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil
        pendingChromecastPlaybackItem = nil
        seekDebounceTask?.cancel()
        seekDebounceTask = nil

        guard manager.connectionState == .connected || manager.connectionState == .connecting else { return }
        let submitted = manager.endSessionAndStopCasting(true)
        if !submitted {
            assertionFailure("endSessionAndStopCasting returned false despite active connection state")
        }
        if wasChromecastPlayback {
            notifyMediaPlayerChromecastSessionEnded()
        }
    }

    func loadChromecastItem(_ playbackItem: MediaPlayerItem?) {
        pendingChromecastPlaybackItem = playbackItem
        Task { await flushChromecastMessagesIfReady() }
    }

    func connectSDKChannelBecameWritable() async {
        await flushChromecastMessagesIfReady()
    }

    func connectSDKChannelDidDisconnect() {
        let wasChromecastPlayback = lastPlayNowSignature != nil

        // When the channel disconnects (e.g. lock/unlock), the receiver-side namespace may still be
        // registered in the underlying Cast session. If we nil our reference without removing the
        // old channel, the next `session.add(...)` can fail.
        let channelToRemove = connectSDKChannel
        if let channelToRemove,
           let session = sessionManager.currentCastSession
        {
            _ = session.remove(channelToRemove)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil
        if wasChromecastPlayback {
            notifyMediaPlayerChromecastSessionEnded()
        }
    }

    /// Dispatches a parsed receiver to sender message to the media player manager or error state.
    /// Only acts while `routesPlaybackControlsToChromecast` is true (i.e. a PlayNow has fired).
    /// Progress updates are throttled to ≤4 Hz
    func handleConnectSDKInboundText(_ message: String) {
        guard routesPlaybackControlsToChromecast,
              let parsed = JellyfinCastInboundMessage.parse(jsonString: message)
        else { return }

        switch parsed {
        case .ignored:
            break
        case let .playbackProgress(ticks, paused):
            applyInboundPositionTicks(ticks, throttle: true)
            if let paused {
                Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: nil, isPaused: paused)
            }
        case let .playStateChange(ticks, paused):
            applyInboundPositionTicks(ticks, throttle: ticks != nil)
            if let paused {
                Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: nil, isPaused: paused)
            }
        case let .playbackStart(ticks, paused):
            applyInboundPositionTicks(ticks, throttle: ticks != nil)
            if let paused {
                Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: nil, isPaused: paused)
            }
        case .playbackStop:
            Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: nil, isPaused: true)
        case let .playbackError(code):
            sessionErrorMessage = Self.userFacingChromecastPlaybackError(code)
        case let .connectionError(detail):
            sessionErrorMessage = detail ?? L10n.castConnectionError
        }
    }

    private func applyInboundPositionTicks(_ ticks: Int?, throttle: Bool) {
        guard let ticks else { return }
        lastChromecastInboundPositionTicks = ticks
        if throttle {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastChromecastInboundProgressTime < chromecastInboundProgressMinInterval { return }
            lastChromecastInboundProgressTime = now
        }
        Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: ticks, isPaused: nil)
    }

    private static func userFacingChromecastPlaybackError(_ code: String?) -> String {
        if let code, !code.isEmpty {
            return L10n.castPlaybackErrorCode(code)
        }
        return L10n.castPlaybackError
    }

    private func refreshConnectionState() {
        let wasActive = isCastSessionActive
        let state = sessionManager.connectionState
        switch state {
        case .connecting, .connected:
            isCastSessionActive = true
        default:
            isCastSessionActive = false
        }
        if wasActive, !isCastSessionActive {
            GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
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
        if isFlushingChromecastMessages {
            flushRequestedWhileInProgress = true
            return
        }
        isFlushingChromecastMessages = true
        defer {
            isFlushingChromecastMessages = false
            if flushRequestedWhileInProgress {
                flushRequestedWhileInProgress = false
                Task { await flushChromecastMessagesIfReady() }
            }
        }

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
            lastChromecastInboundPositionTicks = startTicks
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
            let wasChromecastPlayback = self.lastPlayNowSignature != nil
            if let ch = self.connectSDKChannel {
                _ = session.remove(ch)
            }
            self.connectSDKChannel = nil
            self.sentIdentifyThisConnection = false
            self.lastPlayNowSignature = nil
            self.pendingChromecastPlaybackItem = nil
            self.seekDebounceTask?.cancel()
            self.seekDebounceTask = nil
            self.refreshConnectionState()
            if let error {
                self.sessionErrorMessage = self.mapError(error)
            }
            if wasChromecastPlayback {
                self.notifyMediaPlayerChromecastSessionEnded()
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

    func seekWhenControlling(positionSeconds: Double) {
        sendChromecastSeekWhenControlling(positionSeconds: positionSeconds)
    }
}

// MARK: - ChromecastVideoPlayerCoordinating

extension GoogleCastSessionCoordinator: ChromecastVideoPlayerCoordinating { }
