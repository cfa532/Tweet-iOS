# Tweet-iOS Video System

A comprehensive iOS video playback system with advanced caching, black screen elimination, and proactive loading capabilities.

## 🎯 Overview

The Tweet-iOS video system provides seamless video playback across different contexts (grid, detail, fullscreen) with robust error handling and performance optimization.

## 🏗️ Architecture

### Core Components

#### 1. **BackgroundVideoLoader** (`SimpleVideoPlayer.swift`)
- **Purpose**: Handles all video loading operations in background
- **Features**:
  - Prevents UI blocking during video loading
  - URL-based caching system
  - HLS playlist resolution
  - Concurrent loading task management

```swift
class BackgroundVideoLoader: ObservableObject {
    static let shared = BackgroundVideoLoader()
    private var playerCache: [String: AVPlayer] = [:]
    private var loadingTasks: [String: Task<AVPlayer, Error>] = [:]
    
    func loadVideo(for url: URL, mid: String) async throws -> AVPlayer
}
```

#### 2. **SingletonVideoManagers** (`SingletonVideoManagers.swift`)
- **DetailVideoManager**: Manages video playback in detail views
- **FullscreenVideoManager**: Handles fullscreen video playback
- **Features**:
  - Context-aware video management
  - Automatic play/pause coordination
  - State persistence across view transitions

```swift
@MainActor
class DetailVideoManager: ObservableObject {
    @Published var currentPlayer: AVPlayer?
    @Published var currentVideoMid: String?
    @Published var isPlaying = false
}
```

#### 3. **SimpleVideoPlayer** (`SimpleVideoPlayer.swift`)
- **Purpose**: Core video player component with custom controls
- **Features**:
  - Automatic HLS detection and handling
  - Custom playback controls
  - Background/foreground state management
  - Black screen recovery mechanisms

#### 4. **MediaGridView** (`MediaGridView.swift`)
- **Purpose**: Grid layout for multiple media items
- **Features**:
  - Sequential video playback
  - Visibility-based loading
  - Debounced video loading (0.3s delay)

## 🎬 Video Loading Strategy

### Proactive Loading System

#### 1. **Debounced Loading**
```swift
// 0.3-second delay to prevent rapid loading during scroll
videoLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
    shouldLoadVideo = true
    // Setup video playback
}
```

#### 2. **Background Loading**
- All heavy video operations moved to background queue
- UI remains responsive during video loading
- Concurrent loading with task management

#### 3. **HLS Resolution**
```swift
private func resolveHLSURL(_ url: URL) async throws -> URL {
    // Try master.m3u8 first
    let masterURL = url.appendingPathComponent("master.m3u8")
    // Fallback to playlist.m3u8
    let playlistURL = url.appendingPathComponent("playlist.m3u8")
    // Final fallback to original URL
}
```

### Cache Management

#### URL-Based Caching
```swift
private var playerCache: [String: AVPlayer] = [:]
private var loadingTasks: [String: Task<AVPlayer, Error>] = [:]
```

#### Loading Task Management
- Prevents duplicate loading for same URL
- Concurrent task handling
- Automatic cleanup of completed tasks

## 🛡️ Black Screen Elimination

### Multi-Strategy Recovery System

#### 1. **Enhanced Player Layer Restoration**
```swift
private func restorePlayerLayer(cachedPlayer: CachedVideoPlayer, mid: String) {
    let player = cachedPlayer.player
    let currentTime = player.currentTime()
    let wasPlaying = player.rate > 0
    
    // Strategy 1: Immediate micro-seek to force layer refresh
    player.seek(to: currentTime, toleranceBefore: CMTime(value: 1, timescale: 600), 
                toleranceAfter: CMTime(value: 1, timescale: 600)) { completed in
        // Strategy 2: Brief pause-play cycle to reinitialize layer
        if wasPlaying {
            player.pause()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                player.play()
            }
        }
    }
    
    // Strategy 3: Force immediate layer update by changing volume
    let currentVolume = player.volume
    player.volume = currentVolume == 1.0 ? 0.99 : 1.0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        player.volume = currentVolume
    }
}
```

#### 2. **Background/Foreground State Management**
```swift
// Prepare for background transition
func prepareForBackground() {
    for (mid, cachedPlayer) in videoCache {
        let player = cachedPlayer.player
        let currentTime = player.currentTime()
        let wasPlaying = player.rate > 0
        
        // Store state for quick restoration
        cachedPlayer.preservedTime = currentTime
        cachedPlayer.wasPlayingBeforeBackground = wasPlaying
    }
}

// Immediate restoration after foreground
func immediateRestoreVideoPlayers() {
    for (mid, cachedPlayer) in videoCache {
        if let preservedTime = cachedPlayer.preservedTime {
            player.seek(to: preservedTime, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                if completed, cachedPlayer.wasPlayingBeforeBackground {
                    DispatchQueue.main.async {
                        player.play()
                    }
                }
            }
        }
    }
}
```

#### 3. **Health Monitoring**
```swift
func checkVideoLayerHealth(for videoMid: String) -> Bool {
    guard let playerItem = player.currentItem,
          playerItem.status == .readyToPlay else {
        return false
    }
    
    let hasVideoTracks = duration > 0 && playerItem.presentationSize.width > 0
    return hasVideoTracks && duration > 0
}
```

#### 4. **Nuclear Recovery Option**
```swift
func recreateVideoPlayerView(for videoMid: String) {
    // Post notification to trigger VideoPlayer recreation
    NotificationCenter.default.post(
        name: NSNotification.Name("RecreateVideoPlayer"),
        object: nil,
        userInfo: ["videoMid": videoMid]
    )
}
```

## 🚀 Performance Optimizations

### 1. **Sequential Playback**
- Only one video plays at a time in grid views
- Automatic pause/resume coordination
- Memory-efficient playback management

### 2. **Visibility-Based Loading**
```swift
.onAppear {
    // Mark grid as visible
    isVisible = true
    
    // Start video loading timer if grid contains videos
    let hasVideos = attachments.contains(where: { 
        $0.type.lowercased() == "video" || $0.type.lowercased() == "hls_video" 
    })
    
    if hasVideos {
        videoLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            shouldLoadVideo = true
            // Setup video playback
        }
    }
}
.onDisappear {
    isVisible = false
    videoLoadTimer?.invalidate()
    shouldLoadVideo = false
    videoManager.stopSequentialPlayback()
}
```

### 3. **Context-Aware Management**
- Different managers for different contexts
- Automatic state synchronization
- Efficient resource utilization

## 🔧 Configuration

### Video Loading Delays
- **Grid Loading**: 0.3 seconds debounce
- **Background Operations**: User-initiated QoS
- **HLS Resolution**: Automatic fallback chain

### Cache Settings
- **URL-based caching**: Efficient memory usage
- **Task management**: Prevents duplicate loading
- **Automatic cleanup**: Memory pressure handling

## 📱 Usage Examples

### Grid View Integration
```swift
SimpleVideoPlayer(
    url: url,
    mid: attachment.mid,
    autoPlay: videoManager.shouldPlayVideo(for: attachment.mid),
    showControls: false
)
```

### Detail View Integration
```swift
DetailVideoManager.shared.setCurrentVideo(
    url: url,
    mid: attachment.mid,
    autoPlay: true
)
```

### Fullscreen Integration
```swift
FullscreenVideoManager.shared.setCurrentVideo(
    url: url,
    mid: attachment.mid,
    autoPlay: true
)
```

## 🐛 Troubleshooting

### Common Issues

#### 1. **Black Screen**
- Automatic recovery via multi-strategy restoration
- Manual refresh via `forceRefreshVideoLayer()`
- Nuclear option via `recreateVideoPlayerView()`

#### 2. **Loading Delays**
- Check network connectivity
- Verify HLS playlist availability
- Monitor background task completion

#### 3. **Memory Issues**
- Automatic cache cleanup on memory pressure
- LRU eviction for old videos
- Background task cancellation

### Debug Logging
All components include comprehensive debug logging:
```swift
print("DEBUG: [BACKGROUND LOADER] Starting background load for: \(mid)")
print("DEBUG: [VIDEO CACHE] Enhanced restoration completed for mid: \(mid)")
print("DEBUG: [DETAIL VIDEO MANAGER] Setting current video: \(mid)")
```

## 🔄 Migration Status

- ✅ **Grid Views**: Fully migrated to new system
- ✅ **Detail Views**: Using new SingletonVideoManagers
- ✅ **Fullscreen**: New FullscreenVideoManager
- ✅ **Background Loading**: BackgroundVideoLoader active
- ✅ **Black Screen Recovery**: Multi-strategy system active

## 📚 Related Documentation

- `VideoPlaybackAlgorithm.md`: Detailed playback algorithms
- `CONSOLIDATED_VIDEO_PROCESSING.md`: Video processing overview
- `HLS_VIDEO_PROCESSING.md`: HLS-specific optimizations

---

**Note**: This system provides a robust, performant video playback experience with automatic error recovery and proactive loading capabilities.
