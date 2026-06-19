# Video Playback Pipeline — Plain Language

## The Big Picture

The app is a Twitter-like feed where tweets can contain videos. Videos are stored on IPFS (a decentralized network, often slow). The challenge: play videos smoothly in a scrolling feed when the source is slow and unreliable.

The system has 4 layers working together:

---

## Layer 1: The Feed (what the user sees)

When a tweet with a video scrolls onto screen:

1. **Show a thumbnail first** — check if we have a cached frame from a previous viewing. If yes, show it immediately. If not, show a black rectangle with a spinner.

2. **Wait 0.3 seconds before loading the player** — if the user is scrolling fast, don't waste resources creating players for cells that fly by.

3. **Register with the coordinator** — tell the "traffic cop" (VideoPlaybackCoordinator) that a new video is visible and ready to play.

---

## Layer 2: The Coordinator (the traffic cop)

Only **one video plays at a time** in each feed. The coordinator decides which one:

- **Scrolling down** → pick the **topmost** visible video (the one the user is most likely reading)
- **Scrolling up** → pick the **bottommost** visible video (the one that just appeared)

When the coordinator picks a primary:
1. **Stop** any previously playing video
2. **Tell the proxy server** which video is primary (so it gets bandwidth priority)
3. **Send a "play" command** to the chosen video cell

If the primary video gets stuck (hasn't actually played for 15 seconds), the coordinator picks a different one.

**Directional preload budget:** The coordinator pre-creates only the next likely off-screen player after scrolling has stopped. Main, standard, and profile feeds use 1 directional player preload.

**Current business rules:**
- Visibility is measured at the media cell level, not the tweet row level. A partially visible image/video can load its cover/player, but off-screen media should stop network work.
- When scrolling starts, pending directional video and image preloads are cancelled. On-screen video work stays protected.
- While scrolling is active, directional video preloads do not start. They resume only after scroll stop or initial load.
- Directional preloads are for invisible media only. Visible media loads through its own visible-cell path.
- Primary playback is foreground work. It gets network priority over visible non-primary media and all preloads.
- Invisible video/image preloads may start only when the selected visible primary is stable enough: actually playing or recently playing. If the primary is still loading, buffering, or recovering, directional preloads pause/cancel.
- If a feed player is released or rebuilt to save memory, keep a last-frame cover when possible. Once the attached player has displayable content, remove any stale cover before playback starts.
- On first HLS access, race `master.m3u8` and `playlist.m3u8`; use whichever valid playlist responds first.

---

## Layer 3: The Video Cell (MediaCellUIView)

When the cell receives a "play" command, it goes through a state machine:

```
noContent → thumbnail → playerLoading → playerReady → playing
                                                         ↓
                                                       paused
```

**Getting a player** has two tiers:
- **Fast path (sync cache)**: If this video was played before in this session, the player is cached in memory. Grab it instantly.
- **Slow path (async creation)**: Ask `SharedAssetCache` to create a new `AVPlayer`. This involves resolving the HLS URL, starting the local proxy server, and creating a player item that points to `http://localhost:8080/ipfs/{videoID}/...`.

**Setting up the player** follows a strict 5-step sequence:
1. Pause and assign the player to this cell
2. Register a callback for when the first video frame renders
3. Set up KVO observers (to watch for status changes)
4. Attach the player to the display layer (this may immediately show a cached frame)
5. If the player already has data loaded, play immediately

**The play gate** (`requestPlaybackStartIfNeeded`) has 3 guards before calling `player.play()`:
- The coordinator must want this cell to play
- The cell must be visible on screen
- The player item must be in `.readyToPlay` status (not still loading or failed)

**After play() is called**, the system watches two KVO signals:
- **`timeControlStatus == .playing`**: Actual frames are rendering → stop spinner, remove the cover, show real video
- **`timeControlStatus == .waitingToPlayAtSpecifiedRate`**: Buffering → show spinner
- **`item.status == .failed`**: Something broke → clean up, show retry button

---

## Layer 4: The Proxy Server (LocalHTTPServer)

AVPlayer doesn't talk to IPFS directly. A local HTTP server on `localhost:8080` sits in between, providing caching, deduplication, and bandwidth management.

**For HLS videos** (most videos), AVPlayer requests:
1. A **playlist** (`.m3u8`) — lists all the video segments
2. Multiple **segments** (`.ts`) — each is 2-10 seconds of video, 1-6 MB

**When a segment is requested:**

```
AVPlayer request → localhost proxy → check disk cache →
  HIT:  serve from disk (instant)
  MISS: download from IPFS (slow) → stream to AVPlayer as bytes arrive
                                   → also save to disk for next time
```

**Bandwidth management** (NodeConnectionPool): Each IPFS node gets a connection pool:
- The **primary video** gets priority — its downloads bypass the pool cap
- **Preloads** (non-primary videos loading in background) share 3 slots
- This prevents preloads from starving the video the user is actually watching

**Deduplication**: If AVPlayer requests the same segment that's already downloading:
- **Primary/fullscreen requests monitor download progress** instead of assuming a fast network. If the existing IPFS download is still receiving bytes, keep waiting and serve from disk when it completes. If it goes idle for about 3 seconds, or the primary has waited about 6 seconds, the primary request takes ownership so fullscreen receives bytes directly.
- **Non-primary requests poll longer** for the download to finish and the file to appear on disk
- Once on disk, serve from cache
- This prevents duplicate IPFS downloads and avoids a cancel-retry storm without stranding fullscreen behind a stale background cache fill

**IPFS rule of thumb**: treat slow as normal, not broken. Do not rebuild/retry a player or segment just because buffering lasts a few seconds. Only recover when there is no download progress or buffered-position progress for a grace window. When fullscreen is active, suspend feed preloads so the user's active video owns the scarce IPFS bandwidth.

**Segment streaming**: Unlike a normal download-then-serve approach, segments are **streamed in real-time** — each chunk from IPFS is immediately forwarded to AVPlayer. This means the first video frame can render after just ~200KB instead of waiting for the full 5MB segment.

---

## What Happens During Scroll

| Event | What happens |
|---|---|
| Media cell becomes visible | Register with coordinator, start loading cover/thumbnail, debounce player creation |
| User starts scrolling | Cancel pending directional image/video preloads, keep on-screen video work protected |
| User is still scrolling | Do not start new directional video preloads |
| Scroll stops | If the primary is stable, start the next likely invisible directional video preload and nearby invisible image preloads |
| Coordinator selects this cell | Send play command, set bandwidth priority |
| Media cell scrolls off screen | Pause player, cancel network downloads, save position, unregister from coordinator |
| User scrolls back to same cell | Reclaim cached player (instant), resume from saved position |
| User taps video | Loan player to fullscreen view, pause feed playback |
| User closes fullscreen | Reclaim loaned player, resume in feed |

---

## Complete Flow: Cell Appears → Video Playing

```
Cell appears on screen
  → configure() → setupVideoCell() [thumbnail + debounce 0.3s]
  → didMoveToWindow() → setVisible(true) [register delegate with coordinator]
  → Coordinator: registerDelegate() → scheduleStartPrimary()
  → identifyPrimaryVideo() selects topmost/bottommost visible video
  → startPrimaryVideoPlayback()
     → setPrimaryMediaID() [bandwidth priority]
     → delegate.shouldPlayVideo() → handleCoordinatorPlayCommand()
        → acquirePlayer()
           → TIER 1: VideoStateCache sync hit → configurePlayer()
           → TIER 2: SharedAssetCache.getOrCreatePlayer()
              → createPlayerNow()
                 → HLS: CachingPlayerItem → localhost proxy URL → AVPlayer
                 → Progressive: registerAndGetURL → localhost proxy URL → AVPlayer
              → configurePlayer()
                 → preparePlayerForConfiguration() [.playerLoading]
                 → registerFirstFrameCallback()
                 → setupPlayerObservers() [status + timeControl KVO]
                 → attachPlayerToLayer()
                 → handleAlreadyReadyPlayer()
        → requestPlaybackStartIfNeeded() [3 guards]
           → actuallyStartPlayback()
              → player.play() [AVPlayer begins requesting data]
  → AVPlayer → localhost:{port}/ipfs/{mediaID}/...
     → LocalHTTPServer: handleGetRequest()
        → handleSegmentRequest()
           → Cache hit: serve from disk
           → Cache miss: NodeConnectionPool.acquireSlot()
              → fetchAndServe() → IPFS download
              → SegmentStreamDelegate: stream to AVPlayer + write to disk
  → KVO: timeControlStatus → .playing
     → spinner stops, cover is removed, video is playing
```

---

## Key Design Decisions

### Why a local proxy server?
AVPlayer only accepts HTTP(S) URLs. IPFS content needs custom fetching logic (retries, caching, deduplication). The proxy bridges this gap — AVPlayer thinks it's talking to a normal HTTP server, while the proxy handles all IPFS complexity behind the scenes.

### Why only one video at a time?
IPFS bandwidth is limited. Playing multiple videos simultaneously would cause all of them to buffer poorly. By focusing all bandwidth on one video (the primary), that video plays smoothly.

### Why the 0.3s debounce?
Creating an AVPlayer is expensive (memory, network, CPU). During fast scrolling, cells appear and disappear in under 100ms. The debounce prevents creating players for cells the user will never see.

### Why profile feeds use the same preload budget?
Profiles now use the same preload budget as the main feed: the current visible video plus 1 next likely directional off-screen AVPlayer, with at most 2 player creations in flight. This keeps profile scrolling behavior consistent with the main feed while keeping memory and IPFS bandwidth predictable.

Paused off-screen preload players are also not allowed to keep network streaming enabled after poster-frame work. This preserves a fast next-video path without letting background players continue downloading large media.

### Why stream segments instead of download-then-serve?
A typical HLS segment is 4-5MB. On IPFS, downloading the full segment might take 5-10 seconds. By streaming bytes as they arrive, AVPlayer can decode the first video frame after receiving just ~200KB of the segment's initial keyframe — cutting perceived latency from seconds to under a second.

### Why the KVO ordering matters?
When a cached player is attached to the display layer, AVPlayerLayer may immediately report "ready for display" from a stale GPU frame. If `player.play()` is called in that callback but KVO observers aren't set up yet, the `timeControlStatus → .playing` transition is lost and the spinner never stops. Setting up KVO observers *before* attaching the player ensures all transitions are captured.
