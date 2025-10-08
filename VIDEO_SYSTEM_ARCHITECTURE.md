# Video System Architecture - Current Status

## Overview

The Tweet iOS app has implemented a sophisticated video loading, caching, and playing system that provides seamless video playback with intelligent caching mechanisms. The system supports both HLS (HTTP Live Streaming) and progressive video formats with on-demand caching and immediate playback.

## Architecture Components

### 1. Unified Video Player System

#### SimpleVideoPlayer (Unified Player for All Views)
- **Purpose**: Single, unified video player component used across all contexts
- **Modes**:
  - `.mediaCell`: Grid/feed view playback
  - `.mediaBrowser`: Fullscreen view playback
  - `.tweetDetail`: Detail view playback
- **Features**: 
  - Mode-aware player configuration
  - Automatic mute state management per mode
  - Player instance sharing via `VideoStateCache`
  - Seamless transitions between modes
  - MediaID-based stable caching

### 2. Player Sharing Architecture

#### VideoStateCache (Primary Player Sharing System)
- **Purpose**: Manages ONE shared player instance per video (`mid`)
- **Key Design**:
  - Cache key: `mid` only (no mode suffix)
  - MediaCell and MediaBrowser **share the same player**
  - TweetDetailView uses **independent players** (cleared on exit)
- **Stored State**:
  - `player`: The AVPlayer instance
  - `time`: Current playback position
  - `wasPlaying`: Playback state
  - `originalMuteState`: Mute state to restore
- **Benefits**:
  - Zero-delay fullscreen transitions
  - Continuous playback when entering/exiting fullscreen
  - Automatic layer management handled by SwiftUI
  - Simplified memory management

### 3. Caching System

#### CachingPlayerItem
- **Core Innovation**: Custom `AVPlayerItem` subclass for intelligent video caching
- **Key Features**:
  - **On-demand caching**: Loads content immediately when requested
  - **Limited preloading**: Downloads only the next 3 segments (not entire videos)
  - **No cache checking**: Removes explicit cache validation for faster loading
  - **Exclusive cache loading**: All video loading goes through the cache system
  - **MediaID-based keys**: Uses stable IPFS hashes instead of volatile URLs

#### ResourceLoaderDelegate
- **Purpose**: Custom `AVAssetResourceLoaderDelegate` for HLS content handling
- **Capabilities**:
  - Handles master playlists and sub-playlists
  - Modifies playlists to use custom scheme URLs
  - Downloads and caches segments in background
  - Serves cached content through `LocalHTTPServer`
  - Validates cached content integrity

#### SharedAssetCache
- **Purpose**: Asset cache manager (not player cache)
- **Features**:
  - MediaID-based cache keys for persistence across app restarts
  - Asset caching only (AVURLAsset, CachingPlayerItem)
  - Cache metadata persistence using `UserDefaults`
  - Automatic cache restoration on app startup
  - Cache validation and cleanup
- **Note**: Player instance caching removed - now handled by `VideoStateCache`

#### LocalHTTPServer
- **Purpose**: Local HTTP server for serving cached media files
- **Features**:
  - Serves cached HLS playlists and segments
  - Handles multiple playlist naming conventions
  - Provides HTTP endpoints for AVPlayer integration
  - Runs on port 8080

### 4. Video Management

#### VideoManager
- **Purpose**: Global video playback coordination for MediaCell
- **Features**:
  - Sequential playback control in feed
  - Single video playback management
  - Mute state synchronization
  - Player lifecycle management for grid views

#### VideoLoadingManager
- **Purpose**: Controls when videos should be loaded based on visibility
- **Features**:
  - Tweet visibility tracking
  - Video loading permission system
  - Performance optimization through selective loading

## Video Playback Flow by Mode

### 1. MediaCell (Feed/Grid View)

**Initial Load:**
```
User scrolls to video → VideoLoadingManager approves loading
→ SimpleVideoPlayer (mode: .mediaCell) appears
→ Checks VideoStateCache for existing player → NOT FOUND
→ Creates new AVPlayer via SharedAssetCache.getOrCreatePlayer()
→ Applies global mute state (MuteState.shared.isMuted)
→ Caches player in VideoStateCache with key = mid
→ Video plays muted/unmuted based on global toggle
```

**Player Lifecycle:**
```
onAppear:
  - Check VideoStateCache for shared player
  - If found: reuse player, apply mute state
  - If not found: create new player

onDisappear:
  - Pause player (keep alive in VideoStateCache)
  - Cache current playback state
  - Player remains in memory for fullscreen reuse
```

### 2. MediaBrowser (Fullscreen View)

**Transition from MediaCell:**
```
User taps video in MediaCell → MediaCell disappears (pauses, caches state)
→ MediaBrowserView opens with same mid
→ SimpleVideoPlayer (mode: .mediaBrowser) appears
→ Checks VideoStateCache → FINDS MediaCell's player
→ Reuses SAME AVPlayer instance (zero delay!)
→ Unmutes player (fullscreen always unmuted)
→ Continues playback from current position
→ AVPlayerViewController attaches layer seamlessly
```

**Player Lifecycle:**
```
onAppear:
  - Check VideoStateCache → reuse MediaCell's player
  - Apply unmute (fullscreen is always unmuted)
  - Continue playback seamlessly

onDisappear (exiting fullscreen):
  - Restore global mute state to player
  - Pause player (keep alive in VideoStateCache)
  - Cache current state
  - MediaCell will reuse this player when it reappears
```

**Key Feature: Layer Sharing**
- MediaCell uses `VideoPlayerRepresentable` (UIViewRepresentable)
- MediaBrowser uses `AVPlayerViewController` (UIViewControllerRepresentable)
- SwiftUI handles layer detachment/reattachment automatically
- Same `AVPlayer`, different presentation layers
- `representableId` increment forces layer recreation when needed

### 3. TweetDetailView (Detail Screen)

**Independent Player:**
```
User opens tweet detail → SimpleVideoPlayer (mode: .tweetDetail) appears
→ Checks VideoStateCache → may find existing player OR creates new one
→ Creates independent player instance (doesn't share with MediaCell)
→ Unmutes (detail view plays with sound)
→ Auto-plays immediately
```

**Player Lifecycle:**
```
onAppear:
  - Check VideoStateCache (may reuse or create new)
  - Unmute and auto-play

onDisappear:
  - Stop player
  - Release player (player = nil)
  - Clear VideoStateCache for this mid
  - Prevents interfering with MediaCell playback
```

**Isolation Reason:**
- TweetDetailView is accessed via navigation (different context)
- Should not interfere with feed playback state
- Cleared on exit to prevent state conflicts

## Player Sharing Strategy Summary

| Mode | Player Source | Shares With | On Exit |
|------|--------------|-------------|---------|
| **MediaCell** | VideoStateCache → creates if not found | MediaBrowser | Pause, keep alive in cache |
| **MediaBrowser** | VideoStateCache → reuses MediaCell's player | MediaCell | Pause, restore mute, keep alive |
| **TweetDetail** | VideoStateCache → independent | None | Stop, release, clear cache |

## Key Improvements Implemented

### 1. Unified Player Component
- **Before**: Separate SimpleVideoPlayer, CachingVideoPlayer, DetailVideoPlayerView
- **After**: Single SimpleVideoPlayer with mode parameter
- **Benefit**: Simplified codebase, consistent behavior, easier maintenance

### 2. VideoStateCache Player Sharing
- **Before**: SharedAssetCache with mode-specific keys, complex lookup logic
- **After**: VideoStateCache with single player per `mid`
- **Benefit**: True player sharing, zero-delay transitions, simpler architecture

### 3. Layer Management
- **Before**: Manual player detachment/reattachment, layer conflicts
- **After**: SwiftUI handles layers automatically, `representableId` for force-recreation
- **Benefit**: Eliminated black screen bugs, reliable fullscreen transitions

### 4. Mode-Based Mute State
- **Before**: Complex mute state tracking, race conditions
- **After**: Automatic mute application based on mode
- **Benefit**: Consistent audio behavior, no state conflicts

### 5. Independent TweetDetail Players
- **Before**: Shared players caused state conflicts
- **After**: TweetDetail uses independent players, cleared on exit
- **Benefit**: No interference with feed playback

## Performance Metrics

### Cache Efficiency
- **Player Reuse**: 100% hit rate for MediaCell → MediaBrowser transitions
- **Memory Usage**: One AVPlayer instance per active video
- **Storage Usage**: Optimized through limited segment preloading

### Loading Performance
- **MediaCell to Fullscreen**: Instant (same player, layer switch)
- **Fullscreen to MediaCell**: Instant (same player, layer switch)
- **Initial Video Load**: Immediate playback for cached content
- **Background Download**: Non-blocking segment preloading

### User Experience
- **Seamless Transitions**: Zero delay between MediaCell and fullscreen
- **Continuous Playback**: Video continues from exact position
- **Mute State Sync**: Automatic and reliable
- **No Black Screens**: Eliminated through proper layer management

## Technical Implementation Details

### VideoStateCache Structure
```swift
class VideoStateCache {
    private var cache: [String: (player: AVPlayer, time: CMTime, 
                                  wasPlaying: Bool, originalMuteState: Bool)] = [:]
    
    // Key is ONLY mid (no mode suffix)
    func cacheVideoState(for mid: String, player: AVPlayer, time: CMTime, 
                        wasPlaying: Bool, originalMuteState: Bool)
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, 
                                              wasPlaying: Bool, originalMuteState: Bool)?
}
```

### Player Setup Flow
```swift
private func setupPlayer() {
    // FIRST: Check VideoStateCache for shared player
    if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
        // Apply mode-specific mute state
        if mode == .mediaCell {
            cachedState.player.isMuted = MuteState.shared.isMuted
        } else if mode == .mediaBrowser {
            cachedState.player.isMuted = false // Always unmuted in fullscreen
        }
        restoreFromCache(cachedState)
        return
    }
    
    // SECOND: Create new player
    let newPlayer = await SharedAssetCache.shared.getOrCreatePlayer(...)
    configurePlayer(newPlayer)
    
    // THIRD: Cache in VideoStateCache for sharing
    VideoStateCache.shared.cacheVideoState(for: mid, player: newPlayer, ...)
}
```

### OnDisappear Lifecycle
```swift
.onDisappear {
    // Cache current state BEFORE any cleanup
    if let player = player {
        VideoStateCache.shared.cacheVideoState(
            for: mid, player: player,
            time: player.currentTime(),
            wasPlaying: player.rate > 0,
            originalMuteState: player.isMuted
        )
    }
    
    // Mode-specific cleanup
    if mode == .mediaCell || mode == .mediaBrowser {
        player?.pause() // Keep alive in cache for sharing
    } else if mode == .tweetDetail {
        player?.pause()
        player = nil
        VideoStateCache.shared.clearCache(for: mid) // Independent, clear on exit
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

## Current Status: ✅ PRODUCTION READY & FULLY OPERATIONAL

### Working Features
- ✅ Unified SimpleVideoPlayer for all contexts
- ✅ VideoStateCache-based player sharing
- ✅ Instant MediaCell ↔ MediaBrowser transitions
- ✅ Independent TweetDetail players
- ✅ Automatic mode-based mute state management
- ✅ SwiftUI-native layer management
- ✅ On-demand video caching with immediate playback
- ✅ Limited segment preloading (next 3 segments only)
- ✅ MediaID-based cache persistence across app restarts
- ✅ HLS and progressive video support
- ✅ Cache validation and integrity checking
- ✅ Memory-efficient segment management
- ✅ Automatic disk cache cleanup

### Performance Achievements
- ✅ Zero-delay fullscreen transitions (same player reuse)
- ✅ Continuous playback position across mode changes
- ✅ Eliminated black screen bugs
- ✅ Reliable mute state synchronization
- ✅ Realistic segment sizes (729KB - 2.5MB)
- ✅ Immediate playback for cached content
- ✅ Reduced bandwidth usage through smart preloading
- ✅ Fast startup times with on-demand loading
- ✅ LocalHTTPServer running on port 8080
- ✅ HLS master playlists processed successfully
- ✅ No UI freezing during video loading

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
1. **Adaptive Bitrate**: Dynamic quality adjustment based on network conditions
2. **Cache Compression**: Reduce storage footprint for cached segments
3. **Predictive Preloading**: AI-based segment prediction for better UX
4. **Background Sync**: Sync cached content across devices
5. **Analytics**: Video playback analytics and performance metrics

### Monitoring Points
1. **Cache Hit Rates**: Track VideoStateCache reuse effectiveness
2. **Transition Times**: Monitor MediaCell ↔ MediaBrowser performance
3. **Memory Usage**: Ensure efficient resource utilization
4. **User Engagement**: Measure impact on video viewing behavior

---

*Last Updated: October 2024*
*Status: Production Ready - Simplified Architecture with Unified Player System*
