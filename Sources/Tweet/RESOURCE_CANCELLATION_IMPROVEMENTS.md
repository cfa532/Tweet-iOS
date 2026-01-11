# Resource Cancellation Improvements for Fast Scrolling

## Problem
During fast browsing/scrolling, many videos and images were being downloaded but became "hanged" - holding resources that consume both CPU cycles and memory. These resources were not being cancelled promptly once out of sight, and retry attempts continued even for invisible content.

## Root Causes Identified

1. **Delayed Cancellation**: Background cancellation timer ran every 0.5s, too slow for fast scrolling
2. **Incomplete Buffering Cancellation**: CachingPlayerItem continued buffering even after loading tasks were cancelled
3. **Active Players Not Paused**: Players remained active (rate > 0) consuming CPU cycles
4. **Retry Tasks Not Cancelled**: Scheduled retry tasks continued even when content scrolled out of view
5. **Weak onDisappear Handling**: MediaGridView didn't aggressively cancel resources when disappearing

## Changes Made

### 1. Immediate Cancellation in VideoLoadingManager
**File**: `VideoLoadingManager.swift`

Added `cancelOutOfSightTweetsImmediately()` method that:
- Cancels videos more than 2 positions away from current (buffer = 1)
- Runs synchronously during scroll events (no 0.5s delay)
- Directly calls `SharedAssetCache.shared.cancelLoadingForOutOfSightTweet()`
- Posts notifications for MediaGridView to handle

**Impact**: Videos are cancelled instantly when they're >2 positions away, not queued for later.

### 2. Aggressive Buffering Cancellation in SharedAssetCache
**File**: `SharedAssetCache.swift`

Enhanced `cancelLoadingForOutOfSightTweet()` to:
- Cancel all scheduled retry tasks (`scheduledVideoRetries`)
- Call `cachingPlayerItem.cancelPendingSeeks()` to stop ResourceLoaderDelegate downloads
- Pause players and set rate to 0.0 to stop CPU consumption
- Set `preferredForwardBufferDuration = 0.0` to stop aggressive buffering
- Set `canUseNetworkResourcesForLiveStreamingWhilePaused = false`

**Impact**: Videos immediately stop downloading, buffering, and consuming CPU cycles.

### 3. Enhanced Navigation Cleanup
**File**: `SharedAssetCache.swift`

Modified `cleanupForNavigation()` to:
- Cancel all scheduled retry tasks when navigating away
- Prevent wasteful retries after user has moved to different screen

**Impact**: No wasted retry attempts after navigation.

### 4. Aggressive MediaGridView onDisappear
**File**: `MediaGridView.swift`

Enhanced `onDisappear` to:
- Immediately cancel image loading via `GlobalImageLoadManager.cancelLoad()`
- Immediately cancel video loading via `SharedAssetCache.shared.cancelLoading()`
- Process all attachments in the grid

**Impact**: All resources are cancelled as soon as the grid scrolls off screen.

## Performance Benefits

### Before
- Videos continued buffering after scrolling out of view
- Retry tasks ran for invisible content
- Players consumed CPU cycles even when paused
- 0.5s delay before cancellation processing
- Memory accumulated from active downloads

### After
- **Instant cancellation** when content >2 positions away
- **Zero retry attempts** for out-of-sight content
- **CPU cycles freed** by pausing players (rate = 0.0)
- **Network bandwidth saved** by stopping buffering
- **Memory pressure reduced** by stopping downloads immediately

## Testing Recommendations

1. **Fast Scrolling Test**: Rapidly scroll through 50+ tweets with videos
   - Monitor: Network activity should drop immediately when scrolling past
   - Monitor: CPU usage should stay low during fast scrolling
   - Monitor: Memory should not spike from accumulated downloads

2. **Navigation Test**: Open feed → scroll → navigate away → return
   - Monitor: No retry tasks running in background after navigation
   - Monitor: Memory released properly when leaving screen

3. **Visibility Test**: Scroll video out of view → wait 5s → scroll back
   - Expected: Video should still be available (not deleted, just paused)
   - Expected: Retry count preserved for when it becomes visible again

## Configuration

Key constants that control cancellation behavior:

- `VideoLoadingManager.bufferDistance = 1`: Keep 1 tweet behind as buffer
- Immediate cancellation distance: `>2 positions` from current tweet
- No artificial delays in cancellation processing (was 0.5s timer)

## Migration Notes

### No Breaking Changes
All changes are internal optimizations:
- Public APIs remain unchanged
- Video playback behavior unchanged when visible
- Cache persistence unchanged
- Only affects out-of-sight resource management

### Backwards Compatibility
- Retry counts preserved (not reset on cancellation)
- Player cache preserved (just paused, not removed)
- Disk cache unchanged
- LocalHTTPServer unchanged

## Monitoring

Added debug logs to track cancellation:
```
🛑 [CANCEL OUT OF SIGHT] Stopped all loading/buffering for: {mediaID}
```

Watch for these logs during fast scrolling to verify immediate cancellation is working.

## Future Improvements

1. **Adaptive Buffer Distance**: Adjust buffer based on scroll velocity
2. **Memory-Based Cancellation**: Cancel more aggressively when memory pressure is high
3. **Network-Aware Cancellation**: Keep more in cache on WiFi, cancel more on cellular
4. **User Preference**: Allow users to configure preloading aggressiveness

## Related Files
- `VideoLoadingManager.swift` - Visibility tracking and cancellation orchestration
- `SharedAssetCache.swift` - Asset/player lifecycle management
- `MediaGridView.swift` - Grid-level resource cancellation
- `MediaCell.swift` - Cell-level visibility tracking (already had good image cancellation)

## References
- iOS memory management best practices
- AVFoundation buffering control
- SwiftUI lifecycle management (onAppear/onDisappear)
