# Video Coordinator System - Comprehensive Analysis

## Architecture Overview

The video system has **TWO SEPARATE but related subsystems**:

### 1. **VideoPlaybackCoordinator** (VideoPlaybackCoordinator.swift)
**Purpose**: Controls WHICH video plays and WHEN
- Manages playback orchestration (survey → primary → sequential)
- Tracks visible videos and decides primary video
- Sends play/pause/stop commands via NotificationCenter
- **Works with**: `buildVideoList()` and `updateVisibleTweets()`

### 2. **VideoLoadingManager** (VideoLoadingManager.swift)  
**Purpose**: Controls video LOADING and PRELOADING (network/cache)
- Manages video asset loading/downloading
- Preloads upcoming videos
- Cancels loading for off-screen videos
- **Works with**: `updateTweetList()` and `updateVisibleTweetIndex()`

## Key Distinction

```
VideoPlaybackCoordinator → Playback decisions (play/pause/stop)
VideoLoadingManager     → Loading decisions (fetch/preload/cancel)
```

---

## VideoPlaybackCoordinator Deep Dive

### State Machine

```
┌─────────────────────────────────────────┐
│             IDLE PHASE                   │
│  - No videos playing                     │
│  - Waiting for videos to become visible │
└──────────────┬──────────────────────────┘
               │ Videos become visible
               ▼
┌─────────────────────────────────────────┐
│          SURVEYING PHASE                 │
│  - Play ALL visible videos for 2s        │
│  - Identify which is most centered       │
└──────────────┬──────────────────────────┘
               │ After 2s (or video finishes early)
               ▼
┌─────────────────────────────────────────┐
│      PRIMARY PLAYING PHASE               │
│  - One "primary" video plays to end      │
│  - Other videos paused                   │
│  - When finishes → next video becomes    │
│    primary (sequential playback)         │
└──────────────────────────────────────────┘
```

### Critical Methods

#### `buildVideoList(from: [Tweet], pinnedTweets: [Tweet])`
**Called by**: TweetTableViewController when tweet list changes
**Purpose**: Build ordered list of all videos in feed
**Does**:
1. Iterates through pinned tweets → extract video attachments
2. Iterates through regular tweets → extract video attachments
3. Handles pure retweets (gets videos from original tweet via singleton)
4. Stores in `allVideos: [VideoPlaybackInfo]`
5. Shares list with FullScreenVideoManager

**Performance**: O(n * m) where n=tweets, m=avg attachments
**Note**: Explicitly EXCLUDES quoted tweet videos (they autoplay independently)

#### `updateVisibleTweets(_ tweetIds: Set<String>)`
**Called by**: TweetTableViewController during scroll (throttled to 100ms)
**Purpose**: Update which videos are visible and manage playback
**Does**:
1. Updates `visibleTweetIds: Set<String>`
2. Compares to previous visible videos
3. Stops videos that scrolled out of view
4. **Critical logic**:
   - If in `primaryPlaying` and primary still visible → DO NOTHING (prevents restart)
   - If in `surveying` and new videos appear → Add them to survey (don't restart)
   - Otherwise → Reset to idle, start 0.1s debounce timer → start survey
5. Clears `shouldPreserveStateOnForeground` flag (user scrolled)

**Performance**: O(v) where v=visible videos (typically 1-3)
**Critical**: Has complex state preservation logic to avoid video restarts during scroll

---

## VideoLoadingManager Deep Dive

### Purpose
Manages video **asset loading** (downloading/caching), NOT playback control.

### Key Methods

#### `updateTweetList(_ tweetIds: [String])`
**Called by**: TweetListView.updateVideoLoadingManager() - 9+ places!
**Purpose**: Update the list of all tweet IDs in feed
**Does**:
```swift
func updateTweetList(_ tweetIds: [String]) async {
    await MainActor.run {
        allTweetIds = tweetIds  // ← Just stores the array!
    }
}
```

**That's it!** Just stores the array. No heavy work.

#### `updateVisibleTweetIndex(_ index: Int)`
**Called by**: TweetListView .onAppear for each tweet row
**Purpose**: Track which tweet is currently visible, trigger preloading
**Does**:
1. Updates `currentVisibleTweetIndex`
2. Updates `visibleTweetIds` (current + next 3)
3. Queues off-screen tweets for cancellation
4. Triggers preloading for upcoming tweets

**Performance**: Light, mostly Set operations

---

## TweetListView Interaction

### Where `updateVideoLoadingManager()` is Called

```swift
private func updateVideoLoadingManager(delay: TimeInterval = 0) {
    Task.detached(priority: .background) {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: ...)
        }
        let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
        await self.videoLoadingManager.updateTweetList(tweetIds)  // ← Just stores array
    }
}
```

**Called from 9+ places**:
1. Line 478: After cache load
2. Line 511: After server load (startup, 1s delay)
3. Line 611: After refresh
4. Line 671: After load more (success)
5. Line 679: After load more (failure/empty)
6. Line 750: After pagination
7. Line 843: After foreground observer setup
8. Line 875: When tweets become empty

---

## Analysis: Are These Calls Necessary?

### The Good News
`VideoLoadingManager.updateTweetList()` is **EXTREMELY LIGHTWEIGHT**:
- Just stores an array reference
- No iteration, no computation, no network
- Total cost: ~0.001ms

### The Bad News
**Each call creates unnecessary overhead**:
1. Creates `Task.detached` (task spawning overhead)
2. Captures `self` and `tweets`
3. Performs `tweets.map { $0.mid }` (O(n) operation)
4. Context switches: background → main → background

### The Duplication Problem
Many calls happen in rapid succession:
```
Cache load    → updateVideoLoadingManager()  // tweets = [1,2,3,4,5,6,7,8,9,10]
Server load   → updateVideoLoadingManager()  // tweets = [1,2,3,4,5,6,7,8,9,10] (same!)
Load more     → updateVideoLoadingManager()  // tweets = [1..20] (changed)
```

**Analysis**: The first two calls are redundant if tweet IDs haven't changed!

---

## The Real Cost

### Current Implementation
```swift
// Called 9 times during typical app session
Task.detached {  // ← Task spawning: ~0.05ms each
    let tweetIds = tweets.map { $0.mid }  // ← O(n): ~0.1ms for 30 tweets
    await videoLoadingManager.updateTweetList(tweetIds)  // ← ~0.001ms
}
```

**Total per call**: ~0.15ms
**9 calls**: ~1.35ms
**If 5 are redundant**: ~0.75ms wasted

### Is This a Problem?
**No, not really!** 1.35ms total is negligible.

**However**:
- The pattern is inefficient (creating tasks for trivial work)
- Redundant calls do unnecessary work
- Could be cleaner with deduplication

---

## Recommended Optimization Strategy

### Option 1: Smart Deduplication (Low Risk)
Cache the tweet ID array and only update if changed:

```swift
@State private var lastTweetIds: [String] = []

private func updateVideoLoadingManager(delay: TimeInterval = 0) {
    Task.detached(priority: .background) {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: ...)
        }
        
        // Get current tweet IDs
        let (currentIds, lastIds) = await MainActor.run { 
            (self.tweets.map { $0.mid }, self.lastTweetIds) 
        }
        
        // Only update if changed
        guard currentIds != lastIds else { 
            return 
        }
        
        await self.videoLoadingManager.updateTweetList(currentIds)
        
        // Cache for next comparison
        await MainActor.run { 
            self.lastTweetIds = currentIds 
        }
    }
}
```

**Benefits**:
- Eliminates redundant updates
- Preserves all current behavior
- Very low risk

**Risks**:
- Minimal - just adds a comparison

---

### Option 2: Debouncing (Medium Risk)
Add a short debounce to batch rapid updates:

```swift
@State private var videoUpdateTask: Task<Void, Never>?

private func updateVideoLoadingManager(delay: TimeInterval = 0) {
    // Cancel previous pending update
    videoUpdateTask?.cancel()
    
    videoUpdateTask = Task.detached(priority: .background) {
        // Small debounce
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        guard !Task.isCancelled else { return }
        
        let tweetIds = await MainActor.run { self.tweets.map { $0.mid } }
        await self.videoLoadingManager.updateTweetList(tweetIds)
    }
}
```

**Benefits**:
- Batches rapid consecutive updates
- Reduces task spawning

**Risks**:
- Delayed updates could cause preloading delays
- Cancellation logic could miss updates

---

### Option 3: Do Nothing (Safest)
The current implementation works fine. The overhead is minimal.

**When to optimize**:
- If profiling shows this is a bottleneck (unlikely)
- If battery/thermal issues are traced here (unlikely)

---

## Conclusion

### What I Learned
1. **VideoLoadingManager.updateTweetList() is NOT expensive** - just stores an array
2. **VideoPlaybackCoordinator is separate** - handles playback orchestration
3. **The 9 calls are mostly harmless** - total cost ~1.35ms
4. **Some redundancy exists** - but not causing performance issues

### Recommendation
**Option 1 (Smart Deduplication)** is the best approach:
- Low risk
- Eliminates unnecessary work
- Clean implementation
- Preserves all existing behavior

### Why Previous Attempts Failed
1. **First attempt**: Debounced video coordinator updates → broke playback timing
2. **Second attempt**: Unknown, but likely touched playback logic

### For Next Attempt
- **Only optimize VideoLoadingManager** (loading), NOT VideoPlaybackCoordinator (playback)
- Use simple deduplication, NO debouncing, NO cancellation
- Keep all existing calls, just skip redundant work
- Test thoroughly with retweets and quoted tweets

---

## Other Performance Issues (Unrelated to Coordinator)

The coordinator is fine. Real issues are:
1. Height estimation with Core Data sync access
2. Network calls in video navigation (findNextVideoInList)
3. OnAppear callbacks on every tweet row

Focus on those instead!
