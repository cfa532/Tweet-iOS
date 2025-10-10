# Video System Architecture

**Last Updated:** October 10, 2025  
**Status:** Production Ready

## Overview

The Tweet iOS app implements a sophisticated video playback system with intelligent caching, player sharing, and seamless transitions between different viewing contexts. The system supports both HLS (HTTP Live Streaming) and progressive MP4 video formats with on-demand caching and immediate playback.

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
- **HLS Support:** Integration with `CachingPlayerItem`
- **Memory Management:** LRU eviction, proactive monitoring
- **Disk Persistence:** Cache metadata survives app restarts

**Cache Limits:**
- Max Assets: 30
- Max Players: 25
- Cache Expiration: 30 minutes
- Max File Size: 50MB per video

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

### 6. LocalHTTPServer (Cache Content Server)

**Location:** `Sources/CachingPlayerItem/LocalHTTPServer.swift`

Local HTTP server running on port 8080 to serve cached media.

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
- Limited segment preloading (next 3 segments)
- MediaID-based cache persistence
- HLS and progressive video support
- Cache validation and integrity checking
- Memory-efficient segment management
- Automatic disk cache cleanup

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

---

*This document reflects the actual implementation as of October 2025. The system is production-ready and actively used in the Tweet iOS application.*
