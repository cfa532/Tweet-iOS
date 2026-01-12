# VideoPlaybackCoordinator - SIMPLE Version

## Philosophy

**Old approach:** Complex state machine with survey phase, primary selection, sequential playback
**New approach:** Play topmost fully visible video. When it finishes, play next. Done!

---

## How It Works (4 Simple Rules)

### Rule 1: Find Topmost Fully Visible Video
```
┌──────────────────┐
│  Viewport        │
│                  │
│  ┌────────────┐  │ ← Tweet 1 (partially visible) - SKIP
│  └────────────┘  │
│                  │
│  ┌────────────┐  │ ← Tweet 2 (FULLY visible) - PLAY THIS! ✅
│  │  [Video]   │  │
│  └────────────┘  │
│                  │
│  ┌────────────┐  │ ← Tweet 3 (FULLY visible) - Later
│  └────────────┘  │
└──────────────────┘
```

### Rule 2: Stop All Other Videos
```
Only ONE video plays at a time.
When starting video A, stop videos B, C, D.
```

### Rule 3: When Video Finishes, Play Next
```
Video 2 finishes → Play Video 3
Video 3 finishes → Play Video 4
No more videos → Stop
```

### Rule 4: On Scroll, Re-evaluate
```
User scrolls → Wait 0.3s → Find new topmost → Play it
```

---

## What Videos Are Coordinated?

### ✅ COORDINATED (by this coordinator)
- Regular tweet videos
- Pure retweet videos
- Quoted tweet main body videos

### 🚫 NOT COORDINATED (independent autoplay)
- Quoted tweet embedded videos
- Detail view embedded videos

---

## Code Walkthrough

### 1. Build Video List
```swift
func buildVideoList(from tweets: [Tweet], pinnedTweets: [Tweet] = [])
```
- Scans all tweets
- Extracts videos
- Filters to only coordinated videos
- Stores in `allVideos[]`

### 2. Track Visibility
```swift
func updateVisibleTweets(_ tweetIds: Set<String>)
```
- Called during scroll
- Updates `visibleTweetIds`
- Triggers debounced check (0.3s)

### 3. Find & Play Topmost
```swift
private func checkAndPlayTopmost()
```
- Finds topmost fully visible video
- Plays it
- Stops all others

### 4. Handle Finish
```swift
@objc private func handleVideoFinished(_ notification: Notification)
```
- Video sends finish notification
- Coordinator plays next visible video

---

## State

| Variable | Purpose |
|----------|---------|
| `currentlyPlayingVideoId` | Which video is playing (only one!) |
| `allVideos` | All coordinated videos in feed |
| `visibleTweetIds` | Which tweets are visible |
| `visibleVideos` | Computed: videos in visible tweets |

---

## Comparison: Old vs New

### Old Approach (Complex)
```
1. Survey Phase (2s)
   ├─ Play ALL visible videos
   ├─ Wait 2 seconds
   └─ Evaluate which is "primary"

2. Primary Selection
   ├─ Complex viewport calculations
   ├─ Visibility ratios
   └─ Pause non-primary videos

3. Sequential Playback
   └─ When primary finishes, play next

Total: ~900 lines of code
State machine: 3 phases (idle, surveying, primaryPlaying)
Timers: 3 (survey, scroll stop, debounce)
```

### New Approach (Simple)
```
1. Find topmost fully visible video
2. Play it (stop others)
3. When it finishes, play next

Total: ~350 lines of code
State: 1 variable (currentlyPlayingVideoId)
Timers: 1 (debounce)
```

---

## Benefits

### User Experience
- ✅ **Instant playback** - No 2s survey delay
- ✅ **Predictable** - Always plays topmost visible video
- ✅ **Battery efficient** - Only one video at a time
- ✅ **Scroll friendly** - 0.3s debounce feels natural

### Code Quality
- ✅ **Simple** - 60% less code
- ✅ **Maintainable** - Easy to understand
- ✅ **Debuggable** - Clear logic flow
- ✅ **Testable** - Straightforward behavior

---

## Edge Cases Handled

### No Fully Visible Video
If no video is 100% visible, pick the one with highest visibility ratio.

### Table View Not Available
Fallback to first visible video.

### Video Scrolls Off Screen
Debounce timer finds new topmost video.

### Background/Foreground
Stops all on background, resumes topmost on foreground.

### Infrastructure Restart
Stops all when not ready, resumes when ready.

---

## Testing

### Manual Test
1. Open feed with videos
2. **Expected:** Topmost fully visible video plays
3. Scroll down
4. **Expected:** After 0.3s, new topmost video plays (old stops)
5. Let video finish
6. **Expected:** Next video plays automatically
7. Scroll to quoted tweet
8. **Expected:** Main body video plays (if coordinated)
9. **Expected:** Embedded video doesn't auto-play (independent)

### Debug Logging
```
🎬 [VideoCoordinator] Built list: 5 coordinated videos
▶️ [VideoCoordinator] Playing: video_123
✅ [VideoCoordinator] Video finished, playing next
▶️ [VideoCoordinator] Playing: video_456
```

---

## Migration from Old Version

### Breaking Changes
None! Public API is the same:
- `buildVideoList()`
- `updateVisibleTweets()`
- `stopAllVideos()`
- `setTableView()`

### Behavioral Changes
- No survey phase (instant playback)
- Only one video at a time (not multiple during survey)
- 0.3s debounce instead of 0.1s

---

## FAQ

**Q: Why 0.3s debounce?**
A: Feels natural during scroll. Not too fast (jittery), not too slow (laggy).

**Q: Why "fully visible" instead of "most visible"?**
A: Better UX - user can see entire video before it plays. Falls back to "most visible" if needed.

**Q: What if user scrolls very fast?**
A: Debounce cancels previous timer. Only plays video when scroll settles.

**Q: Can I change debounce duration?**
A: Yes, adjust the `0.3` value in `updateVisibleTweets()`.

**Q: Why stop all other videos?**
A: Battery life, bandwidth, CPU efficiency, better UX (no confusion).

---

## Performance

### Memory
- **Old:** 3 timers, complex state tracking
- **New:** 1 timer, single state variable

### CPU
- **Old:** Multiple videos decoding during survey
- **New:** Single video decoding

### Network
- **Old:** Multiple video streams during survey
- **New:** Single video stream

---

## Future Enhancements

If needed, we can add:
1. **Preloading** - Load next video in background
2. **Quality adaptation** - Based on network speed
3. **Smart pausing** - Pause when scrolling fast
4. **Analytics** - Track completion rates

But for now, **simple is better**!

---

## Summary

**Before:** Complex state machine with survey phase
**After:** Play topmost fully visible video

**Result:** 
- 60% less code ✅
- Instant playback ✅
- Predictable behavior ✅
- Easy to maintain ✅

---

**"Simplicity is the ultimate sophistication." - Leonardo da Vinci**
