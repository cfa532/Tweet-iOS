# Video State Management Fix

## Problem Description

The app had several video state management issues:

1. **Black screen in fullscreen**: When videos were playing in MediaCell and then opened in fullscreen, they would show a black screen instead of continuing playback
2. **Videos marked as invalid after background**: When the app went to background and returned, videos were being marked as invalid and wouldn't play
3. **Aggressive cache clearing**: Video state cache was being cleared immediately after use, preventing proper state transfer between views
4. **Black screens after background transitions**: Videos would show black screens when the app returned from background, requiring reactive recovery

## Root Cause

The issues were caused by:
- Overly aggressive error handling that marked videos as invalid too easily
- Immediate cache clearing that prevented state transfer between MediaCell and fullscreen views
- Lack of resilience in video state restoration when the app returned from background
- **iOS detaching AVPlayer video layers during background transitions**, causing black screens

## Solution Implemented

### 1. Improved Error Handling
- **File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Changes**:
  - Modified `handleLoadFailure()` to not immediately clear the player (`player = nil` commented out)
  - Added fallback cache restoration for fullscreen modes even on failure
  - Reset error state when app becomes active

### 2. Persistent Cache Management
- **File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Changes**:
  - Removed immediate cache clearing in `restoreFromCache()`
  - Cache now persists for fullscreen transitions
  - Added comment explaining cache will be cleared by system cleanup

### 3. Enhanced Background/Foreground Handling
- **File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Changes**:
  - Improved `didBecomeActive` notification handling
  - Added automatic cache state restoration when app becomes active
  - Reset error states for videos that were interrupted

### 4. Aggressive Cache Restoration for Fullscreen
- **File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Changes**:
  - Enhanced `setupPlayer()` to prioritize cached state for fullscreen modes

### 5. **Preventive Black Screen Solution (NEW)**
- **File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Changes**:
  - **Player Detachment Strategy**: Detach AVPlayer when app enters background to prevent video layer invalidation
  - **Player Reattachment Strategy**: Reattach AVPlayer when app returns to foreground before user sees the app
  - **State Tracking**: Added `isPlayerDetached` state to track detachment status
  - **Visual Feedback**: Show "Video paused" placeholder instead of black screen when detached
  - **Seamless Recovery**: Automatically restore playback position and state when reattaching
  - Added fallback cache restoration for fullscreen modes when no cached state is found
  - Improved logging to track cache restoration attempts

## Key Code Changes

### Error Handling Improvement
```swift
private func handleLoadFailure() {
    loadFailed = true
    isLoading = false
    // Don't clear player immediately - let it persist for potential recovery
    // player = nil
    print("DEBUG: [VIDEO ERROR] Load failed for \(mid), retry count: \(retryCount)")
    
    // For fullscreen modes, try to restore from cache even on failure
    if mode == .fullscreen || mode == .mediaBrowser {
        print("DEBUG: [VIDEO ERROR] Fullscreen mode, attempting to restore from cache for \(mid)")
        restoreCachedVideoState()
    }
}
```

### Persistent Cache
```swift
// Don't clear cache immediately - let it persist for fullscreen transitions
// Cache will be cleared by the system cleanup or when explicitly needed
```

### Enhanced Background Recovery
```swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
    // App became active - restore video state without marking as invalid
    print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid)")
    
    // Always try to restore cached state first when app becomes active
    if player == nil && shouldLoadVideo {
        print("DEBUG: [VIDEO APP ACTIVE] No player found, attempting to restore cached state for \(mid)")
        restoreCachedVideoState()
    }
    
    // If video is visible and should play, resume playback
    if isVisible && currentAutoPlay && shouldLoadVideo {
        print("DEBUG: [VIDEO APP ACTIVE] Resuming playback for \(mid)")
        checkPlaybackConditions(autoPlay: currentAutoPlay, isVisible: isVisible)
    }
    
    // Reset error state for videos that might have been interrupted
    if loadFailed {
        print("DEBUG: [VIDEO APP ACTIVE] Resetting error state for \(mid)")
        retryCount = 0
        loadFailed = false
    }
}
```

### **Preventive Black Screen Solution (NEW)**
```swift
// Background/Foreground handling with player detachment
.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
    // App going to background - detach player to prevent black screens
    print("DEBUG: [VIDEO BACKGROUND] App entering background for \(mid)")
    detachPlayerForBackground()
}
.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
    // App will enter foreground - reattach player to prevent black screens
    print("DEBUG: [VIDEO FOREGROUND] App will enter foreground for \(mid)")
    reattachPlayerForForeground()
}

// Player detachment method
private func detachPlayerForBackground() {
    guard let player = player else { return }
    
    // Store current state before detaching
    let wasPlaying = player.rate > 0
    let currentTime = player.currentTime()
    
    // Cache the state for restoration
    VideoStateCache.shared.cacheVideoState(
        for: mid,
        player: player,
        time: currentTime,
        wasPlaying: wasPlaying,
        originalMuteState: mode == .mediaCell ? isMuted : MuteState.shared.isMuted
    )
    
    // Pause and mark as detached
    player.pause()
    isPlayerDetached = true
}

// Player reattachment method
private func reattachPlayerForForeground() {
    guard let player = player else { return }
    
    // Mark as reattached
    isPlayerDetached = false
    
    // Restore cached state if available
    if let cachedState = VideoStateCache.shared.getCachedState(for: mid) {
        // Restore mute state and seek to cached position
        player.isMuted = mode == .mediaCell ? MuteState.shared.isMuted : false
        player.seek(to: cachedState.time) { finished in
            if finished && cachedState.wasPlaying && self.isVisible && self.currentAutoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    player.play()
                }
            }
        }
    }
}

// Visual state management
@ViewBuilder
private func videoPlayerView() -> some View {
    if let player = player {
        ZStack {
            // Main video player - only show if not detached
            if !isPlayerDetached {
                VideoPlayer(player: player)
            } else {
                // Show placeholder when player is detached (background state)
                Rectangle()
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "pause.circle")
                                .font(.title)
                                .foregroundColor(.white.opacity(0.7))
                            Text("Video paused")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    )
            }
            // ... other UI elements
        }
    }
}
```

## Benefits

1. **Seamless fullscreen transitions**: Videos now properly continue playing when opened in fullscreen
2. **Resilient background handling**: Videos recover properly when the app returns from background
3. **Better user experience**: No more black screens or interrupted video playback
4. **Improved debugging**: Enhanced logging to track video state management
5. **Preventive black screen solution**: Videos no longer show black screens after background transitions
6. **Clear visual feedback**: Users see "Video paused" indicator instead of confusing black screens
7. **Proactive approach**: Fixes issues at the source rather than reacting to them after they occur

## Current Video Player Architecture

The `SimpleVideoPlayer` now implements a comprehensive video state management system:

### **State Management**
- **VideoStateCache**: Persistent cache for video states across view transitions
- **Player Detachment Tracking**: `isPlayerDetached` state prevents black screens
- **Mute State Management**: Proper handling of global and per-video mute states

### **Background/Foreground Handling**
- **Preventive Detachment**: Detach player when app enters background
- **Seamless Reattachment**: Reattach player when app returns to foreground
- **State Preservation**: Cache and restore playback position, playing status, and mute state

### **Error Recovery**
- **Graceful Degradation**: Fallback mechanisms for failed video loads
- **Retry Logic**: Automatic retry with exponential backoff
- **Cache Restoration**: Restore from cache even on failure for fullscreen modes

### **Visual States**
- **Loading State**: Progress indicator during video setup
- **Error State**: Retry button and error message for failed loads
- **Detached State**: "Video paused" placeholder during background transitions
- **Playing State**: Normal video playback with controls

## Testing

The fix has been tested and the app builds successfully. The changes are minimal and focused, maintaining the existing video architecture while improving its resilience and state management capabilities. The preventive black screen solution has been verified to work correctly during background/foreground transitions.
