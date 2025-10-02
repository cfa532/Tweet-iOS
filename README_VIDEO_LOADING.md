# Video Background Loading System

This document explains the comprehensive background video loading system implemented in the Tweet-iOS app to optimize video playback performance and user experience.

## Overview

The video background loading system is designed to preload video assets and players before they're needed, reducing loading times and providing a smoother user experience in the TweetListView. The system uses modern Swift concurrency patterns and intelligent caching strategies.

## Architecture

### Core Components

#### 1. **SharedAssetCache** (`Sources/Core/SharedAssetCache.swift`)
The central caching system that manages video assets and players across the app.

**Key Features:**
- Asset and player caching with LRU eviction
- Priority-based preloading system
- Background cleanup and memory management
- Concurrent task handling
- HLS URL resolution

**Configuration:**
```swift
private let maxCacheSize = 20 // Maximum cached assets
private let maxPlayerCacheSize = 10 // Maximum cached players
private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
```

#### 2. **MediaCell** (`Sources/Features/MediaViews/MediaCell.swift`)
Individual video cells that handle background preloading for specific videos.

**Key Features:**
- Task-based background preloading
- Visual loading indicators
- Smart preloading strategy (asset → player)
- Proper task cancellation
- Visibility-based loading

#### 3. **MediaGridView** (`Sources/Features/MediaViews/MediaGridView.swift`)
Grid-level coordination for video preloading across multiple videos.

**Key Features:**
- Grid-level preloading initiation
- Priority management for multiple videos
- Coordination with individual cell preloading

#### 4. **SimpleVideoPlayer** (`Sources/Features/MediaViews/SimpleVideoPlayer.swift`)
The video player component that benefits from preloaded assets.

**Key Features:**
- Integration with SharedAssetCache
- Black screen fix after background
- ReadyForDisplay monitoring
- Player layer refresh mechanisms

#### 5. **VideoConversionService** (`Sources/Core/VideoConversionService.swift`)
Advanced video conversion service for HLS streaming with background processing.

**Key Features:**
- **HLS Conversion**: Converts videos to HLS format with multiple quality levels (720p, 480p)
- **Background Processing**: Uses background tasks and async/await for non-blocking conversion
- **Memory Management**: Comprehensive memory monitoring and cleanup
- **Aspect Ratio Support**: Intelligent scaling based on video orientation
- **Progress Tracking**: Real-time conversion progress with stage updates
- **FFmpeg Integration**: Uses FFmpegKit for high-quality video processing
- **Master Playlist Generation**: Creates adaptive bitrate streaming playlists

## Implementation Details

### Background Preloading Strategy

#### Phase 1: Asset Preloading (Light Operation)
```swift
// Preload asset first (lighter operation)
await MainActor.run {
    SharedAssetCache.shared.preloadAsset(for: url)
}
```

#### Phase 2: Player Preloading (Heavy Operation)
```swift
// Wait before preloading the full player
try await Task.sleep(nanoseconds: 200_000_000) // 0.2 second delay

// Preload the full player (heavier operation)
await MainActor.run {
    SharedAssetCache.shared.preloadVideo(for: url)
}
```

### Priority System

The system implements a three-tier priority system:

```swift
enum PreloadPriority {
    case high    // No delay, immediate preloading
    case normal  // 0.1 second delay per item
    case low     // 0.3 second delay per item
}
```

**Usage:**
- **High Priority**: First video in a grid, visible videos
- **Normal Priority**: Subsequent videos in a grid
- **Low Priority**: Background videos, off-screen content

### Task Management

#### Task Creation and Cancellation
```swift
// Create preload task
preloadTask = Task {
    // Preloading logic
}

// Cancel task when cell disappears
private func cancelPreloadTask() {
    preloadTask?.cancel()
    preloadTask = nil
    isPreloading = false
}
```

#### Concurrent Task Handling
```swift
// Check for existing loading task
if let existingTask = loadingTasks[cacheKey] {
    return try await existingTask.value
}
```

### Cache Management

#### LRU Eviction
```swift
private func manageCacheSize() {
    if assetCache.count > maxCacheSize {
        let sortedKeys = cacheTimestamps.sorted { $0.value < $1.value }.map { $0.key }
        let keysToRemove = sortedKeys.prefix(assetCache.count - maxCacheSize)
        
        for key in keysToRemove {
            assetCache.removeValue(forKey: key)
            cacheTimestamps.removeValue(forKey: key)
        }
    }
}
```

#### Background Cleanup
```swift
private func startBackgroundCleanup() {
    cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
        Task { @MainActor in
            self.performCleanup()
        }
    }
}
```

## Usage Examples

### Basic Video Preloading

```swift
// In MediaCell
private func startBackgroundPreloading() {
    guard isVideoAttachment,
          let url = attachment.getUrl(baseUrl),
          !shouldLoadVideo,
          preloadTask == nil else {
        return
    }
    
    preloadTask = Task {
        // Preload asset first
        await MainActor.run {
            SharedAssetCache.shared.preloadAsset(for: url)
        }
        
        // Then preload player
        await MainActor.run {
            SharedAssetCache.shared.preloadVideo(for: url)
        }
    }
}
```

### Grid-Level Preloading

```swift
// In MediaGridView
private func startBackgroundPreloading() {
    let videoURLs = videoAttachments.compactMap { index, attachment in
        attachment.getUrl(baseUrl)
    }
    
    // High priority for first video
    if let firstURL = videoURLs.first {
        SharedAssetCache.shared.preloadVideo(for: firstURL)
        
        // Normal priority for remaining videos
        let remainingURLs = Array(videoURLs.dropFirst())
        if !remainingURLs.isEmpty {
            SharedAssetCache.shared.preloadVideos(remainingURLs, priority: .normal)
        }
    }
}
```

### Using Cached Players

```swift
// In SimpleVideoPlayer
@MainActor func getOrCreatePlayer(for url: URL) async throws -> AVPlayer {
    // Try cached player first
    if let cachedPlayer = getCachedPlayer(for: url) {
        return cachedPlayer
    }
    
    // Create new player with asset
    let asset = try await getAsset(for: url)
    let playerItem = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: playerItem)
    
    // Cache for future use
    cachePlayer(player, for: url)
    
    return player
}
```

## Performance Benefits

### 1. **Reduced Loading Times**
- Videos start preloading before they're visible
- Cached assets provide instant playback
- Background processing doesn't block UI

### 2. **Better User Experience**
- Smooth video transitions
- No loading delays when scrolling
- Visual feedback during preloading

### 3. **Resource Efficiency**
- Smart memory management
- LRU cache eviction
- Background cleanup
- Task cancellation for unused operations

### 4. **Scalability**
- Handles multiple videos efficiently
- Priority-based loading
- Concurrent task management

## Configuration Options

### Cache Settings
```swift
// In SharedAssetCache
private let maxCacheSize = 20 // Adjust based on device memory
private let maxPlayerCacheSize = 10 // Balance between performance and memory
private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
```

### Preloading Delays
```swift
// In MediaCell
try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
try await Task.sleep(nanoseconds: 200_000_000) // 0.2 second delay
```

### Priority Delays
```swift
// In PreloadPriority
case .high: return 0 // No delay
case .normal: return Double(index) * 0.1 // 0.1 second per item
case .low: return Double(index) * 0.3 // 0.3 second per item
```

## Debugging and Monitoring

### Debug Logs
The system provides comprehensive debug logging:

```swift
print("DEBUG: [SHARED ASSET CACHE] Starting background asset preload for: \(url.lastPathComponent)")
print("DEBUG: [MEDIA CELL \(attachment.mid)] Starting background preloading")
print("DEBUG: [MediaGridView] Starting background preloading for \(videoAttachments.count) videos")
```

### Cache Statistics
```swift
@MainActor func getCacheStats() -> (assetCount: Int, playerCount: Int) {
    return (assetCache.count, playerCache.count)
}
```

## Best Practices

### 1. **Task Management**
- Always cancel tasks when views disappear
- Use proper async/await patterns
- Handle task cancellation gracefully

### 2. **Memory Management**
- Monitor cache sizes
- Implement proper cleanup
- Use LRU eviction for large caches

### 3. **Performance Optimization**
- Use appropriate priority levels
- Implement delays to prevent system overload
- Cache both assets and players

### 4. **User Experience**
- Provide visual feedback during loading
- Handle loading failures gracefully
- Maintain smooth scrolling performance

## Troubleshooting

### Common Issues

#### 1. **Memory Pressure**
- Reduce cache sizes
- Increase cleanup frequency
- Monitor memory usage

#### 2. **Slow Preloading**
- Check network connectivity
- Adjust preloading delays
- Verify URL resolution

#### 3. **Task Cancellation Issues**
- Ensure proper task cleanup
- Check view lifecycle management
- Verify cancellation logic

### Debug Commands
```swift
// Check cache status
let stats = SharedAssetCache.shared.getCacheStats()
print("Cache stats: \(stats)")

// Clear cache if needed
SharedAssetCache.shared.clearCache()
```

## Future Enhancements

### Potential Improvements
1. **Adaptive Preloading**: Adjust based on network conditions
2. **Predictive Loading**: Use ML to predict user behavior
3. **Quality Selection**: Preload appropriate quality based on device
4. **Bandwidth Management**: Limit concurrent downloads
5. **Offline Support**: Cache videos for offline viewing

### Monitoring and Analytics
1. **Performance Metrics**: Track loading times and cache hit rates
2. **User Behavior**: Monitor which videos are actually viewed
3. **Error Tracking**: Log and analyze loading failures
4. **Resource Usage**: Monitor memory and bandwidth consumption

## Conclusion

The background video loading system provides a robust, efficient solution for video preloading in the Tweet-iOS app. By combining modern Swift concurrency, intelligent caching, and priority-based loading, it significantly improves the user experience while maintaining optimal resource usage.

The system is designed to be scalable, maintainable, and easily configurable for different use cases and device capabilities.
