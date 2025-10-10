# Video Caching System

**Last Updated:** October 10, 2025  
**Status:** Production Ready

## Overview

The video caching system in Tweet-iOS provides efficient video playback with intelligent disk caching, memory management, and seamless playback across different viewing contexts. The system uses multiple caching layers to optimize performance and user experience.

## Architecture Components

### 1. SharedAssetCache (`Sources/Core/SharedAssetCache.swift`)

**Purpose:** Central caching system for video assets and AVPlayer instances with background loading support.

**Key Features:**
- **Asset Caching:** Stores `AVAsset` objects indexed by media ID (IPFS hash)
- **Player Caching:** Stores `AVPlayer` objects for reuse (25 max)
- **Preloading System:** Priority-based background loading
- **Background Cleanup:** Automatic expiration (30 minutes)
- **HLS Support:** Automatic HLS URL resolution and integration with `CachingPlayerItem`
- **Memory Management:** LRU eviction, proactive monitoring
- **Disk Persistence:** Cache metadata survives app restarts

**Configuration:**
```swift
private let maxCacheSize = 30          // Maximum cached assets
private let maxPlayerCacheSize = 25    // Maximum cached players
private let cacheExpirationInterval: TimeInterval = 1800 // 30 minutes
private let maxVideoFileSize: Int64 = 50 * 1024 * 1024 // 50MB max
```

**Usage Examples:**
```swift
// Get cached player (synchronous check)
if let player = SharedAssetCache.shared.getCachedPlayer(for: mediaID) {
    // Use cached player immediately
}

// Get or create player (async)
let player = try await SharedAssetCache.shared.getOrCreatePlayer(
    for: url,
    tweetId: tweetId,
    mediaType: .hls_video
)

// Check if content is cached (works for tweet IDs or media IDs)
if SharedAssetCache.shared.hasCachedContent(for: mediaID) {
    // Load from cache
}

// Preload video (high priority)
SharedAssetCache.shared.preloadVideo(for: url, tweetId: tweetId)

// Preload asset only (low priority, background)
SharedAssetCache.shared.preloadAsset(for: url, tweetId: tweetId)

// Clear all caches (sign out, emergency)
await SharedAssetCache.shared.clearAllCaches()
```

### 2. CachingPlayerItem (`Sources/CachingPlayerItem/CachingPlayerItem.swift`)

**Purpose:** Custom `AVPlayerItem` subclass for intelligent HLS video segment caching.

**Key Features:**
- **On-Demand Caching:** Loads content immediately when requested
- **Limited Preloading:** Downloads next 3 segments (not entire videos)
- **Playlist Modification:** Rewrites HLS playlists to use cached URLs
- **LocalHTTPServer Integration:** Serves cached segments via HTTP
- **MediaID-Based Storage:** Persistent cache using IPFS hashes
- **Dual Delegate System:**
  - `CachingPlayerItemDelegate`: Progress, errors, completion
  - `AVAssetResourceLoaderDelegate`: Playlist and segment loading

**Cache Strategy:**
```swift
// Only preload next 3 segments to minimize disk usage
private let maxPreloadSegments = 3

// Segment caching flow:
1. Master playlist downloaded and modified
2. Sub-playlists downloaded and modified
3. Current segment loaded immediately
4. Next 3 segments preloaded in background
5. Old segments remain cached for instant replay
```

### 3. ResourceLoaderDelegate (`Sources/CachingPlayerItem/ResourceLoaderDelegate.swift`)

**Purpose:** Custom `AVAssetResourceLoaderDelegate` for HLS content handling.

**Capabilities:**
- Downloads and caches master/sub-playlists
- Modifies playlist URLs to use custom `customSchemeForStreaming://`
- Downloads video segments (.ts files) in background
- Validates cached content integrity
- Serves content through LocalHTTPServer URLs

**Playlist Processing:**
```swift
// Original URL:
http://server.com/ipfs/QmXXX/master.m3u8

// Modified to cache-first URL:
http://localhost:8080/QmXXX/master.m3u8

// LocalHTTPServer serves from disk cache
// Falls back to network if not cached
```

### 4. LocalHTTPServer (`Sources/CachingPlayerItem/LocalHTTPServer.swift`)

**Purpose:** Local HTTP server running on port 8080 to serve cached media files.

**Features:**
- Serves cached HLS playlists and segments
- Handles multiple playlist naming conventions (`master.m3u8`, `playlist.m3u8`, etc.)
- Provides HTTP endpoints for AVPlayer integration
- Thread-safe operation using `DispatchQueue`
- Automatic startup when HLS videos are played

**Server Flow:**
```
1. AVPlayer requests: http://localhost:8080/QmXXX/segment_001.ts
2. LocalHTTPServer checks disk cache
3. If cached: Serve from disk
4. If not cached: Return 404 (ResourceLoaderDelegate will download)
5. Response includes proper Content-Type and Content-Length headers
```

### 5. VideoStateCache (`Sources/Features/MediaViews/SimpleVideoPlayer.swift`)

**Purpose:** Manages shared AVPlayer instances across viewing contexts for seamless transitions.

**Key Features:**
- Single AVPlayer per media ID
- Preserves playback time, playing state, mute state
- Enables instant transitions between MediaCell and MediaBrowser
- Independent from SharedAssetCache (different purposes)

**Difference from SharedAssetCache:**
- **VideoStateCache:** Runtime player sharing for UI transitions
- **SharedAssetCache:** Asset/player caching with disk persistence

### 6. DiskCacheCleanupManager (`Sources/Core/DiskCacheCleanupManager.swift`)

**Purpose:** Manages disk space usage for cached video content.

**Features:**
- Monitors cache directory size
- Removes oldest cached videos when limit reached
- LRU (Least Recently Used) eviction strategy
- Manual cleanup API

### 7. MemoryCapManager (`Sources/Core/MemoryCapManager.swift`)

**Purpose:** Proactive memory management to prevent crashes.

**Features:**
- Monitors app memory usage
- Triggers cache cleanup at threshold (800MB)
- Reports to SharedAssetCache for action
- Logs memory events for debugging

## Cache Flow Diagrams

### Initial Video Load (No Cache)

```
User Scrolls to Video
        ↓
SimpleVideoPlayer.setupPlayer()
        ↓
SharedAssetCache.getOrCreatePlayer(url, mediaID, .hls_video)
        ↓
Check hasCachedContent(mediaID)? → NO
        ↓
CachingPlayerItem(hlsURL: url, mediaID: mediaID)
        ↓
ResourceLoaderDelegate intercepts playlist request
        ↓
Download master.m3u8 → Save to disk
        ↓
Modify playlist URLs → Point to localhost:8080
        ↓
AVPlayer loads from LocalHTTPServer
        ↓
Segment requested → Download → Cache → Serve
        ↓
Video Plays (segment 0)
        ↓
Preload segments 1, 2, 3 in background
```

### Subsequent Video Load (Cached)

```
User Scrolls to Cached Video
        ↓
SharedAssetCache.getOrCreatePlayer(url, mediaID, .hls_video)
        ↓
Check hasCachedContent(mediaID)? → YES
        ↓
checkCachedHLSPlaylist(mediaID) → Returns cached master.m3u8
        ↓
CachingPlayerItem(hlsURL: cachedURL, mediaID: mediaID)
        ↓
LocalHTTPServer serves cached playlists
        ↓
LocalHTTPServer serves cached segments
        ↓
Video Plays Instantly (no network requests)
```

### MediaCell to Fullscreen Transition (Zero Delay)

```
User Taps Video in MediaCell
        ↓
MediaCell.onDisappear() → Pause, cache state in VideoStateCache
        ↓
MediaBrowserView opens
        ↓
SimpleVideoPlayer (mode: .mediaBrowser) appears
        ↓
Check VideoStateCache → FOUND (same mediaID)
        ↓
Reuse SAME AVPlayer instance
        ↓
Switch from VideoPlayer to AVPlayerViewController
        ↓
Unmute, continue from exact position
        ↓
Video Continues Instantly (zero delay)
```

## Cache Storage Locations

### Disk Cache Structure

```
~/Library/Caches/{mediaID}/
├── _master.m3u8         (master playlist, modified)
├── _playlist.m3u8       (sub-playlist, modified)
├── segment_000.ts       (video segment)
├── segment_001.ts
├── segment_002.ts
└── ...
```

### UserDefaults Metadata

```swift
// Cache metadata persists across app restarts
{
  "cachedMediaIDs": {
    "QmXXXXX": "2025-10-10T12:00:00Z",  // timestamp
    "QmYYYYY": "2025-10-10T11:30:00Z"
  }
}
```

## Memory Management

### Automatic Cleanup

**Proactive Monitoring:**
- Memory checked every 10 seconds
- Automatic cleanup at 800MB usage
- System memory warnings trigger 30% cache release

**LRU Eviction:**
- Asset cache: 30 items max
- Player cache: 25 items max
- Least recently used items removed first

**Cache Expiration:**
- Items expire after 30 minutes of inactivity
- Background cleanup runs every 30 seconds

### Manual Cache Management

```swift
// Clear all caches (sign out, settings)
await SharedAssetCache.shared.clearAllCaches()

// Release partial cache (30%)
await SharedAssetCache.shared.releasePartialCache(percentage: 30)

// Cancel loading for specific video
SharedAssetCache.shared.cancelLoading(for: mediaID)

// Clear asset cache for specific video
await SharedAssetCache.shared.clearAssetCache(for: mediaID)
```

## Integration Points

### SimpleVideoPlayer

**Uses SharedAssetCache for:**
- Asset and player creation
- Cache validation
- Memory-efficient playback

**Integration:**
```swift
let player = try await SharedAssetCache.shared.getOrCreatePlayer(
    for: url,
    tweetId: mid,
    mediaType: mediaType
)
```

### MediaCell & MediaGridView

**Uses SharedAssetCache for:**
- Preloading visible videos
- Canceling loads for scrolled-away videos

**Integration:**
```swift
.onAppear {
    SharedAssetCache.shared.preloadAsset(for: url, tweetId: tweetId)
}
.onDisappear {
    SharedAssetCache.shared.cancelLoading(for: mediaID)
}
```

### VideoConversionService

**Converts videos to HLS format:**
- Creates adaptive bitrate playlists (720p/480p)
- Background processing with memory management
- FFmpeg integration for high-quality conversion
- Progress tracking with real-time updates

## Benefits of This Architecture

1. **MediaID-Based Caching:** IPFS hashes provide stable, content-addressed keys
2. **Instant Playback:** Cached content plays with zero network delay
3. **Smart Preloading:** Only 3 segments ahead to minimize disk usage
4. **Seamless Transitions:** VideoStateCache enables zero-delay fullscreen
5. **Memory Efficient:** Proactive monitoring prevents crashes
6. **Disk Efficient:** LRU eviction keeps cache size manageable
7. **Network Efficient:** Cached content reduces bandwidth usage
8. **Persistence:** Cache survives app restarts via UserDefaults metadata

## Performance Metrics

### Cache Hit Rates
- **First Load:** Network download (1-3 seconds for first segment)
- **Repeat Views:** Instant playback from cache (<100ms)
- **Fullscreen Transition:** Zero delay (same player reuse)

### Storage Efficiency
- **Segment Size:** 729KB - 2.5MB per segment
- **Typical Video:** 10-30MB cached (4-5 segments played + 3 preloaded)
- **Cache Limit:** 50MB per video max

### Memory Efficiency
- **Asset Cache:** ~2MB per cached asset
- **Player Cache:** ~5-10MB per cached player
- **Total Budget:** ~250MB for 25 cached players

## Debugging Tips

### Check Cache Status
```swift
let (assetCount, playerCount) = await SharedAssetCache.shared.getCacheStats()
print("Assets: \(assetCount), Players: \(playerCount)")

if SharedAssetCache.shared.hasCachedContent(for: mediaID) {
    print("✅ Video is cached")
}
```

### Inspect Disk Cache
```bash
# Check cached files
ls -lh ~/Library/Developer/CoreSimulator/Devices/{DEVICE_ID}/data/Containers/Data/Application/{APP_ID}/Library/Caches/

# Check cache size
du -sh ~/Library/Developer/.../Caches/
```

### Monitor Memory Usage
```
DEBUG: [SharedAssetCache] Proactive memory check - current usage: 650MB
DEBUG: [SharedAssetCache] Memory usage under 1GB, no action needed
```

### LocalHTTPServer Logs
```
DEBUG: [LocalHTTPServer] Started on port 8080
DEBUG: [LocalHTTPServer] Serving cached file: /QmXXX/segment_001.ts
```

## Future Enhancements

1. **Adaptive Bitrate Selection:** Choose quality based on network speed
2. **Cache Compression:** Reduce disk footprint further
3. **Predictive Preloading:** Use ML to predict next videos
4. **Background Sync:** Sync popular videos while charging
5. **Cache Sharing:** Share cache between users (public content only)

## Related Documentation

- [Video System Architecture](./VIDEO_SYSTEM_ARCHITECTURE.md) - Overall video architecture
- [Video Performance Optimization](./VIDEO_PERFORMANCE_OPTIMIZATION.md) - Performance improvements
- [Cached Video Loading Optimization](./CACHED_VIDEO_LOADING_OPTIMIZATION.md) - Caching mechanics

---

*This document reflects the production caching system as of October 2025.*
