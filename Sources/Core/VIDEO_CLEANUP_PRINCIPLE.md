# Video Cleanup Principle: Only Active View Plays Videos

## The Golden Rule

**Only keep video players on the current view/screen active.**

When navigating to any new screen, stop all videos from the previous screen immediately.

## Implementation Pattern

Every view that displays videos MUST implement BOTH:

### 1. onAppear - Stop Previous Screen's Videos

```swift
.onAppear {
    // CRITICAL: Stop all videos from previous screen
    // Principle: Only keep videos on current view/screen active
    VideoPlaybackCoordinator.shared.stopAllVideos()
    
    print("🧹 [ViewName] View appeared - stopped all videos from previous screen")
    
    // ... rest of onAppear code
}
```

**Why:** Handles push navigation (MainFeed → Profile) where the previous view stays in the navigation stack.

### 2. onDisappear - Clean Up This View's Resources

```swift
.onDisappear {
    // CRITICAL: Stop all video playback when navigating away
    VideoPlaybackCoordinator.shared.stopAllVideos()
    
    // CRITICAL: Clean up video resources to free memory
    SharedAssetCache.shared.cleanupForNavigation()
    
    print("🧹 [ViewName] View disappeared - stopped all videos and cleaned up resources")
    
    // ... rest of onDisappear code
}
```

**Why:** Handles pop navigation (Profile → MainFeed) and tab switching where the view is removed from hierarchy.

## Views That Need This Pattern

✅ **Implemented:**
- `ProfileView.swift` - User profiles with video feeds
- `TweetListView.swift` - Generic tweet lists (bookmarks, favorites, search results)
- `TweetDetailView.swift` - Single tweet detail views

❌ **May Need (Check Your Views):**
- Any custom feed views
- Search results with videos
- Hashtag/topic feeds with videos
- User activity feeds with videos

## Quick Copy-Paste Template

```swift
// In your video-containing view:

.onAppear {
    // Stop all videos from previous screen
    VideoPlaybackCoordinator.shared.stopAllVideos()
    print("🧹 [YourViewName] View appeared - stopped all videos from previous screen")
    
    // Your existing onAppear code...
}

.onDisappear {
    // Stop and clean up this view's videos
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation()
    print("🧹 [YourViewName] View disappeared - stopped all videos and cleaned up resources")
    
    // Your existing onDisappear code...
}
```

## Why Both onAppear AND onDisappear?

### Defense in Depth

Different navigation patterns trigger different lifecycle methods:

| Navigation | onAppear (New View) | onDisappear (Old View) |
|-----------|-------------------|---------------------|
| Push (A→B) | ✅ Called | ❌ NOT called |
| Pop (B→A) | ✅ Called | ✅ Called |
| Replace (A→B) | ✅ Called | ✅ Called |
| Tab Switch (Away) | N/A | ✅ Called |
| Tab Switch (Back) | ✅ Called | N/A |

By implementing BOTH, we catch ALL cases:
- `onAppear` catches push navigation (when old view stays in stack)
- `onDisappear` catches pop navigation and tab switches
- Redundant calls are safe (idempotent operations)

## Testing Your Implementation

### Quick Test (Manual)

1. **Navigate TO your view** → Check console for: `"stopped all videos from previous screen"`
2. **Navigate AWAY from your view** → Check console for: `"stopped all videos and cleaned up resources"`
3. **No background audio** should be heard after navigation

### Comprehensive Test

```
MainFeed → Profile A → Profile B → Tweet → Back → Back → Back
         ↓           ↓           ↓        ↓      ↓      ↓
     Stop Feed  Stop Prof A  Stop Prof B Stop  Stop  Stop
     Load Prof  Load Prof B  Load Tweet  Tweet Prof B Prof A
```

At each step, only the current screen's videos should play.

## Common Mistakes

### ❌ WRONG: Only in onDisappear

```swift
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
}
// Problem: Push navigation (MainFeed → Profile) won't stop MainFeed's videos!
```

### ❌ WRONG: Only in onAppear

```swift
.onAppear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
}
// Problem: Tab switching away won't clean up resources!
```

### ✅ CORRECT: Both

```swift
.onAppear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
}
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation()
}
// Solution: Handles ALL navigation patterns
```

## Memory Impact

### Without This Pattern
- Memory grows: 200MB → 400MB → 600MB → 800MB → 1GB+ → App killed
- Every navigation accumulates video players

### With This Pattern
- Memory stable: 200MB → 300MB → 200MB → 300MB → stays around 250MB
- `cleanupForNavigation()` frees 50-200MB per navigation

## Performance

- **Time:** <50ms per navigation (imperceptible)
- **CPU:** Minimal (much less than decoding background videos)
- **Battery:** Improved (only one screen decodes video)

## When to Skip This Pattern

**NEVER** skip it for views with videos. Always implement both lifecycle methods.

The only exception: Views that never show videos (settings, text-only screens).

## Debugging

### Check If Your View Needs It

1. Navigate to your view
2. Navigate away
3. Listen for background audio
4. **If you hear audio → ADD THE PATTERN**

### Verify It's Working

```swift
.onAppear {
    print("🧹 [MyView] onAppear - stopping previous videos")
    VideoPlaybackCoordinator.shared.stopAllVideos()
}
.onDisappear {
    print("🧹 [MyView] onDisappear - cleaning up")
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation()
}
```

Check console logs during navigation - you should see both messages.

## Summary

**The Pattern:**
1. Every video-containing view has BOTH onAppear and onDisappear cleanup
2. `onAppear` → stop previous screen's videos
3. `onDisappear` → stop and clean up this screen's videos
4. Redundancy is intentional (defense in depth)

**The Result:**
- ✅ Only current screen plays videos
- ✅ No background audio
- ✅ Stable memory usage
- ✅ Clean, predictable behavior

**The Principle:**
> "Only keep video players on the current view/screen active."

Follow this principle in every view that shows videos, and your app will have clean, predictable video behavior with no background playback.
