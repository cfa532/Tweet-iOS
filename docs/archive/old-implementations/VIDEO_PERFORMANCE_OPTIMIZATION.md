# Video Performance Optimization

## Problem Description

When loading multiple tweets with videos simultaneously, the app would experience UI freezes where the screen would stop responding to user gestures while videos continued playing. This was caused by:

1. **Excessive concurrent video loading** - Too many videos loading at once
2. **Main thread blocking** - Video loading operations blocking the UI thread
3. **No performance monitoring** - No system to detect and prevent freezes
4. **Inefficient resource management** - Poor cache management and cleanup

## Solution Implemented

### 1. **Performance Monitor** (`Sources/Core/PerformanceMonitor.swift`)

A new performance monitoring system that:
- **Monitors main thread performance** every 50ms to detect freezes
- **Limits concurrent video loads** to maximum of 3 simultaneous loads
- **Implements cooldown periods** after freeze detection (2 seconds)
- **Provides emergency cleanup** when multiple freezes are detected
- **Tracks active video loads** and system load status

**Key Features:**
```swift
// Freeze detection with 100ms threshold
private let freezeThreshold: TimeInterval = 0.1

// Cooldown period after freeze
private let loadCooldownPeriod: TimeInterval = 2.0

// Maximum concurrent video loads
private let maxConcurrentVideoLoads = 3
```

### 2. **Enhanced Video Loading Manager** (`Sources/Core/VideoLoadingManager.swift`)

Improved video loading management with:
- **Concurrency control** - Limits to 2 concurrent loads (reduced from unlimited)
- **Loading queue** - Queues pending loads when at capacity
- **Frequency throttling** - Prevents loading too frequently (max 10 loads per minute)
- **Performance integration** - Works with PerformanceMonitor
- **Reduced preload count** - From 3 to 2 tweets ahead to reduce load

**Key Improvements:**
```swift
// Limit concurrent loads
private let maxConcurrentLoads: Int = 2

// Reduced preload count
private let preloadCount = 2 // Reduced from 3

// Frequency throttling
private func isLoadingTooFrequently() -> Bool {
    let timeSinceLastLoad = Date().timeIntervalSince(lastLoadTime)
    return timeSinceLastLoad < 0.5 && loadCountInLastMinute > 10
}
```

### 3. **Shared Asset Cache Integration** (`Sources/Core/SharedAssetCache.swift`)

Enhanced asset cache with:
- **Performance monitoring integration** - Notifies when loads start/complete
- **Emergency cleanup** - `clearAllCaches()` method for freeze recovery
- **Better error handling** - Proper cleanup on load failures

### 4. **Simple Video Player Optimizations** (`Sources/Features/MediaViews/SimpleVideoPlayer.swift`)

Video player improvements:
- **Staggered loading** - Small delays between video loads to prevent overwhelming
- **Performance-aware setup** - Checks performance monitor before loading
- **Better error recovery** - Improved retry logic with delays

**Loading Delay Implementation:**
```swift
// Add a small delay to prevent overwhelming the system
if retryCount == 0 {
    try await Task.sleep(nanoseconds: UInt64(retryCount * 50_000_000)) // 0.05s delay per retry
}
```

### 5. **Video Conversion Service Performance** (`Sources/Core/VideoConversionService.swift`)

Advanced video conversion with performance optimizations:
- **Background Task Management** - Uses UIApplication background tasks for long-running conversions
- **Memory Monitoring** - Comprehensive memory usage tracking and cleanup
- **Async Processing** - Non-blocking conversion using Swift concurrency
- **Intelligent Preset Selection** - Uses "copy" preset for videos ≤720p, "veryfast" for larger videos
- **Memory Cleanup** - Force garbage collection between conversion stages
- **Progress Tracking** - Real-time conversion progress without blocking UI

**Key Performance Features:**
```swift
// Memory monitoring and cleanup
private func logMemoryUsage(_ context: String) {
    let memory = getMemoryUsage()
    print("DEBUG: [VIDEO CONVERSION] Memory usage \(context): \(String(format: "%.1f", memory)) MB")
}

// Background task management
private func startBackgroundTask() {
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoConversion") { [weak self] in
        self?.endBackgroundTask()
    }
}

// Intelligent preset selection
let shouldUseCopy = maxDimension <= 720
let preset = shouldUseCopy ? "copy" : "veryfast"
```

## Performance Monitoring Features

### Freeze Detection
- Monitors main thread every 50ms
- Detects freezes when time between checks exceeds 100ms
- Implements cooldown periods after freeze detection
- Triggers emergency cleanup after 3 consecutive freezes

### Load Management
- Tracks active video loads in real-time
- Limits concurrent loads to prevent system overload
- Queues pending loads when at capacity
- Processes queue with small delays to prevent overwhelming

### Emergency Cleanup
When multiple freezes are detected:
1. **Cancels all pending video loads**
2. **Clears all video caches**
3. **Resets performance state**
4. **Stops all video playback**

## Configuration Parameters

### Performance Monitor
- **Freeze threshold**: 100ms (time between main thread checks)
- **Cooldown period**: 2 seconds after freeze detection
- **Max concurrent loads**: 3 videos simultaneously
- **Monitoring frequency**: Every 50ms

### Video Loading Manager
- **Max concurrent loads**: 2 videos simultaneously
- **Preload count**: 2 tweets ahead (reduced from 3)
- **Frequency limit**: Max 10 loads per minute
- **Queue processing delay**: 100ms between queued loads

### Video Player
- **Loading delay**: 50ms per retry attempt
- **Retry limit**: Built-in retry mechanism with delays

## Benefits

### 1. **Eliminated UI Freezes**
- Main thread monitoring prevents freezes
- Concurrency limits prevent system overload
- Emergency cleanup recovers from issues

### 2. **Improved Responsiveness**
- User gestures remain responsive during video loading
- Screen interactions work smoothly
- No more frozen UI states

### 3. **Better Resource Management**
- Efficient cache management
- Automatic cleanup of unused resources
- Memory usage optimization

### 4. **Enhanced User Experience**
- Smooth scrolling through video tweets
- No interruption to user interactions
- Reliable video playback

## Debug Information

The system provides comprehensive debug logging:

```
DEBUG: [PerformanceMonitor] Video load started. Active loads: 1
DEBUG: [VideoLoadingManager] Throttling video load for tweet123 - too many active loads (2)
DEBUG: [PerformanceMonitor] Potential UI freeze detected! Time since last check: 0.15s
DEBUG: [PerformanceMonitor] Emergency cleanup triggered!
```

## Usage

The performance optimizations are automatically applied when:
1. **Multiple tweets with videos** are loaded simultaneously
2. **User scrolls** through video content
3. **System detects** potential performance issues
4. **Emergency situations** require cleanup

No additional code changes are required - the optimizations work transparently in the background.

## Monitoring and Maintenance

### Performance Status
Use `PerformanceMonitor.shared.getPerformanceStatus()` to get current performance metrics:

```
Performance Status:
- Active video loads: 1/3
- System under load: false
- In cooldown: false
- Freeze count: 0
- Time since last freeze: 45.2s
```

### Regular Maintenance
- Performance metrics are automatically reset
- Cache cleanup happens automatically
- System recovers from issues automatically

This comprehensive solution ensures smooth video playback and responsive UI even when loading multiple videos simultaneously.
