# Retweet & Quoted Tweet Video Analysis

## Critical Discovery: Timing Issue with Pure Retweets

### The Problem

**VideoPlaybackCoordinator.buildVideoList()** has a **RACE CONDITION** with pure retweets:

```swift
// Line 180-204: Pure Retweet Handling
if isPureRetweet {
    if let originalTweetId = tweet.originalTweetId,
       let originalTweet = Tweet.getInstance(for: originalTweetId),  // ← CAN RETURN NIL!
       let originalAttachments = originalTweet.attachments {
        
        // Add videos...
    } else {
        print("🟢 [BUILD VIDEO LIST] Skipping pure retweet \(tweet.mid) - original tweet not cached yet")
        // ← VIDEO IS LOST!
    }
}
```

### When This Fails

**Sequence of events**:
1. Retweet loads from cache/server (has `originalTweetId`, no own `attachments`)
2. TweetTableViewController calls `buildVideoList(from: tweets)`
3. `buildVideoList` tries `Tweet.getInstance(for: originalTweetId)`
4. **Original tweet not in singleton cache yet** → returns `nil`
5. Video is skipped with "Skipping pure retweet" log
6. Video never added to coordinator → never plays

### Evidence from User Logs

```
🟢 [BUILD VIDEO LIST] Skipping pure retweet 6S3Sys1JJMXdgci5oxK8Q8ENIcb - original tweet not cached yet
🟢 [BUILD VIDEO LIST] Skipping pure retweet OQAKZH-lIx7eDuU33wFSn1Okopv - original tweet not cached yet
🟢 [BUILD VIDEO LIST] Skipping pure retweet KXfQjSFv5pWbAyjRWMU4Rxr44M3 - original tweet not cached yet
🟢 [BUILD VIDEO LIST] Skipping pure retweet KZQY5_88UJMRYLRwgQ3H2hFM58H - original tweet not cached yet
```

**All 4 pure retweets in initial feed failed** because original tweets weren't in singleton cache when `buildVideoList` was called!

---

## Why Original Tweets Might Not Be in Singleton

### The Tweet Singleton Pattern

`Tweet.getInstance(for: mid)` returns a tweet **ONLY IF** it's already been instantiated and stored in the singleton registry.

**When are tweets added to singleton?**
1. When `Tweet.getInstance(mid:, authorId:, ...)` is called to create/update a tweet
2. When loading from Core Data via `Tweet.from(cdTweet:)`
3. When fetching from server

**When are they NOT in singleton?**
- Original tweet hasn't been loaded yet
- Original tweet is in Core Data but not loaded into memory
- Original tweet is still being fetched from network

### The Race Condition

```
Time 0ms:  Retweets load from cache
Time 10ms: buildVideoList() called → original tweets not in singleton → SKIP
Time 50ms: Original tweets load from cache/network → NOW in singleton
Time 60ms: TOO LATE! buildVideoList already ran and skipped the videos
```

---

## Quoted Tweet Handling (Different Issue)

### Current Behavior

```swift
// Line 205-227: Regular Tweet or Quoted Tweet
else {
    // REGULAR TWEET or QUOTED TWEET: Process the tweet's own attachments
    // NOTE: For quoted tweets, we DON'T process the embedded tweet's videos
    // because they use independent autoplay logic (not coordinated)
    if let attachments = tweet.attachments {
        // Only process outer tweet's videos
    }
}
```

**Quoted tweet videos are INTENTIONALLY EXCLUDED** from coordination!

### Why?

Comment says: "they use independent autoplay logic (not coordinated)"

**This means**:
- Quoted tweet's embedded video autoplays independently
- NOT part of sequential playback
- Has its own lifecycle

### User's Previous Feedback

From conversation summary:
> "the quoted video played independently and restarted after the previous video finished. It should be part of the sequence"

**User wants quoted tweet videos to be coordinated**, but they're explicitly excluded!

---

## Two Separate Issues

### Issue A: Pure Retweet Videos Missing (Race Condition)
**Symptom**: "Skipping pure retweet - original tweet not cached yet"
**Cause**: `Tweet.getInstance()` returns `nil` when `buildVideoList` runs
**Solution**: Ensure original tweets are loaded before `buildVideoList`, OR retry mechanism

### Issue B: Quoted Tweet Videos Not Coordinated (By Design)
**Symptom**: Embedded videos autoplay independently
**Cause**: Explicitly excluded from `buildVideoList` (lines 206-208)
**Solution**: Add quoted tweet videos to coordination (requires design decision)

---

## Call Sequence Analysis

### When buildVideoList is Called

From TweetTableViewController:
- Line 210: After pinned tweets update
- Line 245: After initial load (0 → N tweets)
- Line 256: When tweet IDs haven't changed
- Line 276: After tweets prepended
- Line 292: After tweets appended
- Line 301: After single tweet removed
- Line 308: After complex change

**All calls happen IMMEDIATELY after tweets update**, before original tweets are guaranteed to be in singleton cache!

### When updateVideoLoadingManager is Called

From TweetListView (9+ places):
- After cache load
- After server load
- After refresh
- After load more
- After pagination
- etc.

**These are SEPARATE** - `updateVideoLoadingManager` updates VideoLoadingManager (loading/preloading), NOT VideoPlaybackCoordinator (playback).

---

## Root Cause

The coordinator system has **TWO INDEPENDENT MANAGERS**:

```
VideoPlaybackCoordinator (Playback Control)
  ├─ buildVideoList() ← Called by TweetTableViewController
  └─ updateVisibleTweets() ← Called on scroll

VideoLoadingManager (Asset Loading)
  ├─ updateTweetList() ← Called by TweetListView (9+ places)
  └─ updateVisibleTweetIndex() ← Called on .onAppear
```

**Problem**: `buildVideoList()` is called before original tweets are loaded into singletons.

**Why it matters**: Pure retweet videos are LOST if original tweet not in singleton cache.

---

## Proposed Solutions

### Solution 1: Use TweetCacheManager.fetchTweetSync()

We just added this method! Use it instead of `Tweet.getInstance()`:

```swift
if isPureRetweet {
    if let originalTweetId = tweet.originalTweetId,
       let originalTweet = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId),  // ← NEW
       let originalAttachments = originalTweet.attachments {
        
        // Add videos...
    } else {
        print("🟢 [BUILD VIDEO LIST] Skipping pure retweet - original not in cache")
    }
}
```

**Benefits**:
- Synchronously checks Core Data if not in singleton
- Much higher success rate
- No timing changes needed

**Risks**:
- `performAndWait` during `buildVideoList` (but it's already called during table updates)
- Slight performance impact (but one-time per feed update)

---

### Solution 2: Rebuild Video List After Original Tweets Load

Track which retweets were skipped, rebuild when original tweets load:

```swift
private var skippedRetweets: Set<String> = []

func buildVideoList(...) {
    // ... existing code ...
    
    if isPureRetweet {
        if let originalTweet = ... {
            // Success
        } else {
            skippedRetweets.insert(tweet.mid)  // ← Track it
        }
    }
}

// Call this when original tweets load
func retrySkippedRetweets() {
    if !skippedRetweets.isEmpty {
        buildVideoList(from: currentTweets, pinnedTweets: currentPinnedTweets)
    }
}
```

**Benefits**:
- Handles async loading properly
- No sync Core Data access

**Risks**:
- More complex
- Need to know when original tweets load
- Multiple rebuilds

---

### Solution 3: Coordinate Quoted Tweet Videos

Add quoted tweet embedded videos to coordinator:

```swift
else {
    // Process outer tweet's own attachments
    if let attachments = tweet.attachments {
        // ... add videos ...
    }
    
    // NEW: Also process embedded tweet's videos for quoted tweets
    if let originalTweetId = tweet.originalTweetId,
       let originalTweet = TweetCacheManager.shared.fetchTweetSync(mid: originalTweetId),
       let originalAttachments = originalTweet.attachments {
        
        for (index, attachment) in originalAttachments.enumerated() {
            if attachment.type == .video || attachment.type == .hls_video {
                let videoInfo = VideoPlaybackInfo(
                    tweetId: tweet.mid,  // Use quoted tweet's ID for positioning
                    videoMid: attachment.mid,
                    index: index + 1000  // Offset to distinguish from outer videos
                )
                videos.append(videoInfo)
            }
        }
    }
}
```

**Benefits**:
- Quoted tweet videos become part of sequential playback
- Matches user expectation

**Risks**:
- **HIGH RISK** - Changes fundamental behavior
- Might conflict with existing independent autoplay
- Need to handle embedded video lifecycle carefully
- Previous attempt at this was reverted!

---

## Recommendation

### Priority 1: Fix Pure Retweet Race Condition
**Use Solution 1** (`fetchTweetSync`):
- Low risk
- Uses newly added sync cache access
- Fixes the "Skipping pure retweet" logs
- No behavioral changes

### Priority 2: Quoted Tweet Videos (User Decision)
**Ask user**: Do you want quoted tweet embedded videos to be part of sequential playback?

If yes:
- Use Solution 3
- But implement carefully with extensive testing
- Previous attempts failed, so approach with caution

---

## About updateVideoLoadingManager Calls

**Verdict**: The 9 calls are **NOT related** to retweet/quoted tweet video issues.

- They update VideoLoadingManager (asset loading), not VideoPlaybackCoordinator (playback)
- The race condition is in `buildVideoList`, not `updateTweetList`
- Optimizing these calls won't fix the retweet video issue

**Can we still optimize them?** Yes, with simple deduplication (see VIDEO_COORDINATOR_ANALYSIS.md).

**Should we?** Low priority - focus on the actual bug first.
