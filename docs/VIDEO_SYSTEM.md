# Video System - Complete Documentation

**Last Updated:** October 14, 2025  
**Status:** ✅ Production Ready (Partially Migrated)

---

## Overview

Dual video playback architecture supporting both HLS adaptive streaming and standard MP4 playback with intelligent caching, progressive loading, and shared resource management.

---

## Architecture Status

### ✅ New System (Grid + Detail Views)
- **Components:** `GridVideoContext`, `DetailVideoContext`, `VideoAssetCache`
- **Views:** `MediaGridView`, `TweetDetailView`
- **Features:** Shared AVAsset/AVPlayer cache, intelligent preloading

### ⚠️ Old System (Fullscreen View)
- **Components:** `SimpleVideoPlayer`, `HLSDirectoryVideoPlayer`, `VideoCacheManager`
- **Views:** `MediaBrowserView` (fullscreen)
- **Status:** Still active, not yet migrated

**Note:** Both systems coexist. Migration to new system for fullscreen view is pending.

---

## New Video System

### Components

#### VideoAssetCache (Shared Cache)
```swift
class VideoAssetCache {
    static let shared = VideoAssetCache()
    
    private var assetCache: [String: AVAsset] = [:]
    private var playerCache: [String: AVPlayer] = [:]
    
    private let maxCacheSize = Constants.MAX_ASSET_CACHE_SIZE // 50
    private let maxPlayerCacheSize = Constants.MAX_PLAYER_CACHE_SIZE // 20
    private let maxVideoFileSize: Int64 = Constants.MAX_VIDEO_FILE_CACHE_SIZE // 200MB
}
```

**Features:**
- LRU eviction policy
- Size-based filtering (videos > 200MB not cached)
- Shared between grid and detail views
- Thread-safe access

#### GridVideoContext
```swift
@MainActor
class GridVideoContext: ObservableObject {
    @Published var currentlyPlayingVideoId: String?
    @Published var isMuted: Bool = true
    
    func playVideo(cid: String, asset: AVAsset)
    func pauseCurrentVideo()
    func stopAllVideos()
}
```

**Responsibilities:**
- Manages grid-level video state
- Ensures only ONE video plays at a time in grid
- Coordinates with `VideoLoadingManager` for preloading

#### DetailVideoContext
```swift
@MainActor
class DetailVideoContext: ObservableObject {
    @Published var currentlyPlayingVideoId: String?
    @Published var isMuted: Bool = false // Unmuted by default in detail view
    
    func playVideo(cid: String, asset: AVAsset)
    func pauseCurrentVideo()
}
```

**Responsibilities:**
- Manages detail view video state
- Independent from grid context
- Unmuted playback

---

## Video Loading Strategy

### Sequential Preloading

```swift
class VideoLoadingManager {
    func shouldLoadVideos(forTweetId tweetId: String) -> Bool {
        guard let index = findTweetIndex(tweetId) else { return false }
        
        // Load current + next 2 tweets' videos
        let loadRange = index...(index + 2)
        return loadRange.contains(currentVisibleTweetIndex)
    }
}
```

**Algorithm:**
1. Track visible tweet in feed
2. Load videos for:
   - Current tweet
   - Next tweet
   - Tweet after next
3. Unload videos outside this window

**Benefits:**
- Reduced memory usage
- Faster scrolling
- Smooth playback start

---

## Caching System

### LocalHTTPServer (Video Proxy)

```swift
class LocalHTTPServer {
    static let shared = LocalHTTPServer()
    private var server: GCDWebServer
    private let port: UInt = 8080
    
    func start()
    func createProxyURL(for originalURL: URL) -> URL?
}
```

**Purpose:**
- Intercepts video requests from AVPlayer
- Serves cached data if available
- Downloads and caches on-the-fly if not
- **Enabled for:** MP4 videos
- **Disabled for:** HLS videos (direct backend access)

### CachingPlayerItem

```swift
class CachingPlayerItem: AVPlayerItem {
    private let resourceLoaderDelegate: ResourceLoaderDelegate
    
    init(url: URL) {
        let asset = AVURLAsset(url: LocalHTTPServer.shared.createProxyURL(for: url)!)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }
}
```

**Features:**
- Custom resource loading via LocalHTTPServer
- Progressive download
- Disk caching
- Resume support

---

## HLS Video Handling

### HLS vs MP4 Detection

```swift
func isHLSVideo(url: URL) -> Bool {
    return url.absoluteString.contains("/hls/") ||
           url.pathExtension == "m3u8"
}
```

### HLS Playback Optimization

```swift
player.automaticallyWaitsToMinimizeStalling = false
cachingPlayerItem.preferredForwardBufferDuration = 2.0
cachingPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
```

**Why:**
- `automaticallyWaitsToMinimizeStalling = false` - Start playback immediately
- `preferredForwardBufferDuration = 2.0` - Small buffer for faster start
- `canUseNetworkResourcesForLiveStreamingWhilePaused = false` - Don't buffer when paused

### HLS Directory Structure

```
QmXXX.../hls/
├── master.m3u8          # Master playlist
├── 720p/
│   ├── playlist.m3u8    # 720p playlist
│   ├── segment000.ts
│   ├── segment001.ts
│   └── ...
└── 480p/
    ├── playlist.m3u8    # 480p playlist
    ├── segment000.ts
    ├── segment001.ts
    └── ...
```

**Access:**
```
Backend URL: http://{BACKEND}/ipfs/{CID}/hls/master.m3u8
No LocalHTTPServer proxy (direct access for better HLS performance)
```

---

## Old Video System (Fullscreen)

### Components

#### SimpleVideoPlayer
```swift
struct SimpleVideoPlayer: View {
    @StateObject private var videoCache = VideoCache.shared
    @State private var player: AVPlayer?
    
    var body: some View {
        if let player = player {
            AVPlayerViewControllerRepresentable(player: player)
        }
    }
}
```

**Features:**
- Standalone player for fullscreen view
- Uses `VideoCacheManager` for caching
- Not integrated with shared cache

#### HLSDirectoryVideoPlayer
```swift
class HLSDirectoryVideoPlayer: NSObject {
    func loadHLSVideo(from url: URL, completion: @escaping (AVPlayerItem?) -> Void)
}
```

**Purpose:**
- Handles HLS directory structure
- Downloads master playlist and segments
- Creates playable AVPlayerItem

#### VideoCacheManager
```swift
class VideoCacheManager {
    static let shared = VideoCacheManager()
    
    func getCachedVideo(for url: URL) -> AVPlayerItem?
    func cacheVideo(_ playerItem: AVPlayerItem, for url: URL)
}
```

**Status:** Active in fullscreen view, not shared with grid/detail

---

## Video Playback States

### Global Mute State

```swift
@MainActor
class GlobalMuteState: ObservableObject {
    @Published var isMuted: Bool = true
    static let shared = GlobalMuteState()
}
```

**Behavior:**
- Grid view: Muted by default
- Detail view: Unmuted by default
- Fullscreen: Unmuted by default
- User can toggle in all views

### Autoplay Logic

```swift
// MediaCell (Grid)
if isVisible && autoPlay && shouldLoadVideo {
    setupVideoPlayer()
}

// TweetDetailView
if isDetailView {
    setupDetailVideoPlayer() // Auto-plays unmuted
}
```

---

## Performance Optimizations

### 1. Shared Asset Cache
**Problem:** Multiple AVAssets created for same video  
**Solution:** Single shared cache, reuse assets

### 2. Lazy Loading
**Problem:** All videos loaded at once  
**Solution:** Load only visible + next 2 tweets

### 3. LRU Eviction
**Problem:** Unlimited cache growth  
**Solution:** Max 50 assets, 20 players, oldest evicted first

### 4. Size Filtering
**Problem:** Large videos consume too much memory  
**Solution:** Don't cache videos > 200MB

### 5. Progressive Loading
**Problem:** Wait for entire video before playback  
**Solution:** `CachingPlayerItem` plays while downloading

### 6. HLS Direct Access
**Problem:** LocalHTTPServer adds latency for HLS  
**Solution:** Direct backend access for HLS, proxy only MP4

---

## Known Issues

### Fullscreen Black Screen (HLS Videos)
**Status:** Partially resolved  
**Symptom:** Black screen with spinner in fullscreen for some HLS videos  
**Cause:** Incompatible FFmpeg encoding settings or codec issues  
**Workaround:** Use libx264 with strict compatibility settings

**Current Encoding:**
```bash
-c:v libx264 -profile:v main -level 4.0 -pix_fmt yuv420p \
-preset fast -g 48 -keyint_min 48 -sc_threshold 0
```

### Video State Conflicts
**Status:** Active  
**Symptom:** Grid video continues playing after navigating to detail  
**Cause:** Incomplete context separation  
**Solution:** Explicit pause in grid when detail opens

---

## Migration Plan

### Phase 1: ✅ Grid + Detail Views
- Implement `VideoAssetCache`
- Create `GridVideoContext` and `DetailVideoContext`
- Update `MediaGridView` and `TweetDetailView`

### Phase 2: ⏳ Fullscreen View
- Migrate `MediaBrowserView` to new system
- Remove `SimpleVideoPlayer` old implementation
- Consolidate all video playback

### Phase 3: ⏳ Cleanup
- Remove `VideoCacheManager`
- Remove `HLSDirectoryVideoPlayer`
- Unified video handling across all views

---

## Constants

```swift
// In Sources/DataModels/Constants.swift
static let MAX_ASSET_CACHE_SIZE = 50
static let MAX_PLAYER_CACHE_SIZE = 20
static let CACHE_EXPIRATION_SECONDS: TimeInterval = 3600 // 1 hour
static let MAX_VIDEO_FILE_CACHE_SIZE: Int64 = 200 * 1024 * 1024 // 200MB
static let MAX_FILE_SIZE: Int64 = 240 * 1024 * 1024 // 240MB upload limit
```

---

## Debug Logs

**Reduced in production to minimize noise:**
- LocalHTTPServer: Only errors
- VideoCache: Critical events only
- FFmpeg: Errors only (`FFmpegKitConfig.setLogLevel(16)`)

---

## Testing Checklist

- [ ] Grid video plays and pauses correctly
- [ ] Detail video plays unmuted
- [ ] Fullscreen video plays correctly
- [ ] Navigate grid → detail (grid video stops)
- [ ] Navigate detail → grid (detail video stops)
- [ ] Scroll in grid (only visible videos load)
- [ ] HLS videos play without black screen
- [ ] MP4 videos cache and resume
- [ ] Memory usage stays under 200MB
- [ ] No crashes on low memory

---

## Files

**New System:**
- `Sources/Core/SharedAssetCache.swift` (VideoAssetCache)
- `Sources/Features/MediaViews/GridVideoContext.swift`
- `Sources/Features/MediaViews/DetailVideoContext.swift`
- `Sources/Core/VideoLoadingManager.swift`

**Old System (Fullscreen):**
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- `Sources/Features/MediaViews/HLSDirectoryVideoPlayer.swift`
- `Sources/Core/VideoCacheManager.swift`

**Shared:**
- `Sources/CachingPlayerItem/*` (Progressive loading)
- `Sources/Core/LocalHTTPServer.swift` (Caching proxy)

---

## Future Improvements

- [ ] Complete fullscreen migration
- [ ] Picture-in-picture support
- [ ] Airplay support
- [ ] Download for offline viewing
- [ ] Playback speed control
- [ ] Video quality manual selection
- [ ] Bandwidth-based quality switching

