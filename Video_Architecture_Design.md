# Video Architecture Design

## Overview

This document describes the new video architecture for the Tweet iOS app, designed to solve state conflicts between different video playback contexts while maintaining optimal user experience through shared video assets.

## Problem Statement

### Original Issues
The original architecture shared video player instances and state between three distinct contexts:
- **Grid/Preview Context** - MediaCell in tweet feeds and grids
- **Detail TabView Context** - TweetDetailView and CommentDetailView 
- **Full-Screen Context** - MediaBrowserView

This shared state caused multiple conflicts:
- VideoManager grid logic interfering with detail view autoplay
- Global mute state changes affecting all contexts
- Player pause/play commands from different contexts conflicting
- Shared VideoCacheManager causing lifecycle management issues

### Core Requirements
1. **Shared Video Data** - Avoid duplicate network requests and downloads
2. **Independent Playback State** - Each context should control its own playback behavior
3. **Context-Appropriate Behavior** - Grid sequential play, detail autoplay, full-screen native controls
4. **Optimal UX** - Fast loading, smooth transitions between contexts

## Architecture Solution

### Shared Assets + Independent Contexts

The new architecture separates **data sharing** from **state management**:

```
┌─────────────────────────────────────────────────────────────────┐
│                     VideoAssetCache (Shared)                     │
│  • AVPlayerItem instances                                       │
│  • Resolved HLS URLs                                            │
│  • Video metadata (duration, aspect ratio)                     │
│  • Network request deduplication                                │
│  • LRU cache with smart cleanup                                 │
└─────────────────────────────────────────────────────────────────┘
                                    ↑
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
┌─────────▼─────────┐ ┌─────────────▼─────────┐ ┌─────────────▼─────────┐
│  GridVideoContext │ │ DetailVideoContext   │ │FullscreenVideoContext │
│                   │ │                      │ │                       │
│ • Sequential play │ │ • Autoplay selected  │ │ • Native controls     │
│ • VideoManager    │ │ • Independent state  │ │ • Auto-replay         │
│ • Global mute     │ │ • Local mute         │ │ • Local mute          │
│ • Own AVPlayers   │ │ • Own AVPlayers      │ │ • Own AVPlayers       │
└───────────────────┘ └──────────────────────┘ └───────────────────────┘
```

## Implementation Details

### 1. VideoAssetCache (Shared Layer)

**Purpose**: Centralized cache for video assets that can be shared across all playback contexts.

**Key Features**:
- Caches resolved video URLs (handles HLS playlist resolution)
- Stores video metadata (duration, aspect ratio, video tracks)
- Provides `createPlayerItem()` method for creating new AVPlayer instances
- Smart cleanup with LRU eviction policy
- Thread-safe with proper locking

**Core Interface**:
```swift
class VideoAssetCache {
    static let shared = VideoAssetCache()
    
    func getAsset(for videoMid: String, originalURL: URL, contentType: String) async -> CachedVideoAsset
    func hasAsset(for videoMid: String) -> Bool
    func removeAsset(for videoMid: String)
    func clearCache()
}

struct CachedVideoAsset {
    let videoMid: String
    let originalURL: URL
    let resolvedURL: URL
    let isHLS: Bool
    let duration: TimeInterval
    let aspectRatio: Float
    
    func createPlayerItem() -> AVPlayerItem
}
```

### 2. DetailVideoContext (Independent Playback)

**Purpose**: Manages video playback state specifically for detail views (TweetDetailView, CommentDetailView).

**Key Features**:
- Uses shared VideoAssetCache for assets
- Creates independent AVPlayer instances
- Handles TabView selection-based autoplay
- Maintains local mute state (doesn't affect global)
- Proper cleanup and lifecycle management

**Core Interface**:
```swift
class DetailVideoContext: ObservableObject {
    func getPlayer(for videoMid: String, url: URL, contentType: String) async -> AVPlayer
    func setVideoSelected(_ videoMid: String, isSelected: Bool)
    func togglePlayback(for videoMid: String)
    func toggleMute(for videoMid: String)
    func cleanup()
}
```

**Playback Behavior**:
- Videos autoplay when their tab becomes selected
- Videos pause when deselected in TabView
- First-time autoplay only (subsequent visits require manual play)
- Independent mute state per video

### 3. DetailVideoView & DetailMediaView

**Purpose**: SwiftUI views that use DetailVideoContext for clean, independent video playback.

**Key Features**:
- Direct SwiftUI VideoPlayer usage (native iOS controls)
- Uses shared video assets for fast loading
- Independent from grid VideoManager system
- Handles mixed content (videos and images)
- Proper app lifecycle handling (background/foreground)

## Data Flow

### Asset Creation and Sharing
```
1. Video Request → VideoAssetCache.getAsset()
2. Check cache → Return existing OR Create new
3. HLS Resolution → Resolve playlist URLs if needed
4. Metadata Extraction → Get duration, aspect ratio
5. Cache Storage → Store for future use
6. Return CachedVideoAsset → Ready for player creation
```

### Context-Specific Player Creation
```
1. Context requests player → DetailVideoContext.getPlayer()
2. Get shared asset → VideoAssetCache.shared.getAsset()
3. Create player → AVPlayer(playerItem: asset.createPlayerItem())
4. Configure context → Set mute, autoplay, observers
5. Store player → Context maintains player reference
6. Return player → Ready for SwiftUI VideoPlayer
```

### TabView Selection Flow
```
1. Tab becomes selected → DetailMediaView.onChange(isSelected: true)
2. Update context → DetailVideoContext.setVideoSelected(true)
3. Check autoplay → If first time, start playback
4. Player control → player.play() or player.pause()
5. State update → Update internal playback state
```

## Benefits

### Shared Efficiency
- **No Duplicate Downloads**: Same video URL cached once across all contexts
- **Instant Asset Access**: Grid → Detail → Fullscreen uses same cached data
- **HLS Resolution Cached**: Playlist URLs resolved once and reused
- **Memory Efficient**: Shared AVPlayerItem data with independent player instances

### Independent Control
- **No State Conflicts**: Each context manages its own playback state
- **Context-Appropriate Behavior**: 
  - Grid: Sequential playback with VideoManager
  - Detail: Autoplay on selection with native controls
  - Fullscreen: Native controls with auto-replay
- **Isolated Mute States**: Detail and fullscreen audio doesn't affect global mute
- **Clean Separation**: Changes in one context don't affect others

### Developer Experience
- **Clear Ownership**: Each context owns its players and state
- **Simplified Debugging**: No cross-context interference
- **Maintainable**: Changes isolated to specific contexts
- **Extensible**: Easy to add new video contexts without conflicts

## Usage Examples

### Grid Context (Existing)
```swift
// Uses existing VideoManager + VideoCacheManager
// Sequential playback, global mute state
MediaCell(parentTweet: tweet, attachmentIndex: 0, videoManager: VideoManager())
```

### Detail Context (New)
```swift
// Uses DetailVideoContext + VideoAssetCache
// Independent autoplay, local mute state
DetailMediaView(
    attachment: attachment,
    parentTweet: tweet,
    isSelected: index == selectedIndex,
    aspectRatio: aspectRatio,
    onImageTap: { showBrowser = true }
)
```

### Full-Screen Context (Future)
```swift
// Will use FullscreenVideoContext + VideoAssetCache
// Native controls, auto-replay, local mute state
FullscreenVideoView(
    attachment: attachment,
    tweet: tweet
)
```

## Migration Strategy

### Phase 1: Detail Views (Completed)
- ✅ Created VideoAssetCache for shared video data
- ✅ Created DetailVideoContext for independent detail playback
- ✅ Created DetailVideoView and DetailMediaView
- ✅ Updated TweetDetailView and CommentDetailView to use new architecture

### Phase 2: Full-Screen Views (Pending)
- Create FullscreenVideoContext for MediaBrowserView independence
- Update MediaBrowserView to use new architecture
- Remove dependencies on existing VideoCacheManager

### Phase 3: Grid Optimization (Future)
- Enhance existing VideoManager to use VideoAssetCache
- Maintain current grid behavior while gaining asset sharing benefits
- Gradual migration without breaking existing functionality

## Technical Considerations

### Thread Safety
- VideoAssetCache uses NSLock for thread-safe operations
- All context operations are @MainActor for UI updates
- Async/await used for asset loading and metadata extraction

### Memory Management
- LRU cache eviction prevents unlimited memory growth
- Weak references used in observers to prevent retain cycles
- Proper cleanup methods for context lifecycle

### Performance
- Asset caching eliminates duplicate network requests
- Metadata cached to avoid repeated expensive operations
- Background loading for smooth user experience

### Error Handling
- Graceful fallbacks for HLS resolution failures
- Timeout handling for network requests
- Recovery mechanisms for corrupted cache entries

## Future Enhancements

### Analytics Integration
- Track cache hit/miss ratios
- Monitor context-specific playback metrics
- Performance monitoring for asset loading times

### Advanced Caching
- Disk-based cache for video segments
- Predictive preloading based on user behavior
- Smart cache warming strategies

### Cross-Context Coordination
- Shared playback position for seamless transitions
- Coordinated quality selection across contexts
- Unified video download progress tracking

## Conclusion

This architecture provides the optimal balance between **performance** (shared video assets) and **maintainability** (independent contexts). Each video context can now implement behavior appropriate to its use case without interfering with others, while still benefiting from shared video data for optimal user experience.

The separation of concerns makes the system more robust, easier to debug, and simpler to extend with new video contexts in the future.
