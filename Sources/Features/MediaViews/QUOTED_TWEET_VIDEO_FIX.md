# Quoted Tweet Video Issues Fix

## Issues Fixed

### Issue 1: Black Screen on Detail → Detail Navigation
When navigating from an outer tweet's detail view to a quoted tweet's detail view, the video would show a **black screen**.

### Issue 2: Video Stops Immediately in Parent Detail View  
When opening a parent tweet's detail view that contains a quoted tweet with video, the quoted video would autoplay briefly but then stop immediately.

## Root Causes

### Issue 1: Session Counting Bug

The `DetailVideoManager` singleton uses `activeDetailViewCount` to track active detail views, with a 0.3-second delayed cleanup. However, `activateForDetail()` had a critical bug:

**Old buggy code:**
```swift
func activateForDetail() {
    guard !isActive else { return }  // Returns early on 2nd view!
    beginDetailViewSession()         // Never called for 2nd view
}
```

**Problem flow:**
1. First detail view: count = 1
2. Second detail view: count stays at 1 (early return)
3. First detail view disappears: count = 0 → player cleared
4. Black screen

### Issue 2: Coordinator Stops Embedded Videos

The video playback coordinator was sending stop/pause commands to **all** `.mediaCell` and `.embeddedDetail` mode videos when the feed disappears. The quoted tweet's video (`.embeddedDetail` mode) was being stopped even though it was visible in the detail view.

**Problem flow:**
1. Parent detail view opens
2. Quoted video starts playing (autoplay)
3. TweetListView disappears → sends `.stopAllVideos`
4. Coordinator sends stop command to quoted video
5. Video stops immediately

## Solutions

### Fix 1: Session Counting (SingletonVideoManagers.swift)

Separated session counting from lifecycle management:

```swift
func activateForDetail() {
    // CRITICAL: Always increment count, even if already active
    beginDetailViewSession()
    
    guard !isActive else {
        print("📱 [DetailVideoManager] Already active - incremented session count to \(activeDetailViewCount)")
        return
    }
    isActive = true
    registerLifecycleObservers()
}

func deactivate() {
    // CRITICAL: Always decrement count
    endDetailViewSession()
    
    guard isActive && activeDetailViewCount == 0 else {
        print("📱 [DetailVideoManager] Session ended - count now \(activeDetailViewCount)")
        return
    }
    isActive = false
    teardownAppLifecycleNotifications()
}
```

**Now:**
- First detail view: count = 1
- Second detail view: count = 2 ✅
- First detail view disappears: count = 1 → no clear ✅
- Player stays intact

### Fix 2: Protect Embedded Videos from Coordinator (SimpleVideoPlayer.swift)

Added protection to ignore coordinator stop/pause commands for visible embedded videos in detail views:

```swift
private func handleCoordinatorStopCommand(notification: Notification? = nil) {
    guard mode == .mediaCell || mode == .embeddedDetail else { return }
    
    // CRITICAL: If we're in embeddedDetail mode and visible inside a TweetDetailView,
    // ignore stop commands from the coordinator
    if mode == .embeddedDetail && NavigationStateManager.shared.isDetailViewActive && isVisible {
        print("⏸️ [COORDINATOR] Ignoring stop for visible embeddedDetail video in detail view")
        return
    }
    
    // ... rest of stop logic
}
```

Same protection added to `handleCoordinatorPauseCommand()`.

**Logic:**
- `.embeddedDetail` mode in detail view → ignore coordinator commands
- `.embeddedDetail` mode in feed → respond to coordinator commands
- `.mediaCell` mode → always respond to coordinator commands

## Testing

### Test Case 1: Detail → Detail Navigation
1. Open a tweet with quoted tweet (with video)
2. Open outer tweet's detail view
3. Navigate to quoted tweet's detail view
4. ✅ Video should load and play (not black screen)
5. Navigate back and forth
6. ✅ Video should work on repeated navigation

### Test Case 2: Quoted Video Autoplay in Parent Detail
1. Play a quoted tweet's video in the feed
2. Open the parent tweet's detail view
3. ✅ Quoted video should continue playing (not stop)
4. Video should remain playing while viewing comments

### Test Case 3: Feed Coordination Still Works
1. Play a video in the feed
2. Scroll to another video
3. ✅ First video should stop (coordinator still controls feed)

## Key Insights

### Session Counting vs Lifecycle Management
The old code conflated two concerns:
- **Lifecycle observers** (should register once per app session)
- **Active view counting** (should track every detail view)

By checking `isActive` before calling `beginDetailViewSession()`, the second detail view's session was never counted.

### Coordinator Scope
The coordinator is designed to manage **feed videos** to prevent multiple videos playing simultaneously. However, **detail view videos** operate in a different context:
- User explicitly navigated to view the content
- Only one detail view is focused at a time
- Video should autoplay and stay playing

By checking `NavigationStateManager.shared.isDetailViewActive && isVisible`, we distinguish between:
- Embedded video in **feed** (should be coordinated)
- Embedded video in **detail view** (should be independent)

## Related Files

- `SingletonVideoManagers.swift` - DetailVideoManager session counting fix
- `SimpleVideoPlayer.swift` - Coordinator command protection for embedded videos
- `TweetDetailView.swift` - Calls activateForDetail/deactivate

## Additional Optimizations

### HLS URL Caching (SharedAssetCache.swift)
While fixing these issues, we also added HLS URL resolution caching:
- **Added**: `resolvedHLSURLCache` dictionary
- **Caches**: Resolved HLS URLs (master.m3u8/playlist.m3u8) for 1 hour
- **Benefit**: Eliminates 0.3-0.35s network checks on subsequent loads
- **Impact**: Faster load times and smoother navigation

## Impact Summary

**Before:**
- ❌ Black screen on detail → detail navigation
- ❌ Quoted videos stop when parent detail opens
- ⚠️ 0.3s+ hang on first video load

**After:**
- ✅ Smooth video playback in all detail views
- ✅ Quoted videos stay playing in parent detail
- ✅ Instant resolution on cached videos
- ✅ Proper feed coordination maintained
