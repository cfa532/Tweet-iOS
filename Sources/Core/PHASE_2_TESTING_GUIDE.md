# Phase 2 Implementation - Testing Guide

## Pre-Testing Setup

### 1. Verify Implementation
```bash
# Check that all changes are in place
grep -n "PHASE 2" VideoPlaybackCoordinator.swift
# Should show 15 locations with Phase 2 comments
```

### 2. Build and Run
- ✅ Ensure the app compiles without errors
- ✅ No warnings related to SharedVideoPlayerManager
- ✅ No deprecated notification usage warnings

## Manual Testing Checklist

### Basic Video Playback

#### Test 1: Initial Video Autoplay
**Steps:**
1. Open the app and navigate to feed
2. Scroll to a tweet with video
3. Observe video starts automatically when ≥50% visible

**Expected:**
- ✅ Video autoplays smoothly
- ✅ Only one video plays at a time
- ✅ No audio from multiple videos

**Verify in logs:**
```
🎬 [SHARED PLAYER] Coordinating playback for video: {videoId}
```

#### Test 2: Video Switching During Scroll (Down)
**Steps:**
1. Start with a video playing (50%+ visible)
2. Scroll down slowly until video is 30% visible
3. Observe when next video starts

**Expected:**
- ✅ Current video stops when <30% visible
- ✅ Next video starts immediately
- ✅ Smooth transition, no glitches
- ✅ No multiple videos playing simultaneously

**Verify in logs:**
```
⏹️ [SHARED PLAYER] Stopping video: {oldVideoId}
🎬 [SHARED PLAYER] Started coordinated playback for: {newVideoId}
```

#### Test 3: Video Switching During Scroll (Up)
**Steps:**
1. Start with a video playing
2. Scroll up slowly until video is 30% visible
3. Observe previous video starts

**Expected:**
- ✅ Previous video (above) starts playing
- ✅ Current video stops cleanly
- ✅ Scroll direction logic works correctly

### Fast Scrolling

#### Test 4: Rapid Scroll Through Multiple Videos
**Steps:**
1. Quickly scroll through 5+ videos
2. Stop scrolling at a video
3. Observe video starts playing

**Expected:**
- ✅ No performance issues during fast scroll
- ✅ Videos don't flicker or start/stop rapidly
- ✅ Correct video plays when scrolling stops
- ✅ No memory accumulation (check Xcode memory graph)

**Verify in logs:**
```
⚠️ [TASK LIMIT] Hit max 5 tasks, cancelling oldest
(Should NOT appear - async tasks cleaned up properly)
```

### Sequential Playback

#### Test 5: Video Finishes, Next Video Starts
**Steps:**
1. Let a short video play to completion
2. Observe next video starts automatically

**Expected:**
- ✅ Next video starts within 50ms
- ✅ Next video is sufficiently visible (33%+)
- ✅ No videos start if none are visible enough

**Verify in logs:**
```
📹 [VIDEO ADVANCE] Current video finished at index X
✅ [VIDEO ADVANCE] Found next video: {videoId}
🎬 [SHARED PLAYER] Started coordinated playback for: {videoId}
```

#### Test 6: Video Finishes at End of Feed
**Steps:**
1. Scroll to last video in feed
2. Let video play to completion

**Expected:**
- ✅ Video finishes cleanly
- ✅ No error logs
- ✅ No attempts to play non-existent next video

**Verify in logs:**
```
⚠️ [VIDEO ADVANCE] No next video (reached end of list) - stopping all
```

### Background/Foreground

#### Test 7: Background and Return (No Scroll)
**Steps:**
1. Start video playing (50%+ visible)
2. Press home button (background app)
3. Wait 5 seconds
4. Return to app (don't scroll)

**Expected:**
- ✅ Same video resumes from where it left off
- ✅ No glitches or duplicate videos playing
- ✅ shouldPreserveStateOnForeground flag worked

**Verify in logs:**
```
(No "RESET STATE" log - state was preserved)
```

#### Test 8: Background, Scroll Away, Return
**Steps:**
1. Start video playing
2. Scroll to different location
3. Press home button
4. Return to app

**Expected:**
- ✅ State resets (doesn't try to resume old video)
- ✅ Current visible video starts playing
- ✅ shouldPreserveStateOnForeground cleared by scroll

**Verify in logs:**
```
// RESET STATE: User scrolled away or no active state
```

### Edge Cases

#### Test 9: Stop All Videos
**Steps:**
1. Have video playing
2. Navigate away from feed (e.g., open profile)
3. Return to feed

**Expected:**
- ✅ All videos stop when leaving feed
- ✅ Videos restart when returning to feed
- ✅ No orphaned video players

**Verify in logs:**
```
⏹️ [SHARED PLAYER] Stopping video: {videoId}
```

#### Test 10: Overlay Coverage
**Steps:**
1. Have video playing
2. Open fullscreen view (overlay covers feed)
3. Close overlay
4. Observe playback resumes

**Expected:**
- ✅ Video stops when overlay opens
- ✅ Video resumes after 150ms when overlay closes
- ✅ No audio bleeding under overlay

**Verify in logs:**
```
(When overlay opens - playback stops)
(When overlay closes - playback resumes after delay)
```

#### Test 11: Multiple Retweets/Quotes of Same Video
**Steps:**
1. Find feed with same video retweeted multiple times
2. Scroll through them
3. Observe each instance plays independently

**Expected:**
- ✅ Each instance treated as separate video
- ✅ Correct instance stops/starts based on scroll
- ✅ No confusion with videoMid matching

### State Management

#### Test 12: SharedVideoPlayerManager State Consistency
**Steps:**
1. Start video playing
2. At various times, pause in debugger
3. Check `SharedVideoPlayerManager.shared.currentVideoMid`

**Expected:**
- ✅ `currentVideoMid` always matches the playing video
- ✅ `currentVideoMid` is nil when no video playing
- ✅ State updates happen before notification posts

**Debugger check:**
```swift
(lldb) po SharedVideoPlayerManager.shared.currentVideoMid
// Should match the visible playing video's mid
```

#### Test 13: Notification Flow
**Steps:**
1. Set breakpoint in `SimpleVideoPlayer` notification handler
2. Play a video
3. Verify notification userInfo

**Expected:**
- ✅ Notifications come from SharedVideoPlayerManager (not directly from coordinator)
- ✅ userInfo contains correct videoId, videoMid, cellTweetId
- ✅ isPrimary flag set correctly

## Automated Testing (Future)

### Unit Tests to Write

```swift
@Test("Phase 2: SharedVideoPlayerManager coordinates primary video")
func testPrimaryVideoCoordination() async throws {
    // Given
    let manager = SharedVideoPlayerManager.shared
    let coordinator = VideoPlaybackCoordinator.shared
    
    // When
    coordinator.playVideo(videoId: "test_123", videoMid: "mid_123", cellTweetId: "cell_123")
    
    // Then
    #expect(manager.currentVideoMid == "mid_123")
    #expect(manager.currentlyPlayingVideoId == "test_123")
    #expect(manager.isPlaying() == true)
}

@Test("Phase 2: Stop current video clears state")
func testStopClearsState() async throws {
    // Given
    let manager = SharedVideoPlayerManager.shared
    manager.playVideo(videoId: "test_123", videoMid: "mid_123", cellTweetId: "cell_123")
    
    // When
    manager.stopCurrentVideo()
    
    // Then
    #expect(manager.currentVideoMid == nil)
    #expect(manager.currentlyPlayingVideoId == nil)
    #expect(manager.isPlaying() == false)
}

@Test("Phase 2: Coordinator uses manager for all primary operations")
func testCoordinatorUsesManager() async throws {
    // Verify coordinator doesn't post direct notifications for primary videos
    // All should go through SharedVideoPlayerManager
    
    // This test would mock NotificationCenter and verify
    // coordinator doesn't post .shouldPlayVideo directly
}
```

## Performance Testing

### Memory Usage

**Test:** Scroll through 50+ videos rapidly

**Monitor:**
```
1. Xcode Memory Graph
   - Check for leaked video players
   - Verify timer cleanup
   - Check async task accumulation

2. Instruments - Allocations
   - Track NotificationCenter overhead
   - Verify SharedVideoPlayerManager not accumulating state
   - Check cache sizes (cellCache, cachedVisibilityRatios)
```

**Expected:**
- ✅ Memory stays under 1GB normal, 2GB max
- ✅ No leaked AVPlayer instances
- ✅ Timers properly invalidated
- ✅ Async tasks properly cleaned up

### CPU Usage

**Test:** Continuous scrolling for 30 seconds

**Monitor:**
```
Instruments - Time Profiler
- Check SharedVideoPlayerManager.playVideo() overhead
- Verify notification dispatch efficiency
- Check for redundant calls
```

**Expected:**
- ✅ <5% CPU during steady scrolling
- ✅ No hot loops or excessive method calls
- ✅ Notification dispatch efficient

## Regression Testing

### Test Against Known Issues

#### Issue: Multiple Videos Playing
**Previous bug:** Direct notifications could cause multiple videos to play

**Test:**
1. Rapidly tap multiple video cells
2. Scroll quickly through videos
3. Verify only one plays

**Expected:**
- ✅ SharedVideoPlayerManager prevents multiple simultaneous plays
- ✅ State management ensures clean transitions

#### Issue: Timer Accumulation
**Previous bug:** Timers not cleaned up, CPU cycles accumulating

**Test:**
1. Background/foreground 10 times
2. Check Instruments for active timers
3. Verify proper cleanup

**Expected:**
- ✅ All timers invalidated on cleanup
- ✅ No orphaned display links
- ✅ No CPU cycles accumulation

#### Issue: Memory Leaks
**Previous bug:** Async tasks not cleaned up

**Test:**
1. Scroll through 100+ videos
2. Check memory graph for leaks
3. Verify task limit enforcement

**Expected:**
- ✅ Max 5 concurrent tasks enforced
- ✅ Completed tasks removed from tracking
- ✅ No unbounded memory growth

## Success Criteria

### Phase 2 Implementation is Successful If:

- ✅ All primary video operations go through SharedVideoPlayerManager
- ✅ No direct `.shouldPlayVideo` or `.shouldStopVideo` posts from coordinator for primary videos
- ✅ State management centralized in SharedVideoPlayerManager
- ✅ All existing video playback functionality works correctly
- ✅ No performance regressions
- ✅ No memory leaks or timer accumulation
- ✅ Code is clearer and easier to debug
- ✅ 83% reduction in direct notification posts achieved

## Common Issues and Solutions

### Issue: Video Doesn't Start
**Symptoms:** Video cell visible but video doesn't autoplay

**Debug:**
```swift
// Check SharedVideoPlayerManager state
print("Current video: \(SharedVideoPlayerManager.shared.currentVideoMid ?? "none")")
print("Is playing: \(SharedVideoPlayerManager.shared.isPlaying())")

// Check coordinator state
print("Primary ID: \(VideoPlaybackCoordinator.shared.primaryVideoId ?? "none")")
print("Phase: \(VideoPlaybackCoordinator.shared.phase)")
```

**Possible causes:**
- Overlay coverage active (`isPlaybackSuppressedByOverlay = true`)
- Video not in visible range (`isInVisibleMediaRange = false`)
- Table view not in hierarchy

### Issue: Multiple Videos Playing
**Symptoms:** Audio from multiple videos simultaneously

**Debug:**
```swift
// Check if SharedVideoPlayerManager is actually managing playback
// Should only have ONE currentVideoMid at any time
print("Current video: \(SharedVideoPlayerManager.shared.currentVideoMid ?? "none")")
```

**Possible causes:**
- Direct notification posts bypassing manager (Phase 2 not fully implemented)
- Race condition in stop/start sequence
- Notification not processed before new video starts

### Issue: Video State Not Preserved on Background
**Symptoms:** Wrong video plays after backgrounding

**Debug:**
```swift
// Check shouldPreserveStateOnForeground flag
print("Should preserve: \(coordinator.shouldPreserveStateOnForeground)")
print("Had active state: \(coordinator.phase != .idle)")
```

**Possible causes:**
- User scrolled before backgrounding (clears flag)
- Primary video scrolled out of view
- Visible videos list changed

## Logging Checklist

### Phase 2 logs to watch for:

#### Successful Playback Flow
```
🎬 [SHARED PLAYER] Coordinating playback for video: {videoId}
🎬 [SHARED PLAYER] Started coordinated playback for: {videoId}
```

#### State Changes
```
⏹️ [SHARED PLAYER] Stopping video: {videoId}
⏸️ [SHARED PLAYER] Pausing video: {videoId}
```

#### Error Conditions (should NOT appear often)
```
⚠️ [TASK LIMIT] Hit max 5 tasks, cancelling oldest
⚠️ [VIDEO ADVANCE] Cannot advance - no current primary video
⚠️ [VIDEO ADVANCE] No next video (reached end of list)
```

## Sign-Off Checklist

Before marking Phase 2 as complete:

- [ ] All manual tests pass
- [ ] No memory leaks detected
- [ ] No timer accumulation
- [ ] Performance metrics meet targets
- [ ] Logging shows correct flow through SharedVideoPlayerManager
- [ ] State management working as expected
- [ ] Background/foreground handling works
- [ ] Sequential playback works
- [ ] Scroll switching works (both directions)
- [ ] Edge cases handled correctly

---

**Testing Date:** January 23, 2026  
**Phase 2 Status:** ✅ Ready for Testing  
**Estimated Testing Time:** 2-3 hours for full manual testing
