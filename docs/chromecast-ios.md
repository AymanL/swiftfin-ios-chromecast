# Chromecast (iOS sender) — fork notes

## Stable vs unstable Jellyfin receiver

Google Cast discovery uses a **receiver application ID**. Jellyfin ships two web receivers; IDs match **jellyfin-web** and server playback docs.

| Channel   | App ID (sender `GCKDiscoveryCriteria`) | Bonjour type (declared in `Info.plist`)   |
|-----------|----------------------------------------|-------------------------------------------|
| **Stable** (default) | `F007D354` | `_F007D354._googlecast._tcp` |
| **Unstable** (experimental) | `6F511C87` | `_6F511C87._googlecast._tcp` |

- **Use Stable** for normal servers and parity with production jellyfin-web.
- **Use Unstable** only when you intentionally run an experimental/master receiver build aligned with your server or web client.

**DEBUG builds:** Settings → Debug → **Use unstable Jellyfin Cast receiver ID**. **Force-quit and relaunch** the app so `AppDelegate` can reconfigure `GCKCastContext`. Release builds always use **Stable**.

## Phase 2 behavior (discover + connect)

- A **Cast** control appears in the **iPhone** video player chrome (next to the action buttons). It opens the Google Cast device UI.

## Phase 3 behavior (Situation A — TV playback)

- After **on-device playback is resolved** (same `MediaPlayerItem` / stream path as local play), the app sends Jellyfin **`Identify`** then **`PlayNow`** on the custom namespace **`urn:x-cast:com.connectsdk`**, matching **jellyfin-web** (not a generic `GCKRemoteMediaClient` media `LOAD` of a raw URL).
- **Local player:** VLC stays on-screen for metadata/controls, but after **`PlayNow`** the local stream is **paused** so the TV is the only decoder. **Play / pause** in Swiftfin sends **`Unpause` / `Pause`** to the receiver; **scrub** and **± jump** send **`Seek`** (seconds). This is **phone → TV** only; changing playback from the Google Cast UI or TV remote does not yet update Swiftfin’s UI (full bidirectional sync is later work).
- **Session for Cast:** If you see an error about **not being signed in**, Swiftfin retries resolving your saved user after refreshing the session cache. If it persists, return to the library and confirm you are signed in, then open the player again.

### Dismissing the video player while casting

- If a Cast session is **active**, leaving the player **does not** end Cast so the TV can keep playing. Use **Google’s Cast controls** or **Stop casting** on the device to end the session.
- If Cast is **not** active, dismissing the player still runs coordinator cleanup (same idea as Phase 2 — no orphaned channel state).

### jellyfin-web parity

See **[chromecast-jellyfin-web-parity.md](chromecast-jellyfin-web-parity.md)** for the step-by-step correspondence (web → Swift call sites) and root JSON keys.

## Self-hosting: published URL, HTTPS, and “black screen” checklist

The Chromecast must reach your Jellyfin server using a URL that works **from the TV’s network**, not only from the phone.

| Check | Why it matters |
|-------|----------------|
| **No localhost for the TV** | `http://127.0.0.1` or `http://localhost` on the phone is not valid for the Cast device. Swiftfin tries to substitute Jellyfin’s **LocalAddress** when the configured URL is loopback; if that fails, you’ll see an error explaining the limitation. Prefer a **LAN IP** (e.g. `http://192.168.x.x:8096`) or **hostname** the Chromecast can resolve. |
| **Same network / routing** | Phone and Chromecast are usually on the same Wi‑Fi. The server must be reachable from that LAN (no “phone VPN only” unless the TV path can see the server too). |
| **HTTPS / certificates** | If you use HTTPS, use a certificate the **receiver** trusts (same constraints as jellyfin-web Cast). Self-signed or internal CA issues often match “receiver connects but playback fails.” |
| **Reverse proxy** | Path prefixes, WebSocket upgrades, and **published** external URLs must match what Jellyfin and the receiver expect. Wrong `BaseUrl` / redirect loops break the receiver’s API calls. |
| **Compare with web** | If **jellyfin-web** Cast works from a browser on the same network against the same server, Swiftfin should be close; if web also fails, fix server URL / HTTPS / firewall first. |

**Symptoms:** Jellyfin splash on TV, spinner, or black screen with no audio — walk the table above before assuming an app bug.

**Audio on TV but no picture:** Often means Jellyfin received **wrong stream indices** for `PlaybackInfo` (e.g. VLC’s renumbered tracks were sent instead of API `MediaStream.Index`). Swiftfin maps the selected audio/subtitle tracks to Jellyfin indices before `PlayNow`; if this still happens, compare the same file in **jellyfin-web** Cast and check server / transcoding logs.

## Manual acceptance tests (physical iPhone + Chromecast)

Run on **Wi‑Fi** with a **Chromecast (3rd gen)** reference device. Simulator is unreliable for discovery.

### Phase 2 (connectivity)

| ID | Scenario | Pass |
|----|----------|------|
| M1 | Wi‑Fi on, Chromecast on | Cast button visible in player; device appears in Google’s picker. |
| M2 | Select device | Session starts; TV shows **Jellyfin** receiver UI (not the generic default media receiver). |
| M3 | Stable default | With unstable toggle **off** and fresh launch, M2 still passes. |
| M4 | No devices / wrong network | User gets a clear result (empty picker or error), not a silent failure. |
| M5 | Local Network denied | After denying local network for the app, attempting Cast yields a **Chromecast** alert with guidance; **Open Settings** works. |

### Phase 3 (LOAD / PlayNow path)

| ID | Scenario | Pass |
|----|----------|------|
| P3-A | Direct-play file, server reachable from TV with correct published URL | Start playback on phone, connect Cast, **TV plays video+audio** for several minutes. |
| P3-B | Different library item | TV loads the **current** item, not a stale first item. |
| P3-C | Disconnect Cast from Google UI or stop receiver | App remains usable; no crash. |
| P3-D | Bad URL / TV cannot reach server | Clear failure (coordinator error / message), not an endless silent spinner. |
| P3-E | HTTPS server | Works if jellyfin-web Cast works against the same server. |

## Automated regression

```bash
xcodebuild -scheme Swiftfin -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipMacroValidation test -only-testing:SwiftfinTests
```

Includes **ChromecastStubProxyTests**, **ChromecastCoordinatorTests**, and **JellyfinCastOutboundMessageEncoderTests** (Connect SDK JSON shape for `Identify` / `PlayNow`).

## Further reading

- Web parity detail: [chromecast-jellyfin-web-parity.md](chromecast-jellyfin-web-parity.md).
- Implementation plan: `plans/ios-chromecast-swiftfin.md` (repo root).
- Product context: `PRD.md` (Chromecast PRD).
