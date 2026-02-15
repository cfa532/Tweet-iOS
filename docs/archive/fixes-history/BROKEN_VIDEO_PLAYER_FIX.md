# Broken Video Player Recovery Fix

**Date**: 2026-01-04  
**Issue**: MediaCell video players sometimes get stuck in a broken state and don't recover when scrolled out/back or when long-pressed to reload.

## Root Cause Analysis

The video player recovery system had three critical gaps:

### 1. Long Press Reload Didn't Clear Broken Players
**Problem**: When a user long-pressed to reload a broken video, the `handleError(strategy: .manualReset)` function only reset state variables but **did not clear the broken player instance** or its caches.

**Result**: `setupPlayer()` would reuse the same broken player from `VideoStateCache` or `SharedAssetCache`, so the video remained broken.

**Code Location**: `SimpleVideoPlayer.swift:4130-4137`

### 2. Scroll Recovery Insufficient
**Problem**: When scrolling a broken video out and back into view, `handleOnAppear()` only checked for `.failed` status. Videos in other broken states (has error but not failed status, stuck loading, etc.) were not detected.

**Result**: Broken players that weren't explicitly in `.failed` status would persist indefinitely.

**Code Location**: `SimpleVideoPlayer.swift:908-924`

### 3. Limited Health Check Coverage
**Problem**: `performPeriodicHealthCheck()` only ran when `loadingState.isLoading`. If a video was broken but not showing a spinner, the health check never ran.

**Result**: Silent broken players were never detected or recovered.

**Code Location**: `SimpleVideoPlayer.swift:4237-4287`

## The Fix

### Fix 1: Proper Manual Reset Cleanup
```swift
case .manualReset, .networkRecovery:
    // CRITICAL: For manual reset, completely clean up the broken player
    print("DEBUG: [VIDEO ERROR] Manual reset - cleaning up broken player for \(mid)")
    removePlayerObservers()      // Clear KVO and notification observers
    cleanupFailedPlayer()         // Clear VideoStateCache
    
    // Clear from all caches to force fresh load
    SharedAssetCache.shared.clearAssetCache(for: mid)
    
    playbackState = .notStarted
    loadingState = .idle
    retryAttempts = 0
    player = nil  // CRITICAL: Clear the broken player reference
    
    if shouldLoadVideo {
        setupPlayer()  // Now this will create a fresh player
    }
```

**Key Changes**:
- Added `removePlayerObservers()` to clean up KVO/notification observers
- Added `cleanupFailedPlayer()` to clear `VideoStateCache`
- Added `SharedAssetCache.shared.clearAssetCache(for: mid)` to clear asset cache
- Added `player = nil` to clear the broken player reference
- Now `setupPlayer()` creates a completely fresh player instead of reusing the broken one

### Fix 2: Enhanced Broken State Detection on Scroll
```swift
// For MediaCell mode, check if existing player is broken and needs recreation
if let player = player, let playerItem = player.currentItem {
    // Check for various broken states
    let isFailed = playerItem.status == .failed
    let hasError = playerItem.error != nil || player.error != nil
    let isStuckLoading = loadingState.isLoading && playerItem.status == .readyToPlay && !playerItem.loadedTimeRanges.isEmpty
    
    if isFailed || hasError || isStuckLoading {
        print("⚠️ [VIDEO APPEAR] Detected broken player for \(mid): failed=\(isFailed), hasError=\(hasError), stuckLoading=\(isStuckLoading)")
        handleError(strategy: .loadFailure)
        return
    }
    
    // If player is healthy, mark as initialized for smooth scrolling
    if loadingState.isLoaded && !hasInitialized {
        hasInitialized = true
    }
}
```

**Key Changes**:
- Now checks for multiple broken states: `.failed`, `hasError`, and `isStuckLoading`
- Triggers recovery immediately when any broken state is detected
- More comprehensive detection catches videos that were previously missed

### Fix 3: Expanded Health Check Coverage
```swift
private func performPeriodicHealthCheck() async {
    // Run health check when:
    // 1. In loading state (stuck loading detection)
    // 2. Player exists but might be broken (silent failure detection)
    let shouldCheckLoading = loadingState.isLoading
    let shouldCheckBroken = (player != nil && mode == .mediaCell)
    
    guard shouldCheckLoading || shouldCheckBroken else { return }
    
    // Wait 3 seconds before checking
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    
    // CASE 1: Stuck loading state detection
    if loadingState.isLoading {
        // ... existing stuck loading detection ...
    }
    
    // CASE 2: Silent broken player detection (for visible MediaCell videos only)
    if mode == .mediaCell && isVisible {
        guard let player = player, let playerItem = player.currentItem else { return }
        
        // Check for broken states that KVO might have missed
        let isFailed = playerItem.status == .failed
        let hasError = playerItem.error != nil || player.error != nil
        
        if isFailed || hasError {
            NSLog("⚠️ [HEALTH CHECK] Detected silently broken player for \(mid) - triggering recovery")
            await MainActor.run {
                self.handleError(strategy: .loadFailure)
            }
        }
    }
}
```

**Key Changes**:
- Now runs health check when a player exists, not just when loading
- Added CASE 2 for silent broken player detection
- Checks for `.failed` status or errors even when not in loading state
- Provides a safety net for videos that slip through KVO observer detection

## Recovery Flow

### Long Press Flow
1. User long-presses broken video
2. `handleLongPress()` → `handleError(strategy: .manualReset)`
3. `.manualReset` case:
   - Removes all observers
   - Clears player from VideoStateCache
   - Clears asset from SharedAssetCache
   - Sets `player = nil`
   - Calls `setupPlayer()`
4. `setupPlayer()` creates completely fresh player (no cached player to reuse)
5. Video recovers ✅

### Scroll Out/Back Flow
1. User scrolls broken video back into view
2. `handleOnAppear()` called
3. Checks existing player for broken states:
   - `.failed` status
   - `hasError` (player or item error)
   - `isStuckLoading`
4. If broken: `handleError(strategy: .loadFailure)` → auto-retry with backoff
5. If healthy: Mark as initialized for smooth scrolling
6. Video either recovers or shows spinner for retry ✅

### Periodic Health Check Flow
1. `task(id: loadingState)` triggers `performPeriodicHealthCheck()`
2. Waits 3 seconds
3. Checks two cases:
   - **CASE 1**: Loading state stuck? Fix it and start playback
   - **CASE 2**: Silent broken player? Trigger recovery
4. Catches broken videos that KVO observers missed ✅

## Testing
To test this fix:
1. Find a video that gets stuck/broken
2. **Test long press**: Long press the broken video → should show "Reloading Video..." → should recover
3. **Test scroll**: Scroll the broken video out of view → scroll back → should auto-detect and recover
4. **Test health check**: Wait 3 seconds on a broken video → should auto-detect via periodic check

## Performance Impact
- **No scroll performance impact**: Only checks existing values, no expensive operations
- **No background thread blocking**: Health check uses async/await properly
- **Minimal overhead**: Only runs when needed (on appear, or every 3s for visible videos)
- **Memory efficient**: Properly clears caches during recovery

## Related Files
- `SimpleVideoPlayer.swift` - Main video player component
- `VideoStateCache.swift` - Caches player state across views
- `SharedAssetCache.swift` - Caches AVAsset and AVPlayer instances

## Notes
- This fix is complementary to the disabled watchdog (which was causing scroll lag)
- Uses existing recovery mechanisms (`handleError(strategy:)`) but ensures they're triggered correctly
- Relies on lazy recovery (only when needed) rather than aggressive polling
- Preserves smooth scrolling by using lightweight checks

