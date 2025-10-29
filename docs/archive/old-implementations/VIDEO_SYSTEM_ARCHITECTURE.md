# Video System Architecture

**Last Updated:** October 12, 2025  
**Status:** Production Ready

## Overview

The Tweet iOS app implements a sophisticated video playback system with intelligent caching, player sharing, and seamless transitions between different viewing contexts. The system supports both HLS (HTTP Live Streaming) and progressive video formats with on-demand caching and immediate playback.

### Video Types

1. **HLS Videos** (`MediaType.hls_video`): Adaptive bitrate streaming with master playlists and segments
2. **Progressive Videos** (`MediaType.video`): Direct HTTP video streams (data blobs without file extensions)

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                   Video System                           │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐ │
│  │ MediaCell    │  │ MediaBrowser  │  │ TweetDetail  │ │
│  │ (Feed View)  │  │ (Fullscreen)  │  │ (Detail)     │ │
│  └──────┬───────┘  └───────┬───────┘  └──────┬───────┘ │
│         │                  │                  │          │
│         └──────────────────┼──────────────────┘          │
│                            │                             │
│                 ┌──────────▼──────────┐                 │
│                 │  SimpleVideoPlayer  │                 │
│                 │  (Unified Player)   │                 │
│                 └──────────┬──────────┘                 │
│                            │                             │
│         ┌──────────────────┼──────────────────┐         │
│         │                  │                  │         │
│    ┌────▼─────┐   ┌────────▼────────┐  ┌─────▼─────┐  │
│    │VideoState│   │  SharedAsset    │  │DetailVideo│  │
│    │  Cache   │   │     Cache       │  │  Manager  │  │
│    │(Players) │   │(Assets/Items)   │  │(Singleton)│  │
│    └────┬─────┘   └────────┬────────┘  └─────┬─────┘  │
│         │                  │                  │         │
│         └──────────────────┼──────────────────┘         │
│                            │                             │
│              ┌─────────────▼──────────────┐             │
│              │    CachingPlayerItem       │             │
│              │  (HLS Segment Caching)     │             │
│              └─────────────┬──────────────┘             │
│                            │                             │
│              ┌─────────────▼──────────────┐             │
│              │     LocalHTTPServer        │             │
│              │   (Serves Cached Media)    │             │
│              └────────────────────────────┘             │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### 1. SimpleVideoPlayer (Unified Video Player)

**Location:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

The central component that handles all video playback across different contexts.

**Key Features:**
- **Mode-Aware Playback:** Three modes (`.mediaCell`, `.mediaBrowser`, `.tweetDetail`)
- **Player Sharing:** Seamless transitions using `VideoStateCache`
- **Automatic Mute Management:** Context-appropriate audio state
- **Background/Foreground Handling:** Maintains playback state across app lifecycle
- **Dual Rendering:** `VideoPlayer` for cells, `AVPlayerViewController` for fullscreen

**Modes:**
```swift
enum Mode {
    case mediaCell      // Grid/feed view playback
    case mediaBrowser   // Fullscreen browser
    case tweetDetail    // Detail view playback
}
```

### 2. VideoStateCache (Player State Manager)

**Location:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift` (lines 54-78)

Manages shared AVPlayer instances across viewing contexts.

**Key Features:**
- **Single Player Per Video:** One AVPlayer per `mid` (media ID)
- **MediaCell ↔ MediaBrowser Sharing:** Zero-delay transitions
- **State Preservation:** Time, playback status, mute state
- **Independent TweetDetail:** Separate lifecycle for detail views

**Cache Structure:**
```swift
class VideoStateCache {
    private var cache: [String: (
        player: AVPlayer,
        time: CMTime,
        wasPlaying: Bool,
        originalMuteState: Bool
    )] = [:]
}
```

### 3. SharedAssetCache (Asset & Player Management)

**Location:** `Sources/Core/SharedAssetCache.swift`

Central asset and player cache with background loading support.

**Key Features:**
- **Asset Caching:** AVAsset instances indexed by media ID
- **Player Caching:** AVPlayer instances for reuse
- **MediaID-Based Keys:** Stable IPFS hash identifiers
- **Dual Format Support:**
  - **HLS videos**: Integration with `CachingPlayerItem` + LocalHTTPServer
  - **Progressive videos**: Plain AVPlayer with `ProgressiveVideoResourceLoader` for Content-Type fix
- **Memory Management:** LRU eviction, proactive monitoring
- **Disk Persistence:** Cache metadata survives app restarts

**Cache Limits:**
- Max Assets: 30
- Max Players: 25
- Cache Expiration: 30 minutes
- Max File Size: 50MB per video

**Video Type Detection:**
```swift
// Uses MediaType from attachment.type property
if mediaType == .hls_video {
    // HLS: CachingPlayerItem + LocalHTTPServer
} else {
    // Progressive: Plain AVPlayer with custom ResourceLoader
}
```

### 4. CachingPlayerItem (HLS Segment Caching)

**Location:** `Sources/CachingPlayerItem/CachingPlayerItem.swift`

Custom `AVPlayerItem` subclass for intelligent HLS video caching.

**Key Features:**
- **On-Demand Caching:** Loads content immediately when requested
- **Limited Preloading:** Downloads next 3 segments (not entire videos)
- **Playlist Modification:** Rewrites HLS playlists for cache URLs
- **LocalHTTPServer Integration:** Serves cached segments via HTTP
- **MediaID-Based Storage:** Persistent cache across sessions

### 5. ResourceLoaderDelegate (HLS Content Handler)

**Location:** `Sources/CachingPlayerItem/ResourceLoaderDelegate.swift`

Custom `AVAssetResourceLoaderDelegate` for HLS playlist and segment handling.

**Capabilities:**
- Downloads and caches master/sub-playlists
- Modifies playlist URLs to use custom scheme
- Downloads video segments in background
- Validates cached content integrity
- Serves content through LocalHTTPServer

### 6. ProgressiveVideoResourceLoader (Content-Type Fix)

**Location:** `Sources/Core/SharedAssetCache.swift`

Lightweight `AVAssetResourceLoaderDelegate` that fixes Content-Type headers for progressive videos.

**Purpose:**
- Server returns `Content-Type: application/octet-stream` for video blobs
- AVPlayer requires proper content type to play videos
- Intercepts resource loading requests and provides `video/mp4` content type
- Redirects to original HTTP URL for actual data loading

**Implementation:**
```swift
class ProgressiveVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, 
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Set correct content type
        loadingRequest.contentInformationRequest?.contentType = "video/mp4"
        // Redirect to original URL for data
        let response = HTTPURLResponse(statusCode: 302, headerFields: ["Location": originalURL])
        loadingRequest.response = response
        loadingRequest.finishLoading()
        return true
    }
}
```

### 7. LocalHTTPServer (Cache Content Server)

**Location:** `Sources/CachingPlayerItem/LocalHTTPServer.swift`

Local HTTP server running on port 8080 to serve cached HLS media.

**Features:**
- Serves cached HLS playlists and segments
- Handles multiple playlist naming conventions
- Provides HTTP endpoints for AVPlayer
- Thread-safe operation

### 7. DetailVideoManager (Singleton for Detail View)

**Location:** `Sources/Core/SingletonVideoManagers.swift`

Singleton manager for TweetDetailView video playback.

**Key Features:**
- **Independent Players:** Separate from feed playback
- **KVO Observers:** Monitors player item status
- **Auto-Play Support:** Automatic playback when ready
- **Audio Session Management:** Proper audio handling
- **Lifecycle Management:** Cleans up on view dismissal

## Progressive Video vs HLS Video

### Progressive Video (MediaType.video)

**Server Storage:**
- Stored as binary data blobs without file extensions
- Server returns `Content-Type: application/octet-stream`
- Direct HTTP streaming, no segmentation

**iOS Implementation:**
```swift
// 1. Remove iOS-specific ?dig=xxx query parameter (only for HLS)
var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
components?.query = nil
let cleanURL = components?.url ?? url

// 2. Use custom scheme to intercept Content-Type
let customSchemeURL = cleanURL.replacingOccurrences(of: "http://", with: "progressivevideo://")

// 3. Create AVURLAsset with custom ResourceLoader
let asset = AVURLAsset(url: customSchemeURL)
let loaderDelegate = ProgressiveVideoResourceLoader(originalURL: cleanURL)
asset.resourceLoader.setDelegate(loaderDelegate, queue: .main)

// 4. ResourceLoader fixes Content-Type to "video/mp4" and redirects to HTTP
```

**Key Differences from Android:**
- Android ExoPlayer auto-detects video format from data stream
- iOS AVPlayer requires explicit Content-Type
- Solution: Custom ResourceLoader intercepts and provides correct Content-Type

### HLS Video (MediaType.hls_video)

**Server Storage:**
- Master playlist (master.m3u8) with quality variants
- Sub-playlists (playlist.m3u8) with segment references  
- Video segments (.ts files)
- Proper HLS structure

**iOS Implementation:**
```swift
// 1. Resolve master.m3u8 or playlist.m3u8 URL
let resolvedURL = await resolveHLSURL(url) // Tries master.m3u8, then playlist.m3u8

// 2. Start LocalHTTPServer for segment serving
LocalHTTPServer.shared.start()

// 3. Create CachingPlayerItem with LocalHTTPServer integration
let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: mediaID)

// 4. LocalHTTPServer caches segments and serves them locally
// 5. ?dig=xxx query parameter preserved for AVPlayer cache-busting
```

**Android Comparison:**
- Both platforms handle HLS similarly
- ExoPlayer has built-in caching
- iOS uses custom LocalHTTPServer for caching

## Video Playback Flow by Mode

### MediaCell (Feed/Grid View)

**Initial Load:**
```
User scrolls → VideoLoadingManager approves
→ SimpleVideoPlayer (mode: .mediaCell)
→ Check VideoStateCache → NOT FOUND
→ Create AVPlayer via SharedAssetCache
→ Apply global mute state (MuteState.shared.isMuted)
→ Cache player with key = mid
→ Video plays (muted/unmuted based on toggle)
```

**Player Lifecycle:**
- **onAppear:** Check cache, create if needed
- **onDisappear:** Pause, keep alive in VideoStateCache

### MediaBrowser (Fullscreen View)

**Transition from MediaCell:**
```
User taps video → MediaCell disappears
→ MediaBrowserView opens
→ SimpleVideoPlayer (mode: .mediaBrowser)
→ Check VideoStateCache → FINDS MediaCell's player
→ Reuse SAME AVPlayer (instant transition!)
→ Unmute player (fullscreen always unmuted)
→ Continue playback from current position
```

**Player Lifecycle:**
- **onAppear:** Reuse MediaCell's player, unmute
- **onDisappear:** Restore global mute, pause, keep alive

**Key Feature - Layer Sharing:**
- MediaCell: `VideoPlayer` (UIViewRepresentable)
- MediaBrowser: `AVPlayerViewController` (UIViewControllerRepresentable)
- SwiftUI handles layer detachment/reattachment automatically
- `representableId` increment forces layer recreation

### TweetDetailView (Detail Screen)

**Independent Player:**
```
User opens detail → SimpleVideoPlayer (mode: .tweetDetail)
→ Check DetailVideoManager singleton
→ Create independent player
→ Unmute and auto-play
```

**Player Lifecycle:**
- **onAppear:** Get/create singleton player, unmute, play
- **onDisappear:** Stop player, release, clear cache

**Isolation Reason:**
- Accessed via navigation (different context)
- Should not interfere with feed playback
- Cleared on exit to prevent state conflicts

## Player Sharing Strategy

| Mode | Player Source | Shares With | On Exit |
|------|--------------|-------------|---------|
| **MediaCell** | VideoStateCache → creates if not found | MediaBrowser | Pause, keep in cache |
| **MediaBrowser** | VideoStateCache → reuses MediaCell's player | MediaCell | Pause, restore mute, keep alive |
| **TweetDetail** | DetailVideoManager singleton → independent | None | Stop, release, clear |

## Key Improvements Implemented

### 1. Unified Player Component
- **Before:** Separate `SimpleVideoPlayer`, `CachingVideoPlayer`, `DetailVideoPlayerView`
- **After:** Single `SimpleVideoPlayer` with mode parameter
- **Benefit:** Simplified codebase, consistent behavior, easier maintenance

### 2. VideoStateCache Player Sharing
- **Before:** `SharedAssetCache` with mode-specific keys, complex lookup
- **After:** `VideoStateCache` with single player per `mid`
- **Benefit:** True player sharing, zero-delay transitions, simpler architecture

### 3. Automatic Layer Management
- **Before:** Manual player detachment/reattachment, layer conflicts
- **After:** SwiftUI handles layers automatically, `representableId` for force-recreation
- **Benefit:** Eliminated black screen bugs, reliable fullscreen transitions

### 4. Mode-Based Mute State
- **Before:** Complex mute state tracking, race conditions
- **After:** Automatic mute application based on mode
- **Benefit:** Consistent audio behavior, no state conflicts

### 5. Independent TweetDetail Players
- **Before:** Shared players caused state conflicts
- **After:** TweetDetail uses independent singleton, cleared on exit
- **Benefit:** No interference with feed playback

## Performance Metrics

### Cache Efficiency
- **Player Reuse:** 100% hit rate for MediaCell → MediaBrowser transitions
- **Memory Usage:** One AVPlayer instance per active video
- **Storage Usage:** Optimized through limited segment preloading

### Loading Performance
- **MediaCell to Fullscreen:** Instant (same player, layer switch)
- **Fullscreen to MediaCell:** Instant (same player, layer switch)
- **Initial Video Load:** Immediate playback for cached content
- **Background Download:** Non-blocking segment preloading

### User Experience
- **Seamless Transitions:** Zero delay between MediaCell and fullscreen
- **Continuous Playback:** Video continues from exact position
- **Mute State Sync:** Automatic and reliable
- **No Black Screens:** Eliminated through proper layer management

## Technical Implementation Details

### Player Setup Flow
```swift
private func setupPlayer() {
    // 1. Check VideoStateCache for shared player
    if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
        // Apply mode-specific mute state
        cachedState.player.isMuted = (mode == .mediaCell) ? 
            MuteState.shared.isMuted : false
        restoreFromCache(cachedState)
        return
    }
    
    // 2. Create new player
    let newPlayer = await SharedAssetCache.shared.getOrCreatePlayer(...)
    configurePlayer(newPlayer)
    
    // 3. Cache in VideoStateCache for sharing
    VideoStateCache.shared.cacheVideoState(for: mid, player: newPlayer, ...)
}
```

### OnDisappear Lifecycle
```swift
.onDisappear {
    // Cache current state BEFORE cleanup
    VideoStateCache.shared.cacheVideoState(
        for: mid, player: player,
        time: player.currentTime(),
        wasPlaying: player.rate > 0,
        originalMuteState: player.isMuted
    )
    
    // Mode-specific cleanup
    if mode == .mediaCell || mode == .mediaBrowser {
        player?.pause() // Keep alive for sharing
    } else if mode == .tweetDetail {
        player = nil
        VideoStateCache.shared.clearCache(for: mid)
    }
}
```

### Layer Recreation for Transitions
```swift
.onChange(of: mode) { oldMode, newMode in
    if newMode == .mediaBrowser {
        // Force layer detachment from MediaCell
        self.representableId += 1
        // AVPlayerViewController will attach new layer
    }
}
```

## Memory Management

### Proactive Monitoring
- Memory checked every 10 seconds
- Automatic cleanup at 800MB usage
- System memory warnings trigger 30% cache release

### LRU Eviction
- Asset cache: 30 items max
- Player cache: 25 items max
- Least recently used items removed first

### Cache Expiration
- Items expire after 30 minutes of inactivity
- Background cleanup runs every 30 seconds

## Debugging Tips

### Check Player Sharing
```
DEBUG: [VIDEO SETUP] Checking VideoStateCache for shared player: {mid}
DEBUG: [VIDEO CACHE] ✅ Found shared player for {mid} in {mode} mode
```

### Verify Mode Transitions
```
DEBUG: [VIDEO DISAPPEAR] MediaCell - paused player for {mid}, kept alive in cache
DEBUG: [VIDEO CACHE] ✅ Found shared player for {mid} in mediaBrowser mode
```

### Confirm Mute State
```
DEBUG: [VIDEO CACHE] Applied global mute state to shared player for MediaCell
DEBUG: [VIDEO CACHE] Unmuted shared player for fullscreen
```

## Future Enhancements

### Potential Improvements
1. **Adaptive Bitrate:** Dynamic quality based on network conditions
2. **Cache Compression:** Reduce storage footprint
3. **Predictive Preloading:** AI-based segment prediction
4. **Background Sync:** Sync cached content across devices
5. **Analytics:** Video playback metrics

### Monitoring Points
1. **Cache Hit Rates:** Track VideoStateCache effectiveness
2. **Transition Times:** Monitor MediaCell ↔ MediaBrowser performance
3. **Memory Usage:** Ensure efficient resource utilization
4. **User Engagement:** Measure impact on viewing behavior

## Related Documentation

- [Video Caching System](./VIDEO_CACHING_SYSTEM.md) - Details on caching implementation
- [Video Performance Optimization](./VIDEO_PERFORMANCE_OPTIMIZATION.md) - Performance improvements
- [CachingPlayerItem Details](./CACHED_VIDEO_LOADING_OPTIMIZATION.md) - Caching mechanics
- [MediaBrowser Implementation](./FULLSCREEN_BLACK_SCREEN_FIX.md) - Fullscreen video handling

## Status Summary

### ✅ Working Features
- Unified SimpleVideoPlayer for all contexts
- VideoStateCache-based player sharing
- Instant MediaCell ↔ MediaBrowser transitions
- Independent TweetDetail players
- Automatic mode-based mute state management
- SwiftUI-native layer management
- On-demand video caching with immediate playback
- Limited segment preloading (next 3 segments for HLS)
- MediaID-based cache persistence
- **Dual video format support:**
  - **HLS videos**: CachingPlayerItem + LocalHTTPServer for segment caching
  - **Progressive videos**: Plain AVPlayer with Content-Type fix via ProgressiveVideoResourceLoader
- Cache validation and integrity checking
- Memory-efficient segment management
- Automatic disk cache cleanup
- Query parameter handling (`?dig=xxx` stripped for progressive videos)

### ✅ Performance Achievements
- Zero-delay fullscreen transitions
- Continuous playback position across modes
- Eliminated black screen bugs
- Reliable mute state synchronization
- Realistic segment sizes (729KB - 2.5MB)
- Immediate playback for cached content
- Reduced bandwidth through smart preloading
- Fast startup times
- LocalHTTPServer on port 8080
- HLS master playlists processed successfully
- No UI freezing during video loading

## Recent Updates (October 12, 2025)

### Progressive Video Support Implementation

**Problem:**
- Progressive videos (MediaType.video) were not playing on iOS
- Server returns `Content-Type: application/octet-stream` for video blobs
- AVPlayer requires proper Content-Type to identify video files
- Videos stored as data blobs without file extensions

**Solution:**
- Created `ProgressiveVideoResourceLoader` to fix Content-Type
- Strips `?dig=xxx` query parameter for progressive videos (iOS-specific workaround only needed for HLS)
- Uses custom scheme (`progressivevideo://`) to intercept resource loading
- Redirects to original HTTP URL with correct Content-Type header

**Implementation Details:**
```swift
// Progressive Video Flow:
1. URL with ?dig=xxx → Strip query params → Clean URL
2. Clean URL → Replace http:// with progressivevideo://
3. AVURLAsset with custom scheme + ProgressiveVideoResourceLoader
4. ResourceLoader intercepts → Sets Content-Type: video/mp4 → Redirects to HTTP URL
5. AVPlayer plays successfully
```

**Android Comparison:**
- Android ExoPlayer auto-detects format from data stream (no Content-Type fix needed)
- iOS AVPlayer requires explicit Content-Type declaration
- Both platforms use MediaType.video vs MediaType.hls_video for type detection

---

*This document reflects the actual implementation as of October 12, 2025. The system is production-ready and actively used in the Tweet iOS application.*
