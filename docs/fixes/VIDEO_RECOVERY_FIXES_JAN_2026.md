# Video Recovery Fixes - January 2026

**Date**: January 8, 2026  
**Status**: ✅ Fixed and Deployed

---

## Overview

This document describes three critical fixes for video playback issues related to background recovery, pagination, and finished video restart behavior.

---

## Problem #1: Pagination Cache Fallback Failure

### Issue
When scrolling to load more tweets (pagination), if the network connection fails, cached tweets were not loaded either, leaving the user with no content.

### Root Cause
The `loadSinglePage` function in `TweetListView.swift` had a try-catch block that would:
1. Try to fetch from cache
2. If cache fetch threw an error, catch it and exit
3. Never attempt to load from server

This meant that if there was any issue with the cache (empty, corrupted, etc.), the server fetch never happened, resulting in no tweets at all.

### Solution
Changed to a best-effort cache loading approach:

```swift
// Step 1: Try to load from cache first (best-effort, don't fail on errors)
var tweetsFromCache: [Tweet?] = []
do {
    tweetsFromCache = try await tweetFetcher(page, pageSize, true)
    if !tweetsFromCache.isEmpty {
        // Show cached tweets immediately
        tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
    }
} catch {
    // Cache failed - not critical, we'll try server next
    print("⚠️ [PAGINATION] Cache fetch failed, will try server")
}

// Step 2: ALWAYS try server (even if cache failed)
Task {
    await loadFromServer(page: page, pageSize: pageSize, completion: completion)
}
```

### Benefits
✅ Cache succeeds, server succeeds: Instant UX with cached data, then fresh server data  
✅ Cache succeeds, server fails: Cached data shown and kept  
✅ Cache fails, server succeeds: Server data loaded successfully (was broken before)  
✅ Cache fails, server fails: Loading indicator cleared, user can try again  

### Files Changed
- `Sources/Tweet/TweetListView.swift`

---

## Problem #2: Stuck Loading Spinner After Long Background

### Issue
After the app returns from a long background period (>5 minutes), on-screen videos show a loading spinner that never disappears, even though the player itself is working fine and has buffered data ready.

### Root Cause
When the app returns from long background:
1. Video players are cleared and recreated during background recovery
2. For videos that are visible, `handleReloadVisibleVideosOnly()` is called
3. If the player is intact (not broken), it keeps the existing player
4. However, the `loadingState` variable can be stuck at `.loading` from before backgrounding
5. The KVO observers that normally transition loading state to `.loaded` don't fire again because the player is already ready
6. Result: Spinner stays visible forever

### Solution
Added checks in two locations to detect and fix stuck loading states by verifying actual buffered data:

#### Location 1: `handleReloadVisibleVideosOnly()` (~line 2670)
```swift
// CRITICAL FIX: Check if loading state is stuck even though player is ready
if loadingState.isLoading, let playerItem = player?.currentItem,
   playerItem.status == .readyToPlay, !playerItem.loadedTimeRanges.isEmpty {
    let bufferedDuration = bufferedTimeAhead(for: playerItem, player: player!)
    if bufferedDuration >= firstFrameMinimumBuffer {
        NSLog("🔧 [RELOAD VISIBLE FIX] Loading state stuck after background for \(mid) - fixing")
        loadingState = .loaded
        retryAttempts = 0
    }
}
```

#### Location 2: `handleVisibilityChange()` (~line 1472)
```swift
// CRITICAL FIX: Check buffered duration to ensure we have enough data before hiding spinner
if loadingState.isLoading {
    let bufferedDuration = bufferedTimeAhead(for: playerItem, player: player)
    if bufferedDuration >= firstFrameMinimumBuffer {
        loadingState = .loaded
        retryAttempts = 0
    }
}
```

### Why This Works
- Only clears spinner when player has **sufficient buffered data** (not just "ready" status)
- Runs during background recovery path and normal visibility checks
- Doesn't interfere with VideoPlaybackCoordinator or normal playback flow
- Targeted fix that only addresses the visual spinner issue

### Files Changed
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

---

## Problem #3: Finished Videos Not Auto-Playing When Scrolled Back

### Issue
When a video finishes playing and the user scrolls away, then scrolls back to that video, it doesn't restart from the beginning. The video stays at the last frame and doesn't auto-play.

### Root Cause
In `handleVisibilityChange()`, when a video becomes visible:
1. If player exists and is not broken, it goes to the "healthy player" path
2. This path calls `restoreCachedVideoState()` which keeps the current playback position
3. The code never checks if `playbackState == .finished` and needs resetting
4. Result: Video stays finished at last frame, doesn't restart

### Solution
Added explicit check for finished videos when they become visible:

```swift
// CRITICAL FIX: Reset finished videos when scrolled back into view
if mode == .mediaCell && playbackState == .finished {
    NSLog("🔄 [VIDEO RESET] Resetting finished video \(mid) to beginning on visibility")
    VideoStateCache.shared.clearCachedState(for: mid)
    playbackState = .notStarted
    if let player = player {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            // After seeking, check playback conditions to start if appropriate
            Task { @MainActor in
                self.checkPlaybackConditions(autoPlay: self.currentAutoPlay, isVisible: true)
            }
        }
    }
    return
}
```

### Behavior
When a finished video is scrolled back into view:
1. ✅ Detected as finished via `playbackState == .finished`
2. ✅ State cleared from VideoStateCache
3. ✅ Playback state reset to `.notStarted`
4. ✅ Player seeks to beginning (time 0)
5. ✅ Playback conditions checked (VideoPlaybackCoordinator decides if it should play)
6. ✅ Video enters survey phase or plays as primary based on coordinator rules

### Files Changed
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

---

## Testing Checklist

### Pagination Cache Fallback
- [ ] Enable airplane mode
- [ ] Scroll down to load more tweets
- [ ] Verify cached tweets from previous sessions appear
- [ ] Disable airplane mode and continue scrolling
- [ ] Verify new tweets load from server

### Stuck Loading Spinner
- [ ] Start playing a video in feed
- [ ] Background app for >5 minutes (or force quit and reopen)
- [ ] Return to app
- [ ] Verify video spinner disappears and video plays
- [ ] Test with multiple videos on screen

### Finished Video Restart
- [ ] Let a video play to completion in feed
- [ ] Scroll away from the finished video
- [ ] Scroll back to the finished video
- [ ] Verify video restarts from beginning
- [ ] Verify video auto-plays according to coordinator rules

---

## Implementation Notes

### Design Principles
1. **Minimal Interference**: Fixes don't modify VideoPlaybackCoordinator logic or recovery flags
2. **Targeted Solutions**: Each fix addresses specific symptoms without broad side effects
3. **Defensive Checks**: Verify actual player state (buffered data) not just status flags
4. **Coordinator Respect**: All playback decisions still go through VideoPlaybackCoordinator

### Rejected Approaches
- ❌ Resetting `hasRecoveredThisCycle` flags: Caused all videos to play simultaneously
- ❌ Aggressive player recreation: Interfered with coordinator and visibility detection
- ❌ Checking SharedAssetCache for cleared players: Too many false positives

### Future Considerations
- Monitor for edge cases with offscreen videos after share sheet + background
- Consider additional buffering heuristics for slow networks
- Evaluate if finished video restart should have animation/fade effect

---

## Related Documentation
- [Video System Architecture](../VIDEO_SYSTEM.md)
- [Complete Video Resume Solution](../COMPLETE_VIDEO_RESUME_SOLUTION.md)
- [Share Sheet Video Recovery](./SHARE_SHEET_VIDEO_RECOVERY_FIX.md)
- [Background Video Recovery](./UNIFIED_BACKGROUND_RECOVERY.md)

