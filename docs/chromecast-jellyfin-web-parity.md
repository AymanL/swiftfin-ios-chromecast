# jellyfin-web ↔ Swiftfin iOS Cast parity

Jellyfin’s **web sender** does **not** start TV playback with a standard Google Cast `LOAD` of a `contentId` URL. The **Jellyfin receiver** expects control traffic on the custom namespace **`urn:x-cast:com.connectsdk`**, with JSON payloads shaped like **Connect SDK** messages.

Reference: [jellyfin-web `src/plugins/chromecastPlayer/plugin.js`](https://github.com/jellyfin/jellyfin-web/blob/master/src/plugins/chromecastPlayer/plugin.js) (`messageNamespace`, `sendMessage`, `Identify`, `PlayNow`, `loadMedia` item trimming).

## Message sequence

| Step | jellyfin-web (conceptual) | Swiftfin iOS |
|------|---------------------------|--------------|
| 1 | User starts / joins a Cast session; sender obtains a session to the Jellyfin receiver app. | `GCKSessionManager` session start / resume → `GoogleCastSessionCoordinator.sessionManager(_:didStart:)` / `didResumeCastSession`. |
| 2 | Register a custom message channel for `urn:x-cast:com.connectsdk`. | `JellyfinConnectSDKCastChannel` (`GCKCastChannel` with `JellyfinCastConnectSDK.namespace`) added via `GCKCastSession.add(_:)`. |
| 3 | When the channel is writable, send **`Identify`** with merged auth/session fields and empty `options`. | `flushChromecastMessagesIfReady()` → `JellyfinCastOutboundMessageEncoder.identifyJSON(context:)`. |
| 4 | To play, trim the current item to a small stub (`Id`, `ServerId`, `Name`, `Type`, `MediaType`, `IsFolder`) and send **`PlayNow`** with play options (`items`, `startPositionTicks`, `mediaSourceId`, stream indices, `startIndex`) plus the same merged auth fields as `Identify`. | After `MediaPlayerItem` is resolved (Situation A), `queueChromecastLoad` → `playNowJSON(baseItem:mediaSource:audioStreamIndex:subtitleStreamIndex:context:)`. |
| 4b | Transport: **`Pause`**, **`Unpause`**, **`Seek`** (`options.position` in **seconds**), same root merge as other commands. | `mirrorPlaybackRequestToChromecast` / `sendChromecastSeekWhenControlling` → `transportCommandJSON`. |
| 5 | Server address for the receiver must be reachable from the **Chromecast** (not loopback from the TV’s perspective). | `JellyfinCastServerAddressResolver.serverURLStringForChromecast` uses the client URL or, for localhost, Jellyfin `PublicSystemInfo.localAddress`. |

## Root JSON keys (both commands)

Aligned with web’s `sendMessage` merge: `command`, `options`, `userId`, `deviceId`, `accessToken`, `serverAddress`, `serverId`, optional `serverVersion`, optional `receiverName`.

Implementation: `JellyfinCastOutboundMessageEncoder.jsonString(command:options:context:)`.

## Not used for Jellyfin TV playback (this path)

- **`GCKRemoteMediaClient.loadMedia`** with `GCKMediaInformation` as the primary way to pass a stream URL — the Jellyfin receiver is driven by **`PlayNow`** + API calls from the receiver, not by a generic media `LOAD` of the direct file URL.

Phase 4 may still use `GCKRemoteMediaClient` for status or future hybrid flows; Phase 3 targets **receiver-compatible `Identify` + `PlayNow`** only.
