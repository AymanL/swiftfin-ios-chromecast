//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Foundation
import JellyfinAPI
import VLCUI

// TODO: proper error catching

typealias MediaPlayerManagerPublisher = LegacyEventPublisher<MediaPlayerManager?>

extension Scope {
    static let session = Cached()
}

extension Container {

    var mediaPlayerManagerPublisher: Factory<MediaPlayerManagerPublisher> {
        self { MediaPlayerManagerPublisher() }
            .singleton
    }

    var mediaPlayerManager: Factory<MediaPlayerManager> {
        self { @MainActor in
            .init(
                playbackItem: .init(
                    baseItem: .init(),
                    mediaSource: .init(),
                    playSessionID: "",
                    url: URL(string: "/")!
                )
            )
        }
        .scope(.session)
    }
}

import StatefulMacros

@MainActor
@Stateful
final class MediaPlayerManager: ViewModel {

    // MARK: - Chromecast (iOS sender hooks; set by `GoogleCastSessionCoordinator`)

    /// When non-nil and returns true, play/pause routes to Chromecast; local proxy stays paused to avoid dual playback.
    static var chromecastRoutesPlaybackControls: (@MainActor () -> Bool)?
    static var chromecastMirrorPlaybackRequest: (@MainActor (PlaybackRequestStatus) async -> Void)?
    static var chromecastMirrorSeekToSeconds: (@MainActor (Double) async -> Void)?

    @CasePathable
    enum Action {
        case ended
        case error
        case playNewItem(provider: MediaPlayerItemProvider)
        case setPlaybackRequestStatus(status: PlaybackRequestStatus)
        case setRate(rate: Float)
        case start
        case stop
        case togglePlayPause

        var transition: Transition {
            switch self {
            case .error:
                .to(.error)
                    .invalid(.stopped)
            case .playNewItem, .start:
                .to(.loadingItem, then: .playback)
                    .invalid(.stopped)
            case .stop:
                .to(.stopped)
            default:
                .none
                    .invalid(.stopped)
            }
        }
    }

    enum State {
        case error
        case initial
        case loadingItem
        case playback
        case stopped
    }

    /// A status indicating the player's request for media playback.
    enum PlaybackRequestStatus {

        /// The player requests media playback
        case playing

        /// The player is paused
        case paused
    }

    @Published
    var playbackItem: MediaPlayerItem? = nil {
        didSet {
            if let playbackItem {
                self.item = playbackItem.baseItem
                seconds = playbackItem.baseItem.startSeconds ?? .zero
                playbackItem.manager = self
                setSupplements()

                logger.info(
                    "Playing new item",
                    metadata: [
                        "itemID": .stringConvertible(playbackItem.baseItem.id ?? "Unknown"),
                        "itemTitle": .stringConvertible(playbackItem.baseItem.displayTitle),
                        "url": .stringConvertible(playbackItem.url.absoluteString),
                    ]
                )

                Task { _ = await playbackItem.previewImageProvider?.image(for: seconds) }
            }
        }
    }

    @Published
    private(set) var item: BaseItemDto
    @Published
    private(set) var playbackRequestStatus: PlaybackRequestStatus = .playing
    @Published
    var rate: Float = Defaults[.VideoPlayer.Playback.playbackRate] {
        didSet {
            Defaults[.VideoPlayer.Playback.playbackRate] = rate
        }
    }

    @Published
    var queue: AnyMediaPlayerQueue? = nil

    @Published
    var supplements: [any MediaPlayerSupplement] = []

    // TODO: replace with graph dependency package
    private func setSupplements() {
        var newSupplements: [any MediaPlayerSupplement] = []

        newSupplements.append(MediaInfoSupplement(item: item))

        if let chapters = item.fullChapterInfo, chapters.isNotEmpty {
            newSupplements.append(
                MediaChaptersSupplement(
                    chapters: chapters
                )
            )
        }

        if let queue {
            newSupplements.append(queue)
        }

        self.supplements = newSupplements
    }

    /// The current seconds media playback is set to.
    let secondsBox: PublishedBox<Duration> = .init(initialValue: .zero)

    var seconds: Duration {
        get { secondsBox.value }
        set { secondsBox.value = newValue }
    }

    /// Holds a weak reference to the current media player proxy.
    weak var proxy: (any MediaPlayerProxy)? {
        didSet {
            if var proxy {
                proxy.manager = self
            }
        }
    }

    // MARK: Chromecast (receiver → UI; seek mirror)

    /// Applies TV-reported state without echoing pause/unpause back to the receiver.
    @MainActor
    func applyChromecastInboundPlaybackState(positionTicks: Int?, isPaused: Bool?) {
        if let ticks = positionTicks {
            let d = Duration.ticks(ticks)
            if seconds != d {
                // Keep the scrubber / timestamps aligned with the TV only. Do not seek the local VLC proxy
                // while Cast drives playback (it stays paused); repeated `setSeconds` there can yield black
                // video or audio-only glitches on device even though the TV plays fine.
                seconds = d
            }
        }
        if let paused = isPaused {
            if paused, positionTicks == nil, playbackRequestStatus != .paused {
                // #region agent log: cast stop transitions local manager state
                do {
                    let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
                    if !FileManager.default.fileExists(atPath: logPath) {
                        FileManager.default.createFile(atPath: logPath, contents: nil)
                    }
                    let secondsTicks = NSNumber(value: seconds.ticks)
                    let payload: [String: Any] = [
                        "sessionId": "071397",
                        "runId": "pre_fix",
                        "hypothesisId": "H3",
                        "location": "MediaPlayerManager.applyChromecastInboundPlaybackState(isPaused=true, positionTicks=nil)",
                        "message": "Receiver paused via playbackstop path; capture manager seconds at transition to paused",
                        "data": [
                            "manager.seconds.ticks": secondsTicks
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
            }
            let target: PlaybackRequestStatus = paused ? .paused : .playing
            guard playbackRequestStatus != target else { return }
            playbackRequestStatus = target
            if let shouldRoute = Self.chromecastRoutesPlaybackControls, shouldRoute() {
                proxy?.pause()
            } else {
                switch target {
                case .paused:
                    proxy?.pause()
                case .playing:
                    proxy?.play()
                }
            }
        }
    }

    /// After Cast ends or the control channel is lost while the TV was driving playback.
    /// - Parameter lastTVPositionTicks: Last Jellyfin ticks reported by the receiver while casting; aligns local scrubber and VLC before
    /// resuming on-device playback.
    @MainActor
    func applyChromecastSessionEndedFromReceiver(lastTVPositionTicks: Int? = nil) {
        if let ticks = lastTVPositionTicks {
            let d = Duration.ticks(ticks)
            seconds = d
            proxy?.setSeconds(d)
        }

        // #region agent log: cast session end snapshot
        do {
            let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            let payload: [String: Any] = [
                "sessionId": "071397",
                "runId": "post_fix",
                "hypothesisId": "H4",
                "location": "MediaPlayerManager.applyChromecastSessionEndedFromReceiver",
                "message": "Cast ended from receiver; seconds after optional TV tick apply",
                "data": [
                    "lastTVPositionTicks": lastTVPositionTicks.map { NSNumber(value: $0) } ?? NSNull(),
                    "manager.seconds.ticks": NSNumber(value: seconds.ticks)
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
        playbackRequestStatus = .paused
        proxy?.pause()
    }

    @MainActor
    func mirrorChromecastSeekToTargetSecondsIfControlling(_ positionSeconds: Double) {
        guard let shouldRoute = Self.chromecastRoutesPlaybackControls, shouldRoute() else { return }
        Task {
            await Self.chromecastMirrorSeekToSeconds?(positionSeconds)
        }
    }

    @MainActor
    func mirrorChromecastSeekAfterLocalJump(delta: Duration) {
        guard let shouldRoute = Self.chromecastRoutesPlaybackControls, shouldRoute() else { return }
        let target = max(.zero, seconds + delta).seconds
        Task {
            await Self.chromecastMirrorSeekToSeconds?(target)
        }
    }

    private var itemBuildTask: AnyCancellable?

    private var initialMediaPlayerItemProvider: MediaPlayerItemProvider?

    // MARK: init

//    static let empty: MediaPlayerManager = .init()

//    override private init() {
//        self.item = .init()
//        self.state = .stopped
//        super.init()
//    }

    init(
        item: BaseItemDto,
        queue: (any MediaPlayerQueue)? = nil,
        mediaPlayerItemProvider: @escaping MediaPlayerItemProviderFunction
    ) {
        self.item = item
        self.queue = queue.map { AnyMediaPlayerQueue($0) }
        self.state = .loadingItem
        self.initialMediaPlayerItemProvider = .init(
            item: item,
            function: mediaPlayerItemProvider
        )
        super.init()

        self.queue?.manager = self
    }

    init(
        playbackItem: MediaPlayerItem,
        queue: (any MediaPlayerQueue)? = nil
    ) {
        self.item = playbackItem.baseItem
        self.queue = queue.map { AnyMediaPlayerQueue($0) }
        self.state = .playback
        super.init()

        self.queue?.manager = self
        self.playbackItem = playbackItem
    }

    @Function(\Action.Cases.ended)
    private func _ended() async throws {
        // TODO: change to observe given seconds against runtime
        //       instead of sent action?

        // Ended should represent natural ending of playback, which
        // is verifiable by given seconds being near item runtime.
        // VLC proxy will send ended early.
        guard let runtime = item.runtime else {
            await self.stop()
            return
        }
        let isNearEnd = (runtime - seconds) <= .seconds(1)

        guard isNearEnd else {
            // If not near end, ignore.
            return
        }

        if let nextItem = queue?.nextItem, Defaults[.VideoPlayer.autoPlayEnabled] {
            await self.playNewItem(provider: nextItem)
        }
    }

    @Function(\Action.Cases.error)
    private func onError(_ error: Error) async throws {
        if let playbackItem {
            logger.error(
                "Error while playing item",
                metadata: [
                    "error": .stringConvertible(error.localizedDescription),
                    "itemID": .stringConvertible(playbackItem.baseItem.id ?? "Unknown"),
                    "itemTitle": .stringConvertible(playbackItem.baseItem.displayTitle),
                    "url": .stringConvertible(playbackItem.url.absoluteString),
                ]
            )
        } else {
            logger.error(
                "Error with no playback item",
                metadata: [
                    "error": .stringConvertible(error.localizedDescription),
                    "itemID": .stringConvertible(item.id ?? "Unknown"),
                    "itemTitle": .stringConvertible(item.displayTitle),
                ]
            )
        }

        proxy?.stop()
        Container.shared.mediaPlayerManager.reset()
    }

    @Function(\Action.Cases.playNewItem)
    private func _playNewItem(_ provider: MediaPlayerItemProvider) async throws {
        item = provider.item
        setSupplements()
        proxy?.stop()
        playbackItem = try await provider()
    }

    @Function(\Action.Cases.setPlaybackRequestStatus)
    private func set(_ status: PlaybackRequestStatus) {
        if self.playbackRequestStatus != status {
            self.playbackRequestStatus = status

            if let shouldRoute = Self.chromecastRoutesPlaybackControls, shouldRoute() {
                Task {
                    await Self.chromecastMirrorPlaybackRequest?(status)
                }
                switch status {
                case .paused:
                    proxy?.pause()
                case .playing:
                    // TV resumes via `Unpause`; keep local VLC paused so the phone is not a second player.
                    proxy?.pause()
                }
                return
            }

            switch status {
            case .paused:
                proxy?.pause()
            case .playing:
                proxy?.play()
            }
        }
    }

    @Function(\Action.Cases.setRate)
    private func set(_ rate: Float) {
        if self.rate != rate {
            self.rate = rate
        }
    }

    @Function(\Action.Cases.start)
    private func _start() async throws {
        guard let initialMediaPlayerItemProvider else {
            await self.stop()
            return
        }
        self.initialMediaPlayerItemProvider = nil
        playbackItem = try await initialMediaPlayerItemProvider()
    }

    @Function(\Action.Cases.stop)
    private func _stop() async throws {
        await self.cancel()

        // TODO: remove playback item?
        //       - check that observers would respond correctly to stopping
        itemBuildTask?.cancel()
        proxy?.stop()
        Container.shared.mediaPlayerManager.reset()
    }

    @Function(\Action.Cases.togglePlayPause)
    private func _togglePlayPause() {
        switch playbackRequestStatus {
        case .playing:
            setPlaybackRequestStatus(status: .paused)
        case .paused:
            setPlaybackRequestStatus(status: .playing)
        }
    }
}
