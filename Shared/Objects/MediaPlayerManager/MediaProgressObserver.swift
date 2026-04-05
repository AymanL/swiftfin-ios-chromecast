//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI

// TODO: respond properly to end of playback
//       - when item changes
// TODO: only send stop on manager stop, not per-item

class MediaProgressObserver: ViewModel, MediaPlayerObserver {

    weak var manager: MediaPlayerManager? {
        didSet {
            if let manager {
                setup(with: manager)
            }
        }
    }

    private let timer = PokeIntervalTimer()
    private var hasSentStart = false
    private var item: MediaPlayerItem?
    private var lastPlaybackRequestStatus: MediaPlayerManager.PlaybackRequestStatus = .playing

    init(item: MediaPlayerItem) {
        self.item = item
        super.init()
    }

    private func sendReport() {
        guard let item else { return }

        switch lastPlaybackRequestStatus {
        case .playing:
            if hasSentStart {
                sendProgressReport(for: item, seconds: manager?.seconds)
            } else {
                sendStartReport(for: item, seconds: manager?.seconds)
            }
        case .paused:
            sendProgressReport(for: item, seconds: manager?.seconds, isPaused: true)
        }
    }

    private func setup(with manager: MediaPlayerManager) {
        cancellables = []

        timer.sink { [weak self] in
            self?.sendReport()
            self?.timer.poke()
        }
        .store(in: &cancellables)

        manager.actions
            .sink { [weak self] in self?.didReceive(action: $0) }
            .store(in: &cancellables)

        manager.$playbackItem
            .sink { [weak self] in self?.playbackItemDidChange($0) }
            .store(in: &cancellables)

        manager.$playbackRequestStatus
            .sink { [weak self] in self?.playbackRequestStatusDidChange($0) }
            .store(in: &cancellables)
    }

    private func playbackItemDidChange(_ newItem: MediaPlayerItem?) {
        timer.poke()

        if let item, newItem !== item {
            sendStopReport(for: item, seconds: manager?.seconds)

            self.item = newItem
            self.hasSentStart = false
            sendReport()
        }
    }

    private func playbackRequestStatusDidChange(_ newStatus: MediaPlayerManager.PlaybackRequestStatus) {
        timer.poke()
        lastPlaybackRequestStatus = newStatus
    }

    // TODO: respond to error
    // TODO: respond properly to ended
    private func didReceive(action: MediaPlayerManager._Action) {
        switch action {
        case .stop:
            if let item {
                // #region agent log: manager stop action snapshot
                do {
                    let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
                    if !FileManager.default.fileExists(atPath: logPath) {
                        FileManager.default.createFile(atPath: logPath, contents: nil)
                    }
                    let payload: [String: Any] = [
                        "sessionId": "071397",
                        "runId": "pre_fix",
                        "hypothesisId": "H4",
                        "location": "MediaProgressObserver.didReceive(action:.stop)",
                        "message": "Manager stop action fired; capture seconds at report time",
                        "data": [
                            "manager.seconds.ticks": NSNumber(value: manager?.seconds.ticks ?? 0),
                            "item.baseItem.id": item.baseItem.id ?? ""
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
                sendStopReport(for: item, seconds: manager?.seconds)
            }
            timer.stop()
            cancellables = []
            item = nil
        default: ()
        }
    }

    private func sendStartReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStartInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.itemID = item.baseItem.id
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackStart(info)
            let _ = try await userSession.client.send(request)

            self.hasSentStart = true
        }
    }

    private func sendStopReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStopInfo()
            info.itemID = item.baseItem.id
            info.mediaSourceID = item.mediaSource.id
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID

            // #region agent log: playback stopped report payload
            do {
                let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                let payload: [String: Any] = [
                    "sessionId": "071397",
                    "runId": "pre_fix",
                    "hypothesisId": "H4",
                    "location": "MediaProgressObserver.sendStopReport",
                    "message": "About to send PlaybackStopInfo",
                    "data": [
                        "positionTicks": NSNumber(value: info.positionTicks ?? 0),
                        "item.baseItem.id": item.baseItem.id ?? ""
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

            let request = Paths.reportPlaybackStopped(info)
            let _ = try await userSession.client.send(request)
        }
    }

    private func sendProgressReport(for item: MediaPlayerItem, seconds: Duration?, isPaused: Bool = false) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackProgressInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.isPaused = isPaused
            info.itemID = item.baseItem.id
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            if isPaused {
                // #region agent log: paused progress report payload
                do {
                    let logPath = "/Users/ayman/Documents/GitHub/PlexClone/.cursor/debug-071397.log"
                    if !FileManager.default.fileExists(atPath: logPath) {
                        FileManager.default.createFile(atPath: logPath, contents: nil)
                    }
                    let payload: [String: Any] = [
                        "sessionId": "071397",
                        "runId": "pre_fix",
                        "hypothesisId": "H2",
                        "location": "MediaProgressObserver.sendProgressReport(isPaused=true)",
                        "message": "About to send PlaybackProgressInfo (paused)",
                        "data": [
                            "positionTicks": NSNumber(value: info.positionTicks ?? 0),
                            "item.baseItem.id": item.baseItem.id ?? "",
                            "manager.seconds.isZero": NSNumber(value: (seconds?.ticks ?? 0) == 0)
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

            let request = Paths.reportPlaybackProgress(info)
            let _ = try await userSession.client.send(request)
        }
    }
}
