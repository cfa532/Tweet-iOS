# VideoPlaybackCoordinator Quick Debug Reference

## 🚨 Common Issues & Solutions

### Issue: Video in Quoted Tweet Plays Too Early

**Symptom:** Video in embedded quoted tweet starts playing before it's visible.

**Root Cause:** Video was added to coordinator's `allVideos[]` list with coordinated context.

**Debug Steps:**
1. Search logs for: `Added quoted tweet main video` vs `Skipping embedded quoted tweet videos`
2. Check if video's `context` is `.quoted` (should be filtered) or `.regular` (wrong!)
3. Verify tweet has both `originalTweetId` AND `attachments` (quoted tweet)

**Fix:** Ensure `buildVideoList()` detects quoted tweets correctly:
```swift
let isQuotedTweet = hasOriginalTweet && hasTweetContent
if isQuotedTweet {
    // Only add main body videos, skip embedded videos
}
```

---

### Issue: Video Plays Muted Despite Unmuted State

**Symptom:** Video starts muted even though global mute button is off.

**Root Cause:** Notification doesn't include `isMuted` parameter.

**Debug Steps:**
1. Search logs for: `Survey play:` or `Sending play command for primary`
2. Check if log shows `muted: false` or `muted: true`
3. If missing, notification wasn't updated with mute state

**Fix:** All play notifications should include:
```swift
"isMuted": MuteState.shared.isMuted
```

**Verify in:**
- `playVideoForSurvey()`
- `endSurveyPhase()`
- `playNextVisibleVideo()`
- Foreground recovery methods

---

### Issue: Video Won't Replay After Scrolling Back

**Symptom:** Video plays first time, but not after scrolling away and back.

**Root Cause:** `videosSentPlayCommands` not cleared when video paused.

**Debug Steps:**
1. Search logs for: `Skipping duplicate play command`
2. Check if video is in `videosSentPlayCommands` after being paused
3. Verify `pauseVideo()` clears the entry

**Fix:** Ensure `pauseVideo()` includes:
```swift
videosSentPlayCommands.remove(videoId)
```

---

### Issue: Multiple Videos Play Simultaneously

**Symptom:** Several videos playing at once instead of one primary.

**Root Cause:** Race condition in `endSurveyPhase()` or embedded videos not filtered.

**Debug Steps:**
1. Check if `phase` transitions atomically at start of `endSurveyPhase()`
2. Search logs for duplicate `Sending play command for primary`
3. Check if embedded videos are in `allVideos[]` (they shouldn't be)

**Fix:** Ensure phase transition is first:
```swift
guard phase == .surveying else { return }
phase = .primaryPlaying  // ✅ Immediate
```

---

### Issue: Retweet Video Doesn't Play

**Symptom:** Pure retweet video never loads or plays.

**Root Cause:** Original tweet not found or videos filtered incorrectly.

**Debug Steps:**
1. Search logs for: `Original tweet not found for retweet`
2. Check if video has `context: .retweet` (should be coordinated)
3. Verify `fetchTweetSync()` returns original tweet

**Fix:** Ensure retweet detection works:
```swift
let isPureRetweet = hasOriginalTweet && !hasTweetContent
if isPureRetweet {
    // Fetch original tweet and add videos with .retweet context
}
```

---

## 🔍 Log Analysis Guide

### Healthy Playback Sequence

```
🎬 [VideoPlaybackCoordinator] Building video list from 10 tweets + 0 pinned
  ✅ Added regular video: v1 (context: regular)
  ✅ Added quoted tweet main video: v2 (context: regular)
  🚫 Skipping embedded quoted tweet videos for tweet: t3 (independent autoplay)
  ✅ Added retweet video: v4 (context: retweet)
🎬 [VideoPlaybackCoordinator] Final coordinated video count: 3

📤 [VideoPlaybackCoordinator] Survey play: v1, muted: false
📤 [VideoPlaybackCoordinator] Survey play: v2, muted: false
📤 [VideoPlaybackCoordinator] Survey play: v4, muted: false

📤 [VideoPlaybackCoordinator] Sending play command for primary video: v2, muted: false
⏸️ [VideoPlaybackCoordinator] Paused video: v1
⏸️ [VideoPlaybackCoordinator] Paused video: v4

▶️ [VideoPlaybackCoordinator] Playing next video: v4, muted: false
```

### Problem: Embedded Video Coordinated (Wrong!)

```
❌ BAD:
🎬 [VideoPlaybackCoordinator] Building video list from 5 tweets + 0 pinned
  ✅ Added regular video: v1 (context: regular)
  ✅ Added regular video: v2 (context: regular)  ← Main body
  ✅ Added regular video: v3 (context: regular)  ← ❌ Should be filtered!
  ✅ Added regular video: v4 (context: regular)
🎬 [VideoPlaybackCoordinator] Final coordinated video count: 4

✅ GOOD:
🎬 [VideoPlaybackCoordinator] Building video list from 5 tweets + 0 pinned
  ✅ Added regular video: v1 (context: regular)
  ✅ Added quoted tweet main video: v2 (context: regular)
  🚫 Skipping embedded quoted tweet videos for tweet: t3 (independent autoplay)
  ✅ Added regular video: v4 (context: regular)
🎬 [VideoPlaybackCoordinator] Final coordinated video count: 3
```

### Problem: Missing Mute State

```
❌ BAD:
📤 [VideoPlaybackCoordinator] Survey play: v1
📤 [VideoPlaybackCoordinator] Sending play command for primary video: v2
(No muted state logged)

✅ GOOD:
📤 [VideoPlaybackCoordinator] Survey play: v1, muted: false
📤 [VideoPlaybackCoordinator] Sending play command for primary video: v2, muted: false
```

### Problem: Duplicate Play Commands

```
❌ BAD:
📤 [VideoPlaybackCoordinator] Sending play command for primary video: v1, muted: false
📤 [VideoPlaybackCoordinator] Sending play command for primary video: v1, muted: false
(Same video, duplicate command)

✅ GOOD:
📤 [VideoPlaybackCoordinator] Sending play command for primary video: v1, muted: false
⚠️ [VideoPlaybackCoordinator] Skipping duplicate play command for primary: v1
(Guard prevents duplicate)
```

---

## 🛠️ Debug Commands

### Check Video Context

```swift
// In buildVideoList(), add temporary logging:
print("🔍 Video: \(attachment.mid), Context: \(videoInfo.context), ShouldCoordinate: \(videoInfo.shouldCoordinate)")
```

### Verify Tweet Type Detection

```swift
// In buildVideoList(), add:
print("🔍 Tweet: \(tweet.mid)")
print("   hasTweetContent: \(hasTweetContent)")
print("   hasOriginalTweet: \(hasOriginalTweet)")
print("   isPureRetweet: \(isPureRetweet)")
print("   isQuotedTweet: \(isQuotedTweet)")
```

### Monitor State Transitions

```swift
// In phase-changing methods, add:
print("🔄 Phase transition: \(phase) -> .primaryPlaying")
```

### Track Play Command Set

```swift
// In playVideoForSurvey(), add:
print("📋 videosSentPlayCommands before: \(videosSentPlayCommands)")
print("📋 videosSentPlayCommands after: \(videosSentPlayCommands)")
```

---

## 📊 State Inspection

### Check Current State (Debugger)

```swift
(lldb) po VideoPlaybackCoordinator.shared.phase
// Should be: idle, surveying, or primaryPlaying

(lldb) po VideoPlaybackCoordinator.shared.currentlyPlayingVideoIds
// Set of currently playing video identifiers

(lldb) po VideoPlaybackCoordinator.shared.primaryVideoId
// Currently selected primary video (if any)

(lldb) po VideoPlaybackCoordinator.shared.allVideos.count
// Total number of coordinated videos

(lldb) po VideoPlaybackCoordinator.shared.allVideos.map { $0.context }
// Array of contexts: [regular, retweet, regular, ...]
// Should NOT contain .quoted or .embedded
```

### Check MuteState

```swift
(lldb) po MuteState.shared.isMuted
// Current global mute state
```

### Verify Video is Coordinated

```swift
(lldb) po VideoPlaybackCoordinator.shared.allVideos.contains(where: { $0.videoMid == "YOUR_VIDEO_MID" })
// Should be true if video should be coordinated
```

---

## ⚡ Quick Fixes

### Force Reset Coordinator

```swift
// In problematic state, call:
VideoPlaybackCoordinator.shared.stopAllVideos()
// Resets to idle, clears all state
```

### Manually Trigger Survey

```swift
// After coordinator is in idle:
VideoPlaybackCoordinator.shared.updateVisibleTweets(currentTweetIds)
// Will start debounce timer and survey phase
```

### Clear Play Command Cache

```swift
// If stuck with "already sent" commands:
// (Add this as a debug method)
func clearPlayCommandCache() {
    videosSentPlayCommands.removeAll()
}
```

---

## 🎯 Validation Checklist

Before declaring fix complete, verify:

- [ ] Regular tweet videos play correctly (coordinated)
- [ ] Pure retweet videos play correctly (coordinated)
- [ ] Quoted tweet main body videos play correctly (coordinated)
- [ ] Quoted tweet embedded videos DON'T get coordinated (independent)
- [ ] Mute state is respected from the start
- [ ] Videos can replay after scrolling off/on screen
- [ ] No duplicate play commands in logs
- [ ] Phase transitions are atomic (no race conditions)
- [ ] No unbounded retry loops (check CPU usage)
- [ ] Video finished events only trigger for coordinated videos

---

## 📞 Where to Look

| Symptom | File to Check | Method to Inspect |
|---------|---------------|-------------------|
| Wrong videos coordinated | VideoPlaybackCoordinator.swift | `buildVideoList()` |
| Muted playback | VideoPlaybackCoordinator.swift | `playVideoForSurvey()`, `endSurveyPhase()` |
| Won't replay | VideoPlaybackCoordinator.swift | `pauseVideo()` |
| Duplicate commands | VideoPlaybackCoordinator.swift | `endSurveyPhase()` |
| Embedded video issues | TweetItemBodyView.swift | Check `isEmbedded` flag |
| Video not receiving notifications | MediaCell.swift | Check `mode` parameter |
| Mute state not applied | SimpleVideoPlayer (not visible) | Notification handler |

---

## 🚀 Performance Tips

1. **Minimize Log Noise:** After debugging, reduce log verbosity to errors only
2. **Cache Inspection:** Use `allVideos.count` instead of iterating in hot paths
3. **Debounce Tuning:** 0.1s works well, but adjust based on scroll performance
4. **Memory Monitoring:** Check if `videosSentPlayCommands` grows unbounded

---

## 📝 Reporting Bugs

When reporting issues, include:
1. Tweet type (regular, retweet, quoted)
2. Video context (what should it be?)
3. Relevant log excerpts (with emoji prefixes)
4. State dump: `phase`, `currentlyPlayingVideoIds`, `allVideos.count`
5. Steps to reproduce

Example bug report:
```
Issue: Quoted tweet embedded video gets coordinated

Tweet type: Quoted tweet
Video context: Should be .quoted (independent), but is .regular (coordinated)

Logs:
✅ Added regular video: v3 (context: regular)  ← Wrong!
Should be:
🚫 Skipping embedded quoted tweet videos for tweet: t3

State:
phase: surveying
allVideos.count: 4 (should be 3)

Steps:
1. Load feed with quoted tweet containing video
2. Scroll to make it visible
3. Video plays immediately (should wait for manual trigger)
```

---

## 🔗 Related Documentation

- `VIDEO_COORDINATOR_FIXES.md` - Detailed change log
- `VIDEO_COORDINATOR_ARCHITECTURE.md` - Visual diagrams and flow charts
- `VideoPlaybackCoordinator.swift` - Implementation with inline comments
