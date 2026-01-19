# TweetListView Performance Fixes

## Summary
Fixed critical performance issues causing the app to slow down as more tweets are browsed.

## Issues Identified and Fixed

### 1. **Notification Observer Memory Leak** ⚠️ CRITICAL
**Problem:** 
- Used `ForEach` with `.onReceive()` inside SwiftUI `body`
- Every view re-render created NEW notification observers
- Observers accumulated without cleanup, causing exponential slowdown
- Each observer processed every notification, multiplying CPU usage

**Symptoms:**
- App gets slower the more you scroll
- CPU usage increases over time
- Memory usage grows

**Solution:**
- Moved notification observers outside `body` to dedicated setup/cleanup methods
- Created `setupNotificationObservers()` called in `.onAppear`
- Created `cleanupNotificationObservers()` called in `.onDisappear`
- Observers are now created once and properly cleaned up

**Impact:** 🔥 HIGH - This was likely the primary cause of slowdown

---

### 2. **Excessive Video Manager Updates**
**Problem:**
- `updateVideoLoadingManager()` called on every tweet merge/update
- No debouncing between rapid updates during scrolling
- Multiple updates triggered in quick succession

**Solution:**
- Added task cancellation and debouncing to `updateVideoLoadingManager()`
- Stores update task in `videoManagerUpdateTask` state
- Cancels pending task before starting new one
- Added configurable delay parameter (default 0.2s for most operations)

**Impact:** 🟡 MEDIUM - Reduces redundant work during rapid scrolling

---

### 3. **Tweet Cleanup Running Too Frequently**
**Problem:**
- `Tweet.cleanupOldInstances()` called on EVERY video manager update
- Expensive operation running constantly during scrolling
- Cleanup checks entire tweet instance dictionary

**Solution:**
- Added throttling with `lastCleanupTime` state
- Only runs cleanup every 10 seconds max
- Cleanup still happens, but at reasonable intervals

**Impact:** 🟡 MEDIUM - Reduces CPU spikes during scrolling

---

### 4. **Auto-Load Overwhelming System**
**Problem:**
- `autoLoadRemainingNewTweets()` loads pages with minimal delay
- Could trigger multiple `updateVideoLoadingManager()` calls rapidly
- Insufficient delay between page requests

**Solution:**
- Increased delay between page loads from 100ms to 200ms
- Added debounced video manager updates (0.2s delay)
- Batches multiple updates instead of processing each immediately

**Impact:** 🟢 LOW - Minor improvement during app startup

---

## Code Changes

### Before:
```swift
// In body - creates new observers on every render!
ForEach(Array(Set(notifications.map { $0.name })), id: \.rawValue) { name in
    EmptyView()
        .onReceive(NotificationCenter.default.publisher(for: name)) { notif in
            // Processing...
        }
}
```

### After:
```swift
// In .onAppear - creates observers once
.onAppear {
    setupNotificationObservers()
}
.onDisappear {
    cleanupNotificationObservers()
}

private func setupNotificationObservers() {
    // Create one observer per unique notification name
    // Store in @State array for cleanup
}
```

---

## Performance Metrics Expected

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Notification observers after 100 scrolls | ~100-500+ | 2-5 | 95%+ reduction |
| Video manager update calls per second | 10-50 | 1-5 | 80%+ reduction |
| Tweet cleanup calls per minute | 60-300 | 6 | 90%+ reduction |
| CPU usage during scrolling | High, increasing | Stable, low | Significant |
| Memory growth rate | Fast | Slow | Significant |

---

## Testing Recommendations

1. **Scroll Test:** Open app, scroll through 100+ tweets rapidly
   - Monitor CPU usage in Xcode Instruments
   - Should remain stable, not increase over time

2. **Memory Test:** Use app for 10+ minutes with heavy scrolling
   - Monitor memory in Debug navigator
   - Should not continuously grow

3. **Notification Test:** Check notification observer count
   - Add logging to `setupNotificationObservers()`
   - Should show 2-5 observers max, not growing

4. **Video Manager Test:** Monitor `updateVideoLoadingManager()` calls
   - Add logging with timestamps
   - Should see debouncing working (grouped calls with delays)

---

## Additional Recommendations

### Consider for Future Optimization:

1. **Implement Virtual Scrolling:**
   - Only keep N tweets in memory at once
   - Unload tweets far from viewport
   - Could reduce memory by 50-80%

2. **Optimize `mergeTweets()` Algorithm:**
   - Current implementation unknown, but likely O(n log n) or worse
   - Consider using Set-based deduplication
   - Cache sorted results

3. **Lazy Load Tweet Media:**
   - Defer loading images/videos until needed
   - Cancel loads for off-screen tweets more aggressively
   - Use lower resolution thumbnails

4. **Profile `TweetTableViewController`:**
   - UIKit table view may have its own performance issues
   - Check cell reuse, height caching
   - Consider using Diffable Data Source

5. **Limit Total Tweet Count:**
   - After 500-1000 tweets, remove oldest from memory
   - Keep IDs only, reload if user scrolls back up
   - Prevents unbounded memory growth

---

## Files Modified
- `TweetListView.swift` - All performance fixes

## Testing Status
- ⏳ Awaiting user testing
- Need to verify improvements in production usage
- Monitor crash reports for memory issues

---

## Notes
- These fixes address systemic performance issues, not just symptoms
- Main culprit was notification observer accumulation
- All fixes are backward compatible
- No API changes required
