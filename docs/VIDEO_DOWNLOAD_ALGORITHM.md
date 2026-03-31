# Video Download Algorithm

**Last Updated**: March 2026
**Applies to**: UIKit-based feed (MediaCellUIView, VideoPlaybackCoordinator, LocalHTTPServer proxy)

## Overview

Video downloads are proxied through a local HTTP server (NWConnection-based TCP proxy on localhost:8081). AVPlayer never fetches from the network directly — all requests go through `LocalHTTPServer`, which handles caching, concurrency control, priority, and byte-range resume.

Two video formats are supported:
- **HLS** (`.hls_video`): m3u8 playlists + .ts segments, streamed in real-time
- **Progressive** (`.video`): MP4 files, served via byte-range requests with resume

---

## 1. Trigger: Cell Visibility

```
MediaCellUIView.setVisible(true)
  → configurePlayer()
  → SharedAssetCache.getOrCreatePlayer(url, mediaType, isHighPriority: true)
```

`SharedAssetCache` checks in order:
1. **Blacklist** — skip permanently failed videos
2. **Player cache** — reuse existing AVPlayer (instant)
3. **In-flight creation** — join existing async creation (dedup)
4. **Concurrency gate** — `canStartCreation()`: max 2 concurrent, 1 slot reserved for visible cells

Then based on `MediaType`:
- HLS → `resolveHLSURL()` → `CachingPlayerItem` → register with `LocalHTTPServer`
- Progressive → `LocalHTTPServer.registerAndGetURL()` → `AVURLAsset` with localhost proxy URL

---

## 2. Video Playback Coordination

`VideoPlaybackCoordinator` decides which video plays:

```
registerDelegate(cell, identifier)
  → adds to onScreenMediaCells
  → if phase == .idle: startPrimaryVideoPlayback()  // DIRECT, no debounce
```

`startPrimaryVideoPlayback()`:
1. Pick topmost (scroll-down) or bottommost (scroll-up) visible video with a delegate
2. `setPrimaryMediaID(mid)` — immediately unblocks this video's downloads
3. Schedule `cancelDownloadsTimer` (1.0s debounce) — cancel non-primary downloads
4. Call `delegate.shouldPlayVideo()`

**Debounce paths**:
- `scheduleStartPrimary()` — 0.3s debounce, used when primary leaves screen via scroll
- `registerDelegate()` — NO debounce (calls `startPrimaryVideoPlayback()` directly)

---

## 3. Progressive Download Flow

```
AVPlayer → GET http://localhost:8081/ipfs/{mediaID}
  → handleRequest() → handleProgressiveVideoRequest()
```

### 3.1 Cache Check
- Cache directory: `~/Library/Caches/{mediaID}/`
- Files: `video.mp4` (data), `video.contiguous` (contiguous byte count from offset 0), `video.meta` (total size)
- If requested byte range is within contiguous cached size → serve from disk, no network

### 3.2 Network Fetch
```
1. canStartVideoDownload(for: mediaID)  // max 2 concurrent mediaIDs
2. HEAD request → get total file size
3. Send HTTP 206 Partial Content headers to AVPlayer
4. Serve cached bytes first (if any) via streamFileRange()
5. Start network stream from cached end:
   - URLSession + StreamingDownloadDelegate
   - Session key: "{mediaID}_{byteOffset}" (dedup key)
   - Forward data chunks to NWConnection immediately (AVPlayer can render)
   - Write contiguous bytes to disk cache (50MB cap per video)
6. Send TCP FIN on completion (critical: without this AVPlayer waits forever)
```

### 3.3 Byte-Range Resume
On network failure (timeout, interruption):
- Cache file retains contiguous bytes already written
- Next AVPlayer request starts from cached end
- No re-download of already-cached data

### 3.4 Deduplication
- `streamingSessions[sessionKey]` dict prevents two identical byte-range downloads
- Session key = `"{mediaID}_{streamStart}"` (e.g., `QmS7eJeG_0`)
- If key exists → skip, close connection
- If key was removed (cancelled) → new download starts (potential race window)

---

## 4. HLS Download Flow

### 4.1 Playlist Requests
```
AVPlayer → GET http://localhost:8081/ipfs/{mediaID}/master.m3u8
  → handlePlaylistRequest()
  → Check disk cache (~/Caches/{mediaID}/master.m3u8)
  → If miss: fetch from IPFS, cache to disk
  → Rewrite segment URLs to localhost proxy
  → Inject #EXT-X-ENDLIST (prevents AVPlayer from polling as live stream)
  → Serve to AVPlayer
```

### 4.2 Segment Requests (Two-Stage Pipeline)
```
AVPlayer → GET http://localhost:8081/ipfs/{mediaID}/480p/segment000.ts
  → handleRequest() → handleSegmentRequest()  [Stage 1: dedup + tracking]
  → fetchAndServe()
  → streamSegmentAndServe()                   [Stage 2: actual download]
```

**Stage 1 — `handleSegmentRequest()`**:
1. Check disk cache → serve immediately if hit
2. Dedup via `ActiveDownloadsActor`:
   - Key = cache file path (e.g., `~/Caches/{mediaID}/480p/segment000.ts`)
   - If another request is downloading same segment → poll 0.5s × 240 = 120s max
   - If `isMediaIDCancelled` → abort (player was cleared)
3. Mark download active: `activeDownloadsActor.markDownloadStarted(downloadKey)`
4. `trackVideoDownloadStarted(for: mediaID)` — adds to `downloadingMediaIDs` counter
5. Call `fetchAndServe()` which redirects `.ts` GET requests to `streamSegmentAndServe()`

**Stage 2 — `streamSegmentAndServe()`**:
1. Session key: `"{mediaID}/stream/{relativePath}"` (e.g., `QmAbc/stream/480p/segment000.ts`)
2. Dedup via `streamingSessions[sessionKey]` — skip if already downloading
3. `SegmentStreamDelegate` streams bytes to NWConnection as they arrive:
   - AVPlayer can render first frame after ~100-300KB (no wait for full 4-5MB segment)
   - Accumulate full segment in memory buffer
4. On completion: write full segment to disk cache, call `trackVideoDownloadCompleted(for: mediaID)`

### 4.3 HLS URL Resolution
`resolveHLSURL()` in SharedAssetCache:
- Probes `master.m3u8` and `playlist.m3u8` in parallel (`async let`)
- HEAD request with 8s timeout
- Returns whichever resolves first (worst case 8s instead of 16s sequential)
- Caches resolved filename for future use

---

## 5. Concurrency Control

### 5.1 Video Download Gating
```swift
canStartVideoDownload(for mediaID) -> Bool:
  if isPrimary:              return true   // never throttled
  if mediaID already in dict: return true  // keep existing slot
  if dict.count < 2:         return true   // slot available
  else:                       BLOCKED      // log "⛔ [CONCURRENCY]"
```

- `downloadingMediaIDs: [String: Int]` — maps mediaID to active download count
- `maxConcurrentVideoDownloads = 2`
- Progressive downloads are gated by `canStartVideoDownload()`
- **HLS segments bypass this gate** (blocking causes AVPlayer -12889 error)
- HLS segments still call `trackVideoDownloadStarted()`, inflating the counter

### 5.2 Player Creation Gating
```swift
canStartCreation(isHighPriority) -> Bool:
  if isHighPriority: return activeCreations < 2  // visible cells
  else:              return activeCreations < 1  // preloads (reserve slot for visible)
```

### 5.3 `isDownloadAllowed()` — Dead Code
```swift
isDownloadAllowed(for mediaID) -> Bool:
  if no primary set: return true
  return mediaID == primary
```
Defined but **never called**. Was intended to block non-primary HLS segment downloads.

---

## 6. Priority System

### 6.1 Primary Video Bypass
`setPrimaryMediaID(mid)` — called immediately when coordinator selects primary:
- Primary video's segment requests bypass `canStartVideoDownload()` gate
- No waiting for concurrent slots

### 6.2 Cancel Non-Primary Downloads
`cancelNonPrimaryDownloads(primaryMediaID, protectedMediaIDs)`:
1. `activeDownloadsActor.cancelTasksExcept(keepMediaIDs)` — cancel HLS dedup tracking
2. Cancel `streamingSessions` for non-primary, non-protected videos
3. `clearVideoDownloadTracking(except: keepMediaIDs)` — reset `downloadingMediaIDs`

Protected videos = primary + on-screen cells (cancelling on-screen breaks proxy connections → -1005 errors)

### 6.3 Cancel Debounce
```swift
// In startPrimaryVideoPlayback():
cancelDownloadsTimer?.invalidate()
cancelDownloadsTimer = Timer(timeInterval: 1.0) {
    cancelNonPrimaryDownloads(primaryMid, protectedMids)
}
```
- 1.0s debounce prevents killing downloads when primary changes rapidly during fast scroll
- **Known issue**: during continuous fast scrolling, timer keeps resetting → never fires → downloads accumulate

---

## 7. Preloading System

Three preload mechanisms work together:

### 7.1 Scroll-Direction Preload
`preloadVideosInScrollDirection()` — triggered by scroll events (0.3s throttle):

```
Next 1 video in scroll direction → preloadPlayer() (full AVPlayer + thumbnail)
Next 1 video after that          → preloadAsset()  (asset metadata only)
```

- Preloaded players get `preferredForwardBufferDuration = 10` (10 seconds of data)
- When cell becomes visible: reset to `preferredForwardBufferDuration = 0` (AVPlayer default)
- Preloaded players are paused immediately, cached for instant use

### 7.2 Spatial Nearby Preload
`updateNearbyTweetsForPreloading(nearbyTweetIds)` — called from TweetTableViewController:

```
Visible rows: [5, 6, 7, 8]
Preload buffer: 5 rows
Preload zone: rows [0-4] + [9-13]  (excluding visible)
```

- Scans 5 rows above and below visible area
- Any video tweets in that zone get `preloadAsset()` (asset-only, no player)
- Uses spatial row proximity (not allVideos index, which may skip non-video tweets)

### 7.3 Slot-Available Restart
`restartNearbyVideoPreloads()` — triggered by `.videoCreationSlotsAvailable` notification:

- When active player creations finish and slots free up
- Re-evaluates next 2 videos in scroll direction
- Only preloads videos with no cache at all (no memory player, no disk cache)
- Asset-only preload (lightweight)

### 7.4 Eviction Protection
Preloaded players are protected from LRU cache eviction:
```swift
foregroundProtectedMids = visibleVideoMids ∪ preloadedPlayerMids
```
- `visibleVideoMids` — currently playing/visible
- `preloadedPlayerMids` — top upcoming in scroll direction

---

## 8. Known Issues (March 2026)

### 8.1 `registerDelegate` Bypasses Debounce
`registerDelegate()` calls `startPrimaryVideoPlayback()` directly when `phase == .idle`, skipping the 0.3s `scheduleStartPrimary()` debounce. During fast scrolling, every new cell triggers this, causing rapid primary switches.

### 8.2 Cancel Debounce Never Fires During Fast Scroll
The 1.0s `cancelDownloadsTimer` is invalidated and rescheduled on every `startPrimaryVideoPlayback()` call. During fast scrolling, primary changes every ~0.3s, so the timer never fires. `downloadingMediaIDs` grows unbounded (observed: 12 mediaIDs).

### 8.3 HLS Segments Inflate Concurrency Counter
HLS segments bypass `canStartVideoDownload()` but still call `trackVideoDownloadStarted()`. During fast scrolling, this inflates `downloadingMediaIDs` to 12+ entries, permanently blocking progressive downloads.

### 8.4 `isDownloadAllowed()` Never Called
Was intended to block non-primary video downloads. Currently dead code — HLS segments from scrolled-past videos download freely.

### 8.5 Progressive Download Dedup Race
When a progressive download is cancelled (priority) and the session is removed from `streamingSessions`, a new request arriving before cleanup completes can bypass the dedup check, creating duplicate concurrent downloads to the same file. Observed: two simultaneous byte-0 downloads for QmS7eJeG.

---

## Appendix: Complete Flow Diagram

```
                        ┌─────────────────────────────┐
                        │   MediaCellUIView.setVisible  │
                        │          (true)               │
                        └──────────┬──────────────────┘
                                   │
                        ┌──────────▼──────────────────┐
                        │   SharedAssetCache            │
                        │   getOrCreatePlayer()         │
                        │                               │
                        │  1. Check blacklist            │
                        │  2. Check player cache         │
                        │  3. Check in-flight (dedup)    │
                        │  4. Concurrency gate (max 2)   │
                        └──────────┬──────────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │ HLS                         │ Progressive
                    ▼                             ▼
          resolveHLSURL()              registerAndGetURL()
          (probe m3u8)                 (get localhost URL)
                    │                             │
                    ▼                             ▼
          CachingPlayerItem              AVURLAsset
          registered with                (localhost:8081/ipfs/...)
          LocalHTTPServer
                    │                             │
                    └──────────────┬──────────────┘
                                   │
                        ┌──────────▼──────────────────┐
                        │  VideoPlaybackCoordinator     │
                        │  startPrimaryVideoPlayback()  │
                        │                               │
                        │  → setPrimaryMediaID()        │
                        │  → cancelDownloadsTimer(1.0s) │
                        │  → delegate.shouldPlayVideo() │
                        └──────────┬──────────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │ AVPlayer requests           │
                    │ through proxy               │
                    ▼                             ▼
         ┌─────────────────┐          ┌───────────────────┐
         │  HLS Segments    │          │  Progressive MP4   │
         │                  │          │                    │
         │ handleSegment    │          │ handleProgressive  │
         │  Request()       │          │  VideoRequest()    │
         │       │          │          │       │            │
         │  ┌────▼──────┐   │          │  ┌────▼──────┐     │
         │  │ Disk cache?│   │          │  │ Disk cache?│     │
         │  │ → serve    │   │          │  │ → serve    │     │
         │  └────┬──────┘   │          │  └────┬──────┘     │
         │       │ miss     │          │       │ miss       │
         │  ┌────▼──────┐   │          │  ┌────▼──────────┐ │
         │  │ Dedup via  │   │          │  │ canStartVideo │ │
         │  │ Actor      │   │          │  │ Download()?   │ │
         │  └────┬──────┘   │          │  └────┬──────────┘ │
         │       │          │          │       │            │
         │  ┌────▼────────┐ │          │  ┌────▼──────────┐ │
         │  │ streamSeg-  │ │          │  │ Streaming     │ │
         │  │ mentAndServe│ │          │  │ Download      │ │
         │  │ (real-time) │ │          │  │ Delegate      │ │
         │  └─────────────┘ │          │  └───────────────┘ │
         └─────────────────┘          └───────────────────┘
                    │                             │
                    └──────────────┬──────────────┘
                                   │
                        ┌──────────▼──────────────────┐
                        │  Bytes → NWConnection         │
                        │  (forwarded immediately)      │
                        │                               │
                        │  Bytes → Disk cache           │
                        │  (contiguous write)           │
                        │                               │
                        │  TCP FIN on completion        │
                        └──────────────────────────────┘
```

### Preload Pipeline (parallel to playback)

```
Scroll event (0.3s throttle)
  │
  ├─→ preloadVideosInScrollDirection()
  │     Next 1 video → preloadPlayer() (full AVPlayer, 10s buffer cap)
  │     Next 1 video → preloadAsset()  (metadata only)
  │
  ├─→ updateNearbyTweetsForPreloading()
  │     ±5 rows around visible → preloadAsset() for any video tweets
  │
  └─→ restartNearbyVideoPreloads()  (when creation slots free up)
        Next 2 uncached videos → preloadAsset()
```
