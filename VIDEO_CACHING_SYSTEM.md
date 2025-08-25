# Video Caching System

This document explains the video caching system in the Tweet-iOS app.

## Overview

The video caching system uses **SharedAssetCache** to provide efficient video playback:

1. **SharedAssetCache** - URL-based caching for assets and players

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



## When to Use SharedAssetCache

### Use SharedAssetCache when:
- ✅ You have a URL and want to cache by URL
- ✅ You need preloading functionality
- ✅ You want automatic background cleanup
- ✅ You're working with SimpleVideoPlayer
- ✅ You need asset-level caching

## Integration Points

### SimpleVideoPlayer
- Uses **SharedAssetCache** for URL-based caching
- Benefits from preloading and background cleanup

### MediaCell & MediaGridView
- Use **SharedAssetCache** for preloading
- Coordinate background loading for better UX

## Benefits of This Architecture

1. **URL-based Caching**: Simple and efficient caching by URL
2. **Preloading Support**: Background loading reduces loading times
3. **Memory Management**: Automatic cleanup prevents memory issues
4. **HLS Support**: Handles both regular videos and HLS streams
5. **Comprehensive**: Single cache system for all video needs

## Migration from Old System

- ❌ **Removed**: `VideoAssetCache` (was unused and confusing)
- ❌ **Removed**: `VideoCacheManager` (was unused, replaced by SharedAssetCache)
- ✅ **Kept**: `SharedAssetCache` (actively used, comprehensive)

This consolidation eliminates confusion while maintaining all necessary functionality.
