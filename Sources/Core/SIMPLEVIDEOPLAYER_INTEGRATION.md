# SimpleVideoPlayer Integration Instructions

## Critical: You Need to Add Notification Handlers to SimpleVideoPlayer

The fix in `TweetDetailView.swift` posts notifications that `SimpleVideoPlayer` needs to handle. Here's what you need to add to your `SimpleVideoPlayer` file:

## 1. Add Notification Observers in `onAppear` or `init`

```swift
// In SimpleVideoPlayer's onAppear or init:
.onAppear {
    // ... existing code ...
    
    // Setup notification observers
    NotificationCenter.default.addObserver(
        forName: NSNotification.Name("RestoreVideoPosition"),
        object: nil,
        queue: .main
    ) { [weak self] notification in
        self?.handleRestorePosition(notification)
    }
    
    NotificationCenter.default.addObserver(
        forName: NSNotification.Name("SaveVideoPosition"),
        object: nil,
        queue: .main
    ) { [weak self] notification in
        self?.handleSavePosition(notification)
    }
}
.onDisappear {
    // Remove observers
    NotificationCenter.default.removeObserver(
        self,
        name: NSNotification.Name("RestoreVideoPosition"),
        object: nil
    )
    NotificationCenter.default.removeObserver(
        self,
        name: NSNotification.Name("SaveVideoPosition"),
        object: nil
    )
}
```

## 2. Add Handler Methods

```swift
private func handleRestorePosition(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let videoMid = userInfo["videoMid"] as? String,
          videoMid == self.mid, // Only handle if it's for this video
          let time = userInfo["time"] as? CMTime,
          let wasPlaying = userInfo["wasPlaying"] as? Bool,
          let player = player else {
        return
    }
    
    print("🔄 [SimpleVideoPlayer] Restoring position for \(mid): \(time.seconds)s, wasPlaying: \(wasPlaying)")
    
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
        guard finished, let self = self, let player = player else { return }
        
        print("✅ [SimpleVideoPlayer] Restored position to \(time.seconds)s")
        
        if wasPlaying {
            player.play()
            print("▶️ [SimpleVideoPlayer] Resumed playback")
        }
    }
}

private func handleSavePosition(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let videoMid = userInfo["videoMid"] as? String,
          videoMid == self.mid, // Only handle if it's for this video
          let contextString = userInfo["context"] as? String,
          let player = player else {
        return
    }
    
    let wasPlaying = player.rate > 0
    let currentTime = player.currentTime()
    
    // Parse context
    let context: PersistentVideoStateManager.VideoPlaybackState.VideoContext
    switch contextString {
    case "detail":
        context = .detailView
    case "fullscreen":
        context = .fullScreen
    default:
        context = .mediaCell
    }
    
    PersistentVideoStateManager.shared.saveState(
        videoMid: mid,
        currentTime: currentTime,
        wasPlaying: wasPlaying,
        context: context
    )
    
    print("💾 [SimpleVideoPlayer] Saved state: time=\(currentTime.seconds)s, wasPlaying=\(wasPlaying), context=\(context.rawValue)")
}
```

## 3. Alternative: Direct Integration (Recommended)

If you have access to modify `SimpleVideoPlayer` directly, this is a better approach:

```swift
// In SimpleVideoPlayer - where it handles app lifecycle:

// When app will resign active (screen lock):
func handleAppWillResignActive() {
    guard let player = player else { return }
    
    let wasPlaying = player.rate > 0
    let currentTime = player.currentTime()
    
    // Save to both caches (existing + new)
    // ... existing cache code ...
    
    // ADD: Save to persistent storage
    if mode == .tweetDetail {
        PersistentVideoStateManager.shared.saveState(
            videoMid: mid,
            currentTime: currentTime,
            wasPlaying: wasPlaying,
            context: .detailView
        )
        print("💾 [SimpleVideoPlayer] Saved to PersistentVideoStateManager")
    }
    
    player.pause()
}

// When player is created/ready:
func onPlayerReady() {
    guard let player = player else { return }
    
    // Check for saved state
    if mode == .tweetDetail,
       let savedState = PersistentVideoStateManager.shared.getState(videoMid: mid),
       PersistentVideoStateManager.shared.shouldRestorePlayback(videoMid: mid, context: .detailView) {
        
        print("🔄 [SimpleVideoPlayer] Restoring saved position: \(savedState.currentTime.seconds)s")
        
        player.seek(to: savedState.currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            
            print("✅ [SimpleVideoPlayer] Restored position")
            
            if savedState.wasPlaying {
                player.play()
                print("▶️ [SimpleVideoPlayer] Resumed playback")
            }
        }
    }
}
```

## Which Approach to Use?

### Notification Approach (Current)
**Pros:**
- No need to modify SimpleVideoPlayer extensively
- Keeps SimpleVideoPlayer independent
- Easy to test

**Cons:**
- Adds notification overhead
- Indirect coupling

### Direct Integration (Recommended)
**Pros:**
- More direct and efficient
- Easier to debug
- Better performance

**Cons:**
- Requires modifying SimpleVideoPlayer
- Tighter coupling

## Testing

After adding the handlers, you should see:

**On Screen Lock:**
```
💾 [SimpleVideoPlayer] Saved state: time=2.5s, wasPlaying=true, context=detail
```

**On Screen Unlock:**
```
🔄 [SimpleVideoPlayer] Restoring position for {mid}: 2.5s, wasPlaying: true
✅ [SimpleVideoPlayer] Restored position to 2.5s
▶️ [SimpleVideoPlayer] Resumed playback
```

## Common Issues

### Issue: "Restored position" logs appear but video still restarts
**Solution**: The seek might be happening before player is ready. Add a delay:
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    player.seek(...)
}
```

### Issue: State is saved but not restored
**Solution**: Check if `shouldRestorePlayback` is returning false:
- State might be expired (>5 minutes)
- Context might not match
- Add debug logs to check

### Issue: Multiple restorations happening
**Solution**: Use a flag to prevent duplicate restoration:
```swift
@State private var hasRestoredPosition = false

if !hasRestoredPosition {
    // restore...
    hasRestoredPosition = true
}
```

## Next Steps

1. Locate your `SimpleVideoPlayer.swift` file
2. Add the notification handlers OR direct integration
3. Build and test
4. Look for the log messages to verify it's working

If you can't find `SimpleVideoPlayer.swift`, search for:
- `"VIDEO BACKGROUND"` - this log comes from SimpleVideoPlayer
- `mode: .tweetDetail` - this is how it's created
- `struct SimpleVideoPlayer` or `class SimpleVideoPlayer`
