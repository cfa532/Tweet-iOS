# Video Player Comprehensive Algorithm

## Components
- **MediaCellUIView**: UIKit cell managing AVPlayer lifecycle, KVO observers, state machine
- **VideoPlaybackCoordinator**: Per-feed coordinator selecting primary video, managing visibility
- **SharedAssetCache**: Player creation, caching, HLS resolution, memory management
- **LocalHTTPServer**: Transparent caching proxy (see localhttpserver-algorithm.md)

## State Machine (MediaCellUIView)
```
noContent → thumbnail → playerLoading → playerReady → playing ⇄ paused
                                    ↘ failed (retry button)
```
- `transitionTo()` is single source of truth — controls imageView, videoPlayerView, spinner, retryButton visibility
- `.playerLoading`: Shows thumbnail (prevents black flash during buffering)
- `.playerReady`: First frame rendered, paused, ready for coordinator command
- `.playing`: Video layer visible, thumbnail hidden

## Player Acquisition (3 tiers)

### Tier 1: Synchronous Cache (VideoStateCache)
- `VideoStateCache.shared.getCachedState(for: mid)` → instant reuse
- Validates: `currentItem != nil`, seeks finished videos to zero

### Tier 2: Async Loading (SharedAssetCache)
- `acquirePlayerAsync()` → `SharedAssetCache.shared.getOrCreatePlayer()`
- On success: `configurePlayer(newPlayer)` on MainActor
- On blacklist error (code -2): transition to `.thumbnail`, no retry
- On network error: `handleVideoLoadFailure()`

### Tier 3: SharedAssetCache.getOrCreatePlayer()
1. **Blacklist check**: Throw error -2 if blacklisted
2. **Cached player**: Health check (currentItem != nil, not failed, no errors)
3. **In-flight dedup**: Join existing `inFlightPlayerCreations[mediaID]`
4. **Concurrency gate**: `canStartCreation(isHighPriority:)`
   - High-priority (visible cell): uses both slots (max 2)
   - Low-priority (preload): only when 0 active slots used
5. **Queue**: High-priority at front, low-priority at back

## Player Configuration Sequence
```
configurePlayer(newPlayer)
  → preparePlayerForConfiguration(): pause, mute, throttle buffer (3s), disable network-while-paused
  → registerFirstFrameCallback(): onReadyForDisplay → capture frame → .playerReady
  → attachPlayerToLayer(): suppress CALayer animations
  → setupPlayerObservers(): KVO for item.status + timeControlStatus
  → handleAlreadyReadyPlayer(): immediate play if already readyToPlay
  → deferVideoOutputAttachment(): AVPlayerItemVideoOutput on next run loop
```

## Bandwidth Throttling
- **Default** (preparePlayerForConfiguration): `preferredForwardBufferDuration = 3`, `canUseNetworkResourcesForLiveStreamingWhilePaused = false`, `automaticallyWaitsToMinimizeStalling = false`
- **Primary** (shouldPlayVideo): `preferredForwardBufferDuration = 0` (unlimited), `canUseNetworkResourcesForLiveStreamingWhilePaused = true`
- **Pause/Stop**: reverts to 3s buffer, no network-while-paused
- **Preload** (SharedAssetCache.preloadPlayer): 3s buffer, no network-while-paused
- Only the primary video gets unlimited bandwidth; all others are throttled

## KVO Observers

### item.status Observer
- **readyToPlay**: If coordinator wants play → `requestPlaybackStartIfNeeded(reason: "statusKVO-ready")`
- **failed**: Clear player from SharedAssetCache

### timeControlStatus Observer
- **playing**: Cancel duration mismatch timer, hide spinner, reveal player layer
- **waitingToPlayAtSpecifiedRate**:
  - Guard: `isVideoAtEnd()` prevents infinite play/wait loop at end
  - Show spinner (buffering)
  - Start duration mismatch detection (see below)
- **paused**: Cancel mismatch timer

## Duration Mismatch Detection
**Problem**: IPFS/HLS sometimes declares duration (e.g. 11.2s) but only delivers data up to 9.8s.

```
Condition: loaded_end < declared_duration AND current_pos > loaded_end - 1.0
Trigger: Start 1s repeating timer
Monitor: Check if loaded_end grows each tick
Threshold: 3 seconds of no growth → handleVideoFinishedDueToMismatch()
```
Bypasses normal finish guard (timeUntilEnd will never reach 0).

## requestPlaybackStartIfNeeded()
**Guards**: `coordinatorWantsToPlay == true` AND `isVisible == true`
**Flow**: `playWithVolumeFadeIn()` → `startPlaybackWithFade()` → `actuallyStartPlayback()`
- Show player layer, transition to `.playing`
- Set volume 0, call `player.play()`, fade volume to 1.0 over 0.3s

## Coordinator Commands (MediaCellDelegate)

### shouldPlayVideo
- Set `coordinatorWantsToPlay = true`
- If `.playerReady`: `requestPlaybackStartIfNeeded()` immediately
- If `.failed`: cleanup and retry (acquire new player)
- If player not ready: show `.playerLoading`, trigger async setup, KVO triggers play when ready
- If finished: seek to zero before playing

### shouldPauseVideo
- Set `coordinatorWantsToPlay = false`
- Save position, capture last frame (throttled 0.75s), fade out, pause

### shouldStopVideo
- Set `coordinatorWantsToPlay = false`
- If loading + not visible: release player immediately
- If loading + visible: pause (allow preload to complete)
- If playing: transition to paused

## VideoPlaybackCoordinator

### Primary Video Selection
- `scheduleStartPrimary()` → `identifyPrimaryVideo()` → `startPrimaryVideoPlayback()`
- **Fast path**: cached ready player → play immediately (skip debounce)
- **Slow path**: 0.3s debounce per candidate
- During scroll: primary stays until it leaves `onScreenMediaCells` — no mid-scroll switching
- `updateOnScreenMediaCells()` handles primary leaving screen → idle → select new primary

### Per-Feed Instances (Phase 5)
- Main feed: `.shared` singleton
- Profile/list feeds: create own coordinator via `@StateObject`

### Coordinator Chain
```
TweetListView (@StateObject) → TweetTableViewController → TweetTableViewCell
  → TweetCellContentView → TweetBodyUIView → MediaGridUIView → MediaCellUIView
```

### Visibility Tracking
- `visibleTweetIds`: Tweet IDs on screen
- `onScreenMediaCells`: Media cell identifiers within viewport (50% visibility)
- `updateVisibleTweetsForVideoPlayback()`: Called on scroll, updates visibility sets

### Preloading (scroll-stop only)
- `performPreloadOnScrollStop(nearbyTweetIds:)`: Called on scroll stop + initial load
- **Preload**: next 2 videos in scroll direction → `preloadPlayer()` (full AVPlayer)
- **Nearby**: adjacent tweet videos → `preloadAsset()` (asset only)
- Stale preloads cancelled when sets change; completed players stay in LRU cache
- `activePreloadMids` / `activeNearbyMids`: explicit tracked sets (replaced `preloadedVideoMids`)

### Scroll Lifecycle
- `onScrollStarted()`: 2s grace timer — if scroll >2s, cancel preload/nearby downloads
- Scroll stop: `triggerPreloadOnScrollStop()` from TweetTableViewController
- No preloading during active scroll — bandwidth reserved for primary video

## Frame Capture (AVPlayerItemVideoOutput)
- **Priority 1**: AVPlayerItemVideoOutput → try 5 candidate times → downscale to 720px
- **Priority 2**: Same but synchronous on main thread
- **Priority 3**: Layer snapshot via UIGraphicsImageRenderer
- **Priority 4**: Already-cached thumbnail from SharedAssetCache
- **Throttle**: 0.75s minimum between captures

## Memory Management (SharedAssetCache)

### Protection
- `foregroundProtectedMids`: visible + preloaded + in-flight + VideoLoadingManager visible
- Protected videos never evicted by LRU cleanup

### Cleanup (10s interval)
1. Identify expired keys (> 15s since last access)
2. Skip protected mids
3. Release player, remove from all caches
4. Manage cache size, clean orphaned mappings

### Release on Scroll-Out
- `releasePlayerImmediately()`: Called when cell scrolls out of view
- Cancels loading/preload tasks, stops buffering, releases player
- **Preserves disk cache** for fast reload when scrolling back

## HLS URL Resolution (SharedAssetCache)
1. **Fast path**: Check `hlsExtensions[mediaID]` cache → append to URL (no network)
2. **Disk check**: Look for master.m3u8 or playlist.m3u8 on disk
3. **Network**: Parallel HEAD requests for both filenames (`async let`, 8s worst case)
4. **Persist**: Save resolved extension for next app launch

## Retry Logic
- Try once, on first failure: refresh author's baseUrl via `fetchUser(authorId, baseUrl: "")`, retry once
- On second failure: give up, reset counter
- Progressive and HLS share same retry logic
