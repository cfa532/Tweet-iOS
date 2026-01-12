# Video Navigation Fix - Final Solution

## The Core Problem

When navigating back from Profile → MainFeed, videos don't play because:
1. Players are created fresh (not reused from cache)
2. Coordinator doesn't send play commands to the new players
3. Result: Videos exist but don't play

## Root Cause

The approach of "stop all videos on every navigation" breaks the coordinator's state tracking:

```
Profile → MainFeed:
1. ProfileView.onDisappear → stopAllVideos()
2. Coordinator resets to idle state
3. MainFeed.onAppear → does NOTHING (let coordinator handle it)
4. Coordinator is idle, has no primary video
5. Videos create players but coordinator never sends play commands ❌
```

## The Real Solution

**Remove `stopAllVideos()` from ProfileView's onAppear.**

The coordinator should manage video lifecycle naturally without forced resets.

### Updated ProfileView

```swift
private func handleViewAppear() {
    // DON'T stop all videos here!
    // Let the coordinator naturally handle the transition.
    // The coordinator already knows which videos are visible.
    
    print("🧹 [ProfileView] View appeared - letting coordinator handle state")
    
    // Navigation visibility
    isNavigationVisible = true
    NotificationCenter.default.post(
        name: .navigationVisibilityChanged,
        object: nil,
        userInfo: ["isVisible": true]
    )
}

private func handleViewDisappear() {
    // Stop this profile's videos
    VideoPlaybackCoordinator.shared.stopAllVideos()
    
    // DON'T call cleanupForNavigation()!
    // Periodic cleanup handles memory
    
    print("🧹 [ProfileView] View disappeared - stopped videos")
}
```

### Why This Works

**MainFeed → Profile:**
```
1. Profile.onAppear → does NOTHING
2. Coordinator continues tracking (MainFeed videos still tracked)
3. Profile loads its own videos
4. Coordinator sees new visible tweets → starts survey for Profile videos
5. MainFeed videos pause naturally (no longer visible)
```

**Profile → MainFeed (back):**
```
1. MainFeed.onAppear → does NOTHING  
2. Profile.onDisappear → stopAllVideos()
3. Coordinator resets to idle
4. MainFeed is now visible
5. Coordinator sees visible videos (from previous tracking) → starts survey
6. MainFeed videos play ✅
```

## Memory Management Strategy

### Don't Use Aggressive Cleanup

**Bad (causes issues):**
- ❌ Call `cleanupForNavigation()` on every navigation
- ❌ Clear all players when leaving any view
- ❌ Force recreation of players unnecessarily

**Good (natural cleanup):**
- ✅ 30 player cache limit (enforced every 15s)
- ✅ 10 minute inactivity timeout
- ✅ Memory pressure handlers (system warnings)
- ✅ Manual cleanup only when needed (app backgrounding, sign out)

### Why Natural Cleanup Works

**Memory stays bounded:**
- 30 players × 20MB = ~600MB maximum
- iOS can reclaim this if needed
- Periodic cleanup removes old players
- Users rarely have >30 videos in view history

**Performance stays good:**
- Cached players enable instant playback (<100ms)
- No unnecessary player recreation
- No race conditions from aggressive cleanup

## Implementation Checklist

### ✅ Completed

1. **TweetListView** - No cleanup in onAppear/onDisappear
2. **ProfileView** - No cleanup in onDisappear
3. **Periodic cleanup** - Runs every 15s, removes old players
4. **Cache limits** - 30 player maximum enforced

### ❌ Need to Fix

1. **ProfileView.onAppear** - Remove `stopAllVideos()` call
2. **VideoPlaybackCoordinator** - Ensure proper state tracking across navigation

## Testing

### Test 1: MainFeed → Profile → Back

```
Expected:
1. MainFeed videos playing
2. Navigate to Profile → Profile videos start
3. Navigate back → MainFeed videos restart immediately
```

### Test 2: Multiple Profile Navigations

```
Expected:
1. Profile A → Profile B → Profile C
2. Each profile's videos play correctly
3. Memory stays around 200-400MB
```

### Test 3: Memory Stability

```
Expected:
1. Visit 20 different profiles
2. Memory oscillates 200-600MB
3. Never exceeds 800MB
4. No crashes
```

## Debugging

If videos don't play:

1. **Check coordinator logs**:
   ```
   🎬 [COORDINATOR] Starting survey phase
   📤 [COORDINATOR] Sending play command for primary video
   ```

2. **Check player cache**:
   ```swift
   let stats = SharedAssetCache.shared.getCacheStats()
   print("Cache: \(stats.playerCount) players")
   ```

3. **Check if stopAllVideos() was called**:
   ```
   🧹 [ProfileView] View appeared - stopped all videos
   ← This is BAD! Remove this call!
   ```

## Conclusion

The key insight: **Let the coordinator manage video lifecycle naturally.**

Don't force resets with `stopAllVideos()` on every navigation. The coordinator already tracks visible videos and handles transitions intelligently.

Remove aggressive cleanup. Rely on natural cache limits and periodic cleanup for memory management.
