# Performance Analysis - Remaining Issues

## ✅ Fixed Issues
1. **Consolidated MainActor calls** - Reduced from 3 to 1 in video navigation
2. **Optimized notification handler** - Single O(n) search instead of multiple
3. **Improved mergeTweetsInternal** - Dual-strategy (bulk vs incremental) merging
4. **Fixed retweet height estimation** - Proper calculation using cached tweet data

---

## 🔍 Remaining Performance Issues

### 🔴 HIGH PRIORITY

#### 1. Excessive Video Coordinator Updates
**Location**: `TweetListView.swift` - Lines 478, 511, 611, 671, 679, 750, 843, 875

**Problem**: 
- `updateVideoLoadingManager()` called 9+ times in various loading scenarios
- Each call creates a `Task.detached`, maps entire tweets array (`tweets.map { $0.mid }`), and updates coordinator
- No deduplication or batching

**Impact**: 
- Multiple concurrent background tasks during tweet loading
- Repeated O(n) array mapping operations
- Unnecessary coordinator updates when tweet list hasn't changed

**Example**:
```swift
// Called in many places:
updateVideoLoadingManager()  // → Task.detached { tweets.map { $0.mid } }
```

**Proposed Fix**:
- Debounce/throttle coordinator updates
- Cache tweet ID array and only update if changed
- Batch multiple rapid updates into single update

---

### 🟡 MEDIUM PRIORITY

#### 2. Network Calls in Video Navigation Path
**Location**: `TweetListView.swift` - Lines 111, 146 (`findNextVideoInList`)

**Problem**:
- Synchronous network calls via `hproseInstance.getTweet()` during video navigation
- Blocks video navigation if original tweet not in cache

**Impact**:
- Delayed "next video" playback for retweets
- Potential UI freezes during navigation

**Current Code**:
```swift
if let original = try? await hproseInstance.getTweet(tweetId: originalTweetId, authorId: originalAuthorId) {
    mediaTweet = original
}
```

**Proposed Fix**:
- Check cache first before network call
- Skip videos with uncached retweets and move to next
- Pre-fetch original tweets when displaying retweets

---

#### 3. Height Estimation Performance
**Location**: `TweetTableViewController.swift` - Lines 698-743 (`estimateHeight`)

**Problem**:
- `fetchTweetSync()` performs synchronous Core Data access for uncached retweets
- `NSString.boundingRect()` calculations on every height estimate miss
- Called frequently during scrolling for new rows

**Impact**:
- Scroll stuttering when encountering many uncached retweets
- Core Data performAndWait blocks during scroll

**Current State**:
- Has height cache (good!)
- But cache misses trigger expensive operations

**Proposed Fix**:
- Pre-calculate heights in background when tweets load
- Expand height cache to include retweet estimates
- Use simpler fallback estimates during fast scrolling

---

#### 4. OnAppear Callback Overhead
**Location**: `TweetListView.swift` - Lines 1012-1014

**Problem**:
- Calls `videoLoadingManager.updateVisibleTweetIndex(index)` for every tweet that appears
- Fires many times during scroll

**Current Code**:
```swift
.onAppear {
    // Update VideoLoadingManager when tweet becomes visible
    videoLoadingManager.updateVisibleTweetIndex(index)
}
```

**Impact**:
- Potential callback overhead during fast scrolling
- May trigger unnecessary coordinator updates

**Proposed Fix**:
- Throttle/debounce visible index updates
- Use table view's existing visibility tracking instead
- Batch updates

---

### 🟢 LOW PRIORITY

#### 5. Repeated Array Operations
**Location**: `TweetListView.swift` - Lines 73, 970, 981

**Problem**:
- `tweets.map { $0.mid }` - Maps entire array on every coordinator update
- `tweets.compactMap({ $0 })` - Used for empty checks

**Impact**:
- Minor: O(n) operations, but relatively fast
- Could be cached

**Proposed Fix**:
- Cache tweet ID array
- Replace `compactMap` empty checks with `.isEmpty`

---

#### 6. BuildVideoList Complexity
**Location**: `VideoPlaybackCoordinator.swift` - Lines 146-235

**Problem**:
- Iterates all tweets + all attachments
- Singleton lookups for retweets
- Called on every tweet list update

**Current Complexity**: O(n * m) where n=tweets, m=avg attachments

**Impact**:
- Minor: Necessary work, reasonable complexity
- But could be optimized

**Proposed Fix**:
- Cache video list and only rebuild on actual changes
- Skip iteration if tweet IDs haven't changed

---

## 📊 Priority Ranking

1. **🔴 Issue #1** - Excessive Video Coordinator Updates (biggest impact)
2. **🟡 Issue #3** - Height Estimation Performance (scroll stuttering)
3. **🟡 Issue #2** - Network Calls in Navigation (UX impact)
4. **🟡 Issue #4** - OnAppear Callback Overhead
5. **🟢 Issue #5** - Repeated Array Operations
6. **🟢 Issue #6** - BuildVideoList Complexity

---

## 🎯 Recommended Next Steps

**Quick Wins:**
- Fix #1: Debounce/deduplicate video coordinator updates
- Fix #5: Cache tweet ID array

**Medium Effort:**
- Fix #3: Pre-calculate heights in background
- Fix #2: Check cache before network calls

**Future Optimization:**
- Fix #4: Batch visible index updates
- Fix #6: Cache video list with change detection
