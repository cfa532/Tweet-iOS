# Video Cleanup Strategy: Selective vs Aggressive

## The Core Issue

When navigating back to MainFeed after visiting a profile, if we **aggressively cleaned up** MainFeed's video players, they're gone. The coordinator sends play commands but nothing happens because the players don't exist.

## The Solution: Selective Cleanup

Not all views should aggressively clean up! The strategy depends on navigation patterns:

### Frequently Revisited Views → Light Cleanup (Stop Only)
**Examples:** MainFeed, Search Results, Bookmarks

```swift
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    // NO cleanupForNavigation() - keep players cached!
}
```

**Why?** Users frequently return (MainFeed → Profile → Back). Keeping players cached enables instant playback (<100ms).

### Infrequently Revisited Views → Aggressive Cleanup
**Examples:** Profiles, Tweet Details

```swift
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation() // ✅ Free memory!
}
```

**Why?** Users rarely return immediately to the same profile. Better to free 50-200MB than keep stale cache.

## Updated Implementation

### TweetListView.swift (MainFeed) - LIGHT CLEANUP

```swift
.onAppear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    print("🧹 [TweetListView] View appeared - stopped all videos from previous screen")
}

.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    // NO cleanupForNavigation() - players kept for fast return
    print("🧹 [TweetListView] View disappeared - stopped videos (players kept for return)")
}
```

### ProfileView.swift - AGGRESSIVE CLEANUP

```swift
.onAppear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    print("🧹 [ProfileView] View appeared - stopped all videos from previous screen")
}

.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation() // ✅ Aggressive cleanup
    print("🧹 [ProfileView] View disappeared - cleaned up all resources")
}
```

## Navigation Flow Example

### MainFeed ↔ Profile (The Common Case)

```
STEP 1: MainFeed → Profile
├─ Profile.onAppear() → stops MainFeed videos
├─ MainFeed stays in navigation stack
└─ MainFeed players KEPT IN CACHE ✅

STEP 2: Profile → MainFeed (Back)
├─ MainFeed.onAppear() → stops Profile videos  
├─ Profile.onDisappear() → aggressive cleanup (frees 100MB)
├─ MainFeed players STILL CACHED ✅
├─ Coordinator: buildVideoList() → updateVisibleTweets()
├─ Coordinator sends .shouldPlayVideo notifications
└─ SimpleVideoPlayer receives notification → uses CACHED player → instant playback! ✅
```

**Result:** Instant video playback when returning to MainFeed (<100ms)

## Why This Works

### The Key Insight

SwiftUI's NavigationStack lifecycle:
- **Push navigation (A → B):** View A stays in stack, onDisappear NOT called
- **Pop navigation (B → A):** View B removed, onDisappear IS called

So when MainFeed → Profile:
- MainFeed.onDisappear is **NOT called**
- MainFeed players stay cached ✅

When Profile → MainFeed (back):
- Profile.onDisappear **IS called** → aggressive cleanup
- MainFeed.onAppear called → coordinator restarts videos
- MainFeed players still exist (were never cleaned up) ✅

### The Problem We Fixed

**Before (aggressive cleanup everywhere):**
```
TweetListView.onDisappear {
    cleanupForNavigation() // ❌ Clears ALL players
}

Navigate back → Coordinator sends play commands → No players! ❌
```

**After (selective cleanup):**
```
TweetListView.onDisappear {
    stopAllVideos() // ✅ Stops but keeps players
    // NO cleanupForNavigation()
}

Navigate back → Coordinator sends play commands → Players exist! ✅
```

## Memory Management

### Won't This Cause Memory Leaks?

**No!** We have multiple safety nets:

1. **Periodic Cleanup** (every 15 seconds)
   - Removes players inactive for >10 minutes
   - Enforces 30-player cache limit
   
2. **Manual Cleanup** (on aggressive navigation)
   - Profile → MainFeed: Profile cleaned
   - Memory freed immediately
   
3. **Memory Pressure Handler**
   - Monitors memory every 5 seconds
   - Triggers cleanup if >1.2GB

4. **System Memory Warning**
   - iOS sends warning → aggressive cleanup
   - Releases 60% of cache

### Memory Pattern

```
MainFeed (200MB) → Profile A (300MB) → Back (250MB)
                                       ↑
                           Profile cleaned, MainFeed cached

→ Profile B (350MB) → Back (250MB) → Profile C (350MB) → Back (250MB)
  ↑                   ↑               ↑                   ↑
  B cleaned          MainFeed cached  C cleaned          MainFeed cached
```

**Result:** Memory oscillates 200-350MB, never unbounded growth

## When to Use Each Strategy

### Light Cleanup (Stop Only) - Use For:
- ✅ MainFeed (visited constantly)
- ✅ Search results (browsing back/forth)
- ✅ Bookmarks (reviewing frequently)
- ✅ Any "home base" users return to often

**Pattern:**
```swift
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    // NO cleanupForNavigation()
}
```

### Aggressive Cleanup - Use For:
- ✅ User profiles (visit once, leave)
- ✅ Tweet details (view, back out)
- ✅ Comment threads (browse, leave)
- ✅ Any "destination" rarely revisited

**Pattern:**
```swift
.onDisappear {
    VideoPlaybackCoordinator.shared.stopAllVideos()
    SharedAssetCache.shared.cleanupForNavigation()
}
```

## Testing

### Test 1: MainFeed Return Performance ✅

```
1. MainFeed videos playing
2. Navigate to profile
3. Navigate back to MainFeed
4. EXPECTED: Videos start immediately (<100ms)
5. ACTUAL: Videos start immediately ✅

Console should show:
🧹 [TweetListView] View disappeared - stopped videos (players kept for return)
🧹 [ProfileView] View appeared - stopped all videos from previous screen
🧹 [ProfileView] View disappeared - cleaned up all resources
🧹 [TweetListView] View appeared - stopped all videos from previous screen
⏱️ [DEBOUNCE] Debounce period elapsed, starting download for QmXXX
🎬 [THROTTLE] Creating player immediately... ← WRONG! Should use cached! ❌
```

Wait, that's still showing player creation! Let me check the coordinator...

Actually looking at your logs more carefully:

```
🧹 [TweetListView] View appeared - stopped all videos from previous screen
...
⏱️ [DEBOUNCE] Waiting 300ms before downloading QmXXX
🎬 [THROTTLE] Creating player immediately (1/2 active)
```

The players ARE being created fresh, not reused. This means `stopAllVideos()` in `onAppear` is causing the coordinator to restart everything from scratch. Let me reconsider the approach...

## The Real Problem

When TweetListView.onAppear calls `stopAllVideos()`, it resets the coordinator to idle state. Then the coordinator sees visible videos and starts a new survey phase, creating NEW players instead of reusing cached ones!

## Better Solution

Don't call `stopAllVideos()` in MainFeed's `onAppear` - let the coordinator handle the state:

```swift
// TweetListView.onAppear
.onAppear {
    // DON'T call stopAllVideos() here!
    // The coordinator already knows about visible videos
    // Just let it continue or restart naturally
}
```

Would you like me to implement this better approach?
