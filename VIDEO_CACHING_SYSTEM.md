# Video Caching System

This document explains the video caching system in the Tweet-iOS app after consolidating the overlapping cache implementations.

## Overview

The video caching system consists of **two complementary caches** that work together to provide efficient video playback:

1. **SharedAssetCache** - URL-based caching for assets and players
2. **VideoCacheManager** - MID-based caching for players

## Architecture

### 1. SharedAssetCache (`Sources/Core/SharedAssetCache.swift`)

**Purpose**: URL-based caching for video assets and players with preloading support

**Key Features:**
- **Asset Caching**: Stores `AVAsset` objects by URL
- **Player Caching**: Stores `AVPlayer` objects by URL  
- **Preloading System**: Priority-based background loading
- **Background Cleanup**: Automatic expiration (5 minutes)
- **HLS Support**: Automatic HLS URL resolution

**Configuration:**
```swift
private let maxCacheSize = 20 // Maximum cached assets
private let maxPlayerCacheSize = 10 // Maximum cached players
private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
```

**Usage Examples:**
```swift
// Get cached player
if let player = SharedAssetCache.shared.getCachedPlayer(for: url) {
    // Use cached player
}

// Get or create player
let player = try await SharedAssetCache.shared.getOrCreatePlayer(for: url)

// Preload video
SharedAssetCache.shared.preloadVideo(for: url)

// Preload asset only
SharedAssetCache.shared.preloadAsset(for: url)
```

### 2. VideoCacheManager (`Sources/Core/VideoCacheManager.swift`)

**Purpose**: MID-based player caching for video identification

**Key Features:**
- **MID-based Keys**: Uses video `mid` (unique ID) instead of URL
- **Player Caching**: Stores `AVPlayer` objects by video ID
- **Memory Management**: Responds to memory warnings
- **HLS Support**: Caches resolved HLS playlist URLs

**Configuration:**
```swift
private let maxCacheSize = Constants.VIDEO_CACHE_POOL_SIZE
```

**Usage Examples:**
```swift
// Get cached player by MID
if let player = VideoCacheManager.shared.getCachedPlayer(for: videoMid) {
    // Use cached player
}

// Get or create player
let player = VideoCacheManager.shared.getVideoPlayer(for: videoMid, url: url)
```

## When to Use Which Cache

### Use SharedAssetCache when:
- ✅ You have a URL and want to cache by URL
- ✅ You need preloading functionality
- ✅ You want automatic background cleanup
- ✅ You're working with SimpleVideoPlayer
- ✅ You need asset-level caching

### Use VideoCacheManager when:
- ✅ You have a video `mid` and want to cache by ID
- ✅ You need to identify videos by their unique ID
- ✅ You're working with VideoTimeRemainingLabel
- ✅ You need MID-based player lookup

## Integration Points

### SimpleVideoPlayer
- Uses **SharedAssetCache** for URL-based caching
- Benefits from preloading and background cleanup

### VideoTimeRemainingLabel  
- Uses **VideoCacheManager** for MID-based player lookup
- Needs to find players by video ID, not URL

### MediaCell & MediaGridView
- Use **SharedAssetCache** for preloading
- Coordinate background loading for better UX

## Benefits of This Architecture

1. **Dual Caching Strategy**: URL-based for assets, MID-based for players
2. **Efficient Lookup**: Can find players by both URL and video ID
3. **Preloading Support**: Background loading reduces loading times
4. **Memory Management**: Automatic cleanup prevents memory issues
5. **HLS Support**: Handles both regular videos and HLS streams

## Migration from Old System

- ❌ **Removed**: `VideoAssetCache` (was unused and confusing)
- ✅ **Kept**: `SharedAssetCache` (actively used, comprehensive)
- ✅ **Kept**: `VideoCacheManager` (actively used, MID-based)

This consolidation eliminates confusion while maintaining all necessary functionality.
