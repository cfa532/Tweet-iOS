# Overnight Background Black Screen Bug - Analysis & Fix

**Date**: October 17, 2025  
**Issue**: Black screens after app is in background overnight  
**Status**: ✅ FIXED

## Problem Description

When the app is put in the background **overnight** (8+ hours), videos show black screens upon return, even though the previous fix was supposed to handle long backgrounds.

## Root Cause

### Critical Bug in `AppDelegate.handleAppWillEnterForeground()`

The code calculates `timeInBackground` on line 178 but **NEVER USES IT** to decide the recovery strategy!

```swift
// CURRENT CODE - BUGGY (lines 177-193)
if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
    let timeInBackground = Date().timeIntervalSince(backgroundDate)
    NSLog("☀️ [AppDelegate] App returning from \(Int(timeInBackground))s background")
    
    // ❌ BUG: Only checks isRunning, ignores timeInBackground!
    if LocalHTTPServer.shared.isRunning {
        // Just clears cache - WRONG for overnight backgrounds!
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        VideoStateCache.shared.clearAllCache()
    } else {
        // Full restart - but this path is rarely hit!
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
        VideoStateCache.shared.clearAllCache()
        LocalHTTPServer.shared.startAndWait()
    }
}
```

### Why This Fails for Overnight Backgrounds

1. **App goes to background overnight** (e.g., 8+ hours)
2. **iOS suspends the NWListener** but doesn't kill the process
3. **`isRunning` flag stays `true`** because the listener object still exists in memory
4. **Listener is SUSPENDED** and cannot process connections
5. **When returning to foreground:**
   - Code checks `isRunning` → `true`
   - Takes the "server still running" path
   - Just clears cache, doesn't restart server
6. **Listener never wakes up** from suspension
7. **Videos try to load** → connection hangs → black screen

## What Should Happen

According to the documentation (`BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md`), the code should:

1. **Check background duration** (`timeInBackground`)
2. **If > 5 minutes (300s)**: Full server restart with blocking semaphore
3. **If < 5 minutes**: Just clear cache (server should still be responsive)

### Correct Approach (from documentation)

```swift
if timeInBackground > 300 {  // 5 minutes
    // LONG background - do FULL restart with blocking
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await restartVideoInfrastructure()
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(10))
} else {
    // SHORT background - just clear cache
    if LocalHTTPServer.shared.isRunning {
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
    } else {
        LocalHTTPServer.shared.startAndWait()
    }
}
```

## The Fix

Replace the `isRunning` check with a **duration-based** check:
- Use `timeInBackground > 300` as the primary condition
- For long backgrounds (>5min), **ALWAYS** do full restart regardless of `isRunning`
- Use blocking semaphore to ensure server is ready before videos load

## Why `isRunning` is Unreliable for Overnight Backgrounds

The `isRunning` flag indicates whether the `NWListener` object exists, NOT whether it's actively processing connections:

| Background Duration | iOS Behavior | `isRunning` | Reality |
|---------------------|--------------|-------------|---------|
| < 5 minutes | Listener stays active | `true` | ✅ Actually working |
| 5-30 minutes | Listener may suspend | `true` | ⚠️ May be suspended |
| Overnight (8+ hours) | Listener suspended | `true` | ❌ Definitely suspended |

**Key Insight**: After overnight suspension, `isRunning == true` is a **lie**. The listener exists but is not processing connections.

## The Fix Applied

### Changed `AppDelegate.handleAppWillEnterForeground()`

**File**: `Sources/App/AppDelegate.swift` (lines 167-226)

```swift
@objc private func handleAppWillEnterForeground() {
    // Check how long app was in background
    if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
        let timeInBackground = Date().timeIntervalSince(backgroundDate)
        
        // ✅ FIX: Use DURATION-based recovery, not isRunning check
        if timeInBackground > 300 {  // 5 minutes
            // LONG background - ALWAYS do full restart with BLOCKING
            NSLog("🔄 [AppDelegate] Long background - forcing full restart")
            
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await restartVideoInfrastructure()
                semaphore.signal()
            }
            
            // BLOCK main thread until server restart completes
            let result = semaphore.wait(timeout: .now() + .seconds(10))
            
            if result == .timedOut {
                NSLog("❌ [AppDelegate] Server restart TIMEOUT")
            } else {
                NSLog("✅ [AppDelegate] Server fully restarted - videos ready")
            }
        } else {
            // SHORT background - just clear cache, server should be responsive
            if LocalHTTPServer.shared.isRunning {
                SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
                VideoStateCache.shared.clearAllCache()
            } else {
                LocalHTTPServer.shared.startAndWait()
            }
        }
    }
}
```

### Key Changes

1. **Primary condition changed**: `if timeInBackground > 300` instead of `if isRunning`
2. **Long backgrounds (>5min)**: ALWAYS do full restart, even if `isRunning == true`
3. **Blocking semaphore**: Ensures videos don't load until server is ready
4. **Short backgrounds (<5min)**: Still use `isRunning` check (server should be responsive)

## Files Modified

1. **`Sources/App/AppDelegate.swift`**
   - Line 167-226: `handleAppWillEnterForeground()`
   - Replaced `isRunning` check with `timeInBackground > 300` check
   - Added blocking semaphore for long backgrounds

## Expected Behavior After Fix

### Overnight Background (8+ hours)
1. User backgrounds app for 8+ hours
2. Returns to app
3. Code detects `timeInBackground > 300s`
4. Triggers full server restart (stop → wait → start)
5. Blocks main thread until server is ready
6. Videos load with fresh connections
7. ✅ No black screens

### Short Background (< 5 minutes)
1. User backgrounds app for 30s
2. Returns to app
3. Code detects `timeInBackground < 300s`
4. Just clears cache
5. Server was never suspended, still responsive
6. Videos load immediately
7. ✅ No black screens

## Related Documentation

- `BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md` - Original fix documentation
- `LOCAL_HTTP_SERVER_BACKGROUND_FIX.md` - Server lifecycle management

