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

    private static var didInstallMediaPlayerChromecastHooks = false

    #if os(iOS)
    private static var didRegisterForegroundDiscoveryObserver = false
    #endif

    /// True after a `PlayNow` was sent for this Cast session; phone controls should target the TV.
    var routesPlaybackControlsToChromecast: Bool {
        isCastSessionActive && lastPlayNowSignature != nil
    }

    override private init() {
        super.init()
        sessionManager.add(self)
        refreshConnectionState()
        Self.installMediaPlayerChromecastHooksIfNeeded()
        #if os(iOS)
        Self.registerForegroundCastDiscoveryRefreshIfNeeded()
        #endif
    }

    #if os(iOS)
    private static func registerForegroundCastDiscoveryRefreshIfNeeded() {
        guard !didRegisterForegroundDiscoveryObserver else { return }
        didRegisterForegroundDiscoveryObserver = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
        }
    }
    #endif

    private static func installMediaPlayerChromecastHooksIfNeeded() {
        guard !didInstallMediaPlayerChromecastHooks else { return }
        didInstallMediaPlayerChromecastHooks = true
        MediaPlayerManager.chromecastRoutesPlaybackControls = {
            GoogleCastSessionCoordinator.shared.routesPlaybackControlsToChromecast
        }
        MediaPlayerManager.chromecastMirrorPlaybackRequest = { status in
            await GoogleCastSessionCoordinator.shared.mirrorPlaybackRequestToChromecast(status)
        }
        MediaPlayerManager.chromecastMirrorSeekToSeconds = { seconds in
            await GoogleCastSessionCoordinator.shared.sendChromecastSeekWhenControlling(positionSeconds: seconds)
        }
    }

    /// Hands off the last TV-reported position before clearing Cast state, then pauses local playback.
    private func notifyMediaPlayerChromecastSessionEnded() {
        let lastTicks = lastChromecastInboundPositionTicks
        lastChromecastInboundPositionTicks = nil
        Container.shared.mediaPlayerManager().applyChromecastSessionEndedFromReceiver(lastTVPositionTicks: lastTicks)
    }

    func clearSessionError() {
        sessionErrorMessage = nil
    }

    func endCastSessionWhenDismissingPlayer() {
        let wasChromecastPlayback = lastPlayNowSignature != nil
        let manager = sessionManager
        if let session = manager.currentCastSession, let channel = connectSDKChannel {
            _ = session.remove(channel)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil
        pendingChromecastPlaybackItem = nil

        if manager.connectionState == .connected || manager.connectionState == .connecting {
            _ = manager.endSessionAndStopCasting(true)
        }
        refreshConnectionState()
        if wasChromecastPlayback {
            notifyMediaPlayerChromecastSessionEnded()
        }
    }

    func stopCastingFromPlayer() {
        let wasChromecastPlayback = lastPlayNowSignature != nil
        let manager = sessionManager
        if let session = manager.currentCastSession, let channel = connectSDKChannel {
            _ = session.remove(channel)
        }
        connectSDKChannel = nil
        sentIdentifyThisConnection = false
        lastPlayNowSignature = nil
        pendingChromecastPlaybackItem = nil
        if manager.connectionState == .connected || manager.connectionState == .connecting {
            _ = manager.endSessionAndStopCasting(true)
        }
        refreshConnectionState()
        if wasChromecastPlayback {
            notifyMediaPlayerChromecastSessionEnded()
        }
    }

    /// Called when `playbackItem` changes or Cast becomes active (Phase 3 LOAD).
    func queueChromecastLoad(playbackItem: MediaPlayerItem?) {
        // #region agent log: queue pending PlayNow context
        if let playbackItem {
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "F",
                location: "GoogleCastSessionCoordinator.queueChromecastLoad",
                message: "Pending Chromecast playback item set",
                data: [
                    "baseItemID": playbackItem.baseItem.id ?? "",
                    "playSessionID": playbackItem.playSessionID,
                    "mediaSourceID": playbackItem.mediaSource.id ?? "",
                    "mediaSourceHasTranscodingURL": playbackItem.mediaSource.transcodingURL != nil,
                    "selectedAudioStreamIndex": playbackItem.selectedAudioStreamIndex ?? -1,
                    "selectedSubtitleStreamIndex": playbackItem.selectedSubtitleStreamIndex ?? -1,
                    "audioStreamsCount": playbackItem.audioStreams.count,
                    "subtitleStreamsCount": playbackItem.subtitleStreams.count,
                    "videoStreamsCount": playbackItem.videoStreams.count
                ]
            )
        } else {
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "F",
                location: "GoogleCastSessionCoordinator.queueChromecastLoad",
                message: "Pending Chromecast playback item set to nil"
            )
        }
        // #endregion

        pendingChromecastPlaybackItem = playbackItem
        Task { await flushChromecastMessagesIfReady() }
    }

    func handleConnectSDKChannelBecameWritable() async {
        await flushChromecastMessagesIfReady()
    }

    func handleConnectSDKChannelDisconnected() {
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

    func handleConnectSDKInboundText(_ message: String) {
        guard routesPlaybackControlsToChromecast,
              let parsed = JellyfinCastInboundMessage.parse(jsonString: message)
        else { return }

        // #region agent log: Cast inbound type/errors (receiver -> phone)
        switch parsed {
        case .ignored:
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Ignored inbound ConnectSDK message"
            )
        case let .playbackProgress(ticks, paused):
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound playbackprogress",
                data: [
                    "positionTicks": ticks as Any,
                    "isPaused": paused
                ]
            )
        case let .playStateChange(ticks, paused):
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound playstatechange",
                data: [
                    "positionTicks": ticks as Any,
                    "isPaused": paused
                ]
            )
        case let .playbackStart(ticks, paused):
            // Receiver might silently fall back to audio-only; PlayState often contains clues we currently discard.
            // Log a compact summary of PlayState on `playbackstart` (not on every progress tick).
            var playStateSummary: [String: Any] = [:]
            if let data = message.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataPayload = root["data"]
            {
                let playState = (dataPayload as? [String: Any])?["PlayState"] ?? dataPayload
                if let dict = playState as? [String: Any] {
                    playStateSummary["playStateKeysCount"] = dict.keys.count as Any
                    // Include all keys (12ish keys) so we can see exactly what the receiver reports.
                    playStateSummary["playStateKeys"] = Array(dict.keys)

                    // Include only primitive values to keep JSON payload small and serializable.
                    var primitiveValues: [String: Any] = [:]
                    for (k, v) in dict {
                        if v is NSNumber || v is Bool || v is String {
                            primitiveValues[k] = v
                        }
                    }
                    playStateSummary["playStatePrimitiveValues"] = primitiveValues

                    let candidateKeys = [
                        "MediaType", "mediaType",
                        "VideoCodec", "videoCodec",
                        "VideoStreamIndex", "videoStreamIndex",
                        "AudioCodec", "audioCodec",
                        "AudioStreamIndex", "audioStreamIndex",
                        "TranscodingType", "transcodingType",
                        "Container", "container",
                        "IsVideo", "isVideo",
                        "IsAudio", "isAudio"
                    ]
                    for key in candidateKeys {
                        if let v = dict[key] {
                            playStateSummary[key] = v
                        }
                    }
                }
            }

            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "J",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound playbackstart (PlayState summary)",
                data: [
                    "positionTicks": ticks as Any,
                    "isPaused": paused,
                    "playStateSummary": playStateSummary
                ]
            )
        case .playbackStop:
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound playbackstop"
            )
        case let .playbackError(codeOrMessage):
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound playbackerror",
                data: [
                    "codeOrMessage": codeOrMessage ?? ""
                ]
            )
        case let .connectionError(detail):
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "I",
                location: "GoogleCastSessionCoordinator.handleConnectSDKInboundText",
                message: "Inbound connectionerror",
                data: [
                    "detail": detail ?? ""
                ]
            )
        }
        // #endregion

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
            // #region agent log: cast stop position evidence
            do {
                let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                let manager = Container.shared.mediaPlayerManager()
                let lastTicks = lastChromecastInboundPositionTicks.map { NSNumber(value: $0) } ?? NSNull()
                let currentSecondsTicks = NSNumber(value: manager.seconds.ticks)
                let payload: [String: Any] = [
                    "sessionId": "071397",
                    "runId": "pre_fix",
                    "hypothesisId": "H1",
                    "location": "GoogleCastSessionCoordinator.handleConnectSDKInboundText(playbackStop)",
                    "message": "Received playbackstop from TV; compare last inbound ticks vs manager.seconds",
                    "data": [
                        "lastChromecastInboundPositionTicks": lastTicks,
                        "manager.seconds.ticks": currentSecondsTicks
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if JSONSerialization.isValidJSONObject(payload),
                   let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let jsonLine = String(data: jsonData, encoding: .utf8),
                   let lineData = (jsonLine + "\n").data(using: .utf8),
                   let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
                {
                    try? handle.seekToEnd()
                    handle.write(lineData)
                    try? handle.close()
                }
            }
            // #endregion
            Container.shared.mediaPlayerManager().applyChromecastInboundPlaybackState(positionTicks: nil, isPaused: true)
        case let .playbackError(code):
            sessionErrorMessage = Self.userFacingChromecastPlaybackError(code)
        case let .connectionError(detail):
            sessionErrorMessage = detail.map { "Cast: \($0)" } ?? "Cast connection error. Check Wi‑Fi and try again."
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
            return "Playback on the TV failed (\(code)). Check Jellyfin or your network."
        }
        return "Playback on the TV failed. Check Jellyfin or your network."
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
        let addOk = session.add(channel)
        if !addOk {
            sessionErrorMessage = "Unable to register Chromecast control channel."
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

            // Capture local playback truth at the moment we send PlayNow (to validate startPositionTicks correctness).
            let manager = Container.shared.mediaPlayerManager()
            let localSecondsTicks = manager.seconds.ticks
            let baseItemUserDataStartTicks = item.baseItem.userData?.playbackPositionTicks ?? 0
            let hasBaseItemUserDataStartTicks = item.baseItem.userData?.playbackPositionTicks != nil
            let deltaTicks = localSecondsTicks - baseItemUserDataStartTicks
            let localPlaybackStatus = switch manager.playbackRequestStatus {
            case .playing: "playing"
            case .paused: "paused"
            }

            // #region agent log: PlayNow payload indices + server URL
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "A",
                location: "GoogleCastSessionCoordinator.flushChromecastMessagesIfReady",
                message: "Sending PlayNow to Jellyfin Cast receiver",
                data: [
                    "sentIdentifyThisConnection": sentIdentifyThisConnection,
                    "baseItemID": item.baseItem.id ?? "",
                    "playSessionID": item.playSessionID,
                    "mediaSourceID": item.mediaSource.id ?? "",
                    "mediaSourceHasTranscodingURL": item.mediaSource.transcodingURL != nil,
                    "startPositionTicksToSend": localSecondsTicks,
                    "baseItemUserDataStartPositionTicks": baseItemUserDataStartTicks,
                    "hasBaseItemUserDataStartPositionTicks": hasBaseItemUserDataStartTicks,
                    "localSecondsTicks": localSecondsTicks,
                    "localPlaybackRequestStatus": localPlaybackStatus,
                    "startPositionTicksDeltaTicks": deltaTicks,
                    "selectedAudioStreamIndex": item.selectedAudioStreamIndex ?? -1,
                    "selectedSubtitleStreamIndex": item.selectedSubtitleStreamIndex ?? -1,
                    "audioStreamIndexForPlaybackInfo": audioIndex,
                    "subtitleStreamIndexForPlaybackInfo": subtitleIndex,
                    "audioStreamsCount": item.audioStreams.count,
                    "audioStreamIndexes": item.audioStreams.map { $0.index ?? -1 },
                    "videoStreamsCount": item.videoStreams.count,
                    "videoStreamIndexes": item.videoStreams.map { $0.index ?? -1 },
                    "subtitleStreamsCount": item.subtitleStreams.count,
                    "subtitleStreamIndexes": item.subtitleStreams.map { $0.index ?? -1 },
                    "serverAddress": context.serverAddress,
                    "serverId": context.serverId
                ]
            )
            // #endregion

            let json = try JellyfinCastOutboundMessageEncoder.playNowJSON(
                baseItem: item.baseItem,
                mediaSource: item.mediaSource,
                audioStreamIndex: audioIndex,
                subtitleStreamIndex: subtitleIndex,
                startPositionTicks: localSecondsTicks,
                context: context
            )
            try postJSON(json)
            lastPlayNowSignature = signature
            lastChromecastInboundPositionTicks = localSecondsTicks
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

            // #region agent log: transport Pause/Unpause
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "L",
                location: "GoogleCastSessionCoordinator.mirrorPlaybackRequestToChromecast",
                message: "Sending transport command",
                data: [
                    "command": command,
                    "statusRoutesToCast": routesPlaybackControlsToChromecast,
                    "lastPlayNowSignaturePresent": lastPlayNowSignature != nil,
                    "serverId": context.serverId
                ]
            )
            // #endregion

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

            // #region agent log: transport Seek
            ChromecastNDJSONDebugLogger.log(
                hypothesisId: "L",
                location: "GoogleCastSessionCoordinator.sendChromecastSeekWhenControlling",
                message: "Sending transport Seek",
                data: [
                    "positionSeconds": positionSeconds,
                    "clampedSeconds": clamped,
                    "serverId": context.serverId
                ]
            )
            // #endregion

            let json = try JellyfinCastOutboundMessageEncoder.transportCommandJSON(
                command: "Seek",
                options: ["position": clamped],
                context: context
            )
            try postJSON(json)
        } catch {}
    }

    private func pauseLocalPlaybackWhileChromecastPlays() {
        // #region agent log: pause local VLC when TV should drive
        ChromecastNDJSONDebugLogger.log(
            hypothesisId: "M",
            location: "GoogleCastSessionCoordinator.pauseLocalPlaybackWhileChromecastPlays",
            message: "Pausing local VLC proxy (Cast should drive)"
        )
        // #endregion
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
        if ns.domain == NSURLErrorDomain || description.localizedCaseInsensitiveContains("network") {
            return "\(description)\n\nIf Cast devices are missing, check Wi‑Fi and allow Local Network access for this app in Settings."
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
            let wasChromecastPlayback = self.lastPlayNowSignature != nil
            if let ch = self.connectSDKChannel {
                _ = session.remove(ch)
            }
            self.connectSDKChannel = nil
            self.sentIdentifyThisConnection = false
            self.lastPlayNowSignature = nil
            self.pendingChromecastPlaybackItem = nil
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
