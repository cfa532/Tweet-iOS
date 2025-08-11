# Tweet-iOS Video System

A comprehensive iOS video playback system with advanced caching, black screen elimination, and proactive loading capabilities.

## 🎯 Overview

The Tweet-iOS video system provides seamless video playback across different contexts (grid, detail, fullscreen) with robust error handling and performance optimization.

## 🏗️ Architecture

### Video Architecture Overview

```
📱 TweetListView (MediaCell)
├── VideoPlaceholderView (while loading)
└── SimpleVideoPlayer (when ready)
    └── Uses BackgroundVideoLoader for smooth scrolling

📱 TweetDetailView (DetailMediaCell)
└── SimpleVideoPlayer (direct)
    └── Immediate playback, no background loading

🖥️ MediaBrowserView (Fullscreen)
└── SimpleVideoPlayer (direct)
    └── Independent mute state, immediate playback
```

### Core Components

#### 1. **BackgroundVideoLoader** (`SimpleVideoPlayer.swift`)
- **Purpose**: Handles all video loading operations in background
- **Features**:
  - Prevents UI blocking during video loading
  - URL-based caching system
  - HLS playlist resolution
  - Concurrent loading task management
- **Usage**: Only in list views (TweetListView) for smooth scrolling

```swift
class BackgroundVideoLoader: ObservableObject {
    static let shared = BackgroundVideoLoader()
    private var playerCache: [String: AVPlayer] = [:]
    private var loadingTasks: [String: Task<AVPlayer, Error>] = [:]
    
    func loadVideo(for url: URL, mid: String) async throws -> AVPlayer
}
```

#### 2. **VideoPlaceholderSystem** (`VideoPlaceholderSystem.swift`)
- **Purpose**: Provides placeholder UI while videos load in background
- **Features**:
  - Fixed-size placeholders prevent scroll jumping
  - Background video loading
  - Smooth transition from placeholder to video
- **Usage**: Only in list views for better scrolling experience

#### 3. **SimpleVideoPlayer** (`SimpleVideoPlayer.swift`)
- **Purpose**: Core video player component with mode-based rendering
- **Features**:
  - Automatic HLS detection and handling
  - Custom playback controls
  - Background/foreground state management
  - Black screen recovery mechanisms
  - Mode-based rendering (mediaCell, mediaBrowser, fullscreen)

```swift
enum Mode {
    case mediaCell      // For list views with placeholders
    case mediaBrowser   // For detail/fullscreen views
    case fullscreen     // For landscape/portrait handling
}
```

#### 4. **MuteState** (`MuteState.swift`)
- **Purpose**: Global mute state management
- **Features**:
  - Singleton pattern for app-wide mute control
  - Preference persistence
  - Debounced refresh utilities
- **Usage**: Controls mute state across all video players

#### 5. **MediaGridView** (`MediaGridView.swift`)
- **Purpose**: Grid layout for multiple media items
- **Features**:
  - Sequential video playback
  - Visibility-based loading
  - Debounced video loading (0.3s delay)
  - Video placeholder integration

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

### 1. **Context-Aware Video Loading**
- **List Views**: Background loading with placeholders for smooth scrolling
- **Detail Views**: Direct loading for immediate playback
- **Fullscreen**: Direct loading with independent controls

### 2. **Video Placeholder System**
- Fixed-size placeholders prevent scroll jumping
- Background video loading while showing placeholders
- Smooth transition when videos are ready
- Memory-efficient placeholder management

### 3. **Sequential Playback**
- Only one video plays at a time in grid views
- Automatic pause/resume coordination
- Memory-efficient playback management

### 4. **Visibility-Based Loading**
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

### Mute State Management
- **Global Mute**: Controls all list view videos via MuteState.shared
- **Local Mute**: Fullscreen videos have independent mute controls
- **State Persistence**: Mute preferences saved to device storage
- **Debounced Refresh**: 1.5-second debounce for pull-to-refresh operations

## 📱 Usage Examples

### Grid View Integration (with Placeholders)
```swift
// Shows placeholder while video loads in background
if placeholderManager.isVideoReady(for: attachment.mid) {
    SimpleVideoPlayer(
        url: url,
        mid: attachment.mid,
        isVisible: isVisible,
        autoPlay: videoManager.shouldPlayVideo(for: attachment.mid),
        isMuted: muteState.isMuted,
        mode: .mediaCell
    )
} else {
    VideoPlaceholderView()
}
```

### Detail View Integration (Direct Loading)
```swift
SimpleVideoPlayer(
    url: url,
    mid: mid,
    isVisible: isVisible,
    autoPlay: true,
    isMuted: muteState.isMuted,
    mode: .mediaBrowser
)
```

### Fullscreen Integration (Independent Mute)
```swift
SimpleVideoPlayer(
    url: url,
    mid: attachment.mid,
    isVisible: index == currentIndex,
    autoPlay: index == currentIndex,
    isMuted: isFullscreenMuted, // Local mute state
    mode: .mediaBrowser
)
```

### Mute State Management
```swift
// Global mute control (for list views)
@ObservedObject private var muteState = MuteState.shared

// Local mute control (for fullscreen)
@State private var isFullscreenMuted = false

// Mute button with global state
MuteButton(muteState: muteState)
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

- ✅ **Grid Views**: Fully migrated to new system with placeholders
- ✅ **Detail Views**: Using SimpleVideoPlayer directly (no singleton managers)
- ✅ **Fullscreen**: Using SimpleVideoPlayer with independent mute state
- ✅ **Background Loading**: BackgroundVideoLoader active for list views only
- ✅ **Black Screen Recovery**: Multi-strategy system active
- ✅ **Mute State**: Centralized management with global/local state support
- ✅ **Video Placeholders**: Implemented for smooth scrolling experience

## 📚 Related Documentation

- `VideoPlaybackAlgorithm.md`: Detailed playback algorithms
- `CONSOLIDATED_VIDEO_PROCESSING.md`: Video processing overview
- `HLS_VIDEO_PROCESSING.md`: HLS-specific optimizations

---

**Note**: This system provides a robust, performant video playback experience with automatic error recovery and proactive loading capabilities.
