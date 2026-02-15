# LocalHTTPServer Background Recovery Fix

**Date**: October 16, 2025  
**Issue**: All videos show black screens after app goes to background

## Problem Description

When the app goes to background (even for short periods), all videos would show black screens when returning to foreground. The issue occurred for **all background events**, not just long ones.

## Root Causes

### 1. **Unnecessary Server Stops on Short Backgrounds**
The server was being stopped on **every** background event (line 149 AppDelegate), even though iOS keeps network listeners alive for short background periods. This caused:
- Unnecessary port releases
- Race conditions during restart
- Risk of binding to different ports on restart

### 2. **Race Condition Between Stop and Start**
Both `stop()` and `start()` are async operations on the same queue:
```swift
// handleAppDidEnterBackground
LocalHTTPServer.shared.stop()  // Async on queue

// handleAppWillEnterForeground (called milliseconds later)
LocalHTTPServer.shared.start() // Async on queue
```

The problem:
- `start()` checks `if self.isStopping { return }` (line 60)
- If `stop()` is still in progress, `start()` returns early
- Server never restarts → videos fail to load

### 3. **Port Changes Break Existing Players**
When the server restarts, it may bind to a **different port** due to randomization (line 159-160 in LocalHTTPServer):
```swift
let randomOffset = UInt16.random(in: 1...900)
let tryPort = startPort + randomOffset + UInt16(attempt)
```

But existing AVPlayers still have URLs pointing to the **old port**:
- Player URL: `http://127.0.0.1:8080/...`
- New server port: `8081`
- Result: Connection refused → black screen

### 4. **No Recovery for Short Backgrounds**
Only backgrounds **>5 minutes** triggered full recovery (line 176). Short backgrounds would:
- Stop/start server (potentially changing port)
- NOT clear player caches
- Leave players with stale URLs

## Solution Implemented

### 1. Don't Stop Server on Short Backgrounds

**File**: `Sources/App/AppDelegate.swift`

```swift
@objc private func handleAppDidEnterBackground() {
    print("[AppDelegate] App did enter background")
    
    // Store timestamp when app went to background
    UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")
    
    // DON'T stop LocalHTTPServer - iOS keeps network listeners alive for short backgrounds
    // Only stop for long backgrounds (>5 min) to avoid race conditions and port changes
    
    // Background handling is now done by SimpleVideoPlayer's notification observers
}
```

**Rationale**: iOS keeps network listeners active during short background periods. Stopping the server unnecessarily creates race conditions and port changes.

### 2. Conditional Recovery Based on Background Duration

**File**: `Sources/App/AppDelegate.swift`

```swift
@objc private func handleAppWillEnterForeground() {
    // Check how long app was in background
    if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
        let timeInBackground = Date().timeIntervalSince(backgroundDate)
        
        if timeInBackground > 300 { // 5 minutes
            // Full restart for long backgrounds
            Task {
                await restartVideoInfrastructure()
            }
        } else {
            // For short backgrounds, just ensure server is running
            LocalHTTPServer.shared.start()
        }
    }
}
```

**Changes**:
- **Short backgrounds (<5 min)**: Only call `start()` to ensure server is running (idempotent)
- **Long backgrounds (>5 min)**: Full infrastructure restart with player cache clearing

### 3. Improved Server Start with Stop Synchronization

**File**: `Sources/CachingPlayerItem/LocalHTTPServer.swift`

```swift
public func start() {
    queue.async { [weak self] in
        guard let self = self else { return }
        
        // If currently stopping, wait for it to finish
        if self.isStopping {
            NSLog("DEBUG: [LocalHTTPServer] Waiting for stop to complete before starting...")
            var waitCount = 0
            while self.isStopping && waitCount < 10 {
                Thread.sleep(forTimeInterval: 0.1)
                waitCount += 1
            }
        }
        
        // Don't start if already running or starting
        if self.isRunning || self.isStarting {
            return
        }
        
        self.startServer()
    }
}
```

**Changes**:
- Added wait loop if `isStopping` is true
- Ensures `stop()` completes before attempting to start
- Prevents race condition that caused server to not restart

### 4. Cleanup Stale Listeners Before Restart

**File**: `Sources/CachingPlayerItem/LocalHTTPServer.swift`

```swift
private func startServer() {
    // Extra check: if listener exists but not ready, cancel it first
    if listener != nil {
        NSLog("DEBUG: [LocalHTTPServer] Found stale listener, cleaning up before restart")
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    isStarting = true
    defer { isStarting = false }
    
    // ... rest of server start logic
}
```

**Changes**:
- Detects and cleans up stale listeners
- Ensures clean state before creating new listener
- Prevents binding conflicts

### 5. Proper Restart Order for Long Backgrounds

**File**: `Sources/App/AppDelegate.swift`

```swift
private func restartVideoInfrastructure() async {
    // CRITICAL: Clear ALL video players FIRST to release their URLs
    await MainActor.run {
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
    }
    
    // Reset connection pool
    LocalHTTPServer.shared.resetConnectionPool()
    
    // Stop server and wait for cleanup
    LocalHTTPServer.shared.stop()
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    
    // Restart server
    LocalHTTPServer.shared.start()
    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
}
```

**Critical Changes**:
1. **Clear players FIRST** - Releases all URL references before server restarts
2. **Longer stop delay** - 0.5s instead of 0.1s to ensure port is released
3. **Wait after start** - 0.2s to ensure server is ready

### 6. Early Server Initialization

**File**: `Sources/App/AppDelegate.swift`

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    // ... other initialization
    
    // Start LocalHTTPServer early to ensure it's ready before videos load
    LocalHTTPServer.shared.start()
    print("[AppDelegate] LocalHTTPServer started on app launch")
    
    return true
}
```

**Changes**:
- Start server during app launch, not lazily
- Ensures server is ready before first video loads
- Prevents race conditions during initial video loading

## Expected Behavior After Fix

### Short Background Events (<5 minutes)
1. App goes to background
   - Server keeps running
   - No port changes
   - No player cache clearing

2. App returns to foreground
   - `start()` called (idempotent - returns early if already running)
   - Videos continue working immediately
   - No black screens

### Long Background Events (>5 minutes)
1. App goes to background
   - Server keeps running initially

2. App returns to foreground after 5+ minutes
   - Clear all video players (releases old URLs)
   - Reset connection pool
   - Stop server (0.5s delay)
   - Restart server (may bind to different port)
   - New video loads will use new port

3. Videos reload with fresh URLs
   - No black screens

## Testing

### Test Case 1: Short Background
1. Load video and start playing
2. Switch to home screen for 5 seconds
3. Return to app
4. **Expected**: Video continues playing, no black screen

### Test Case 2: Long Background
1. Load multiple videos
2. Switch to home screen for 6+ minutes
3. Return to app
4. **Expected**: Videos reload and play, no black screen

### Test Case 3: Multiple Quick Backgrounds
1. Load video
2. Switch to home/back 5 times rapidly
3. **Expected**: Video works, no crashes, no black screens

## Logs to Verify

### Short Background:
```
[AppDelegate] App did enter background
[AppDelegate] App will enter foreground
[AppDelegate] App was in background for 3.2 seconds
[AppDelegate] Short background period, ensured LocalHTTPServer is running
[LocalHTTPServer] Already running/starting, skipping duplicate start
```

### Long Background:
```
[AppDelegate] App did enter background
[AppDelegate] App will enter foreground
[AppDelegate] App was in background for 320.5 seconds
[AppDelegate] Long background period detected, restarting video infrastructure
[AppDelegate] Restarting video infrastructure after long background
DEBUG: [SHARED ASSET CACHE] Clearing video players for background recovery
[LocalHTTPServer] Stopping server and releasing port 8081
[LocalHTTPServer] Port 8081 released
[LocalHTTPServer] Attempting to bind to port 8234...
[LocalHTTPServer] ✅ Successfully bound to port 8234
[AppDelegate] Video infrastructure restart complete
```

## Files Modified

1. **Sources/App/AppDelegate.swift**
   - Removed server stop on background
   - Added conditional recovery based on background duration
   - Improved restart sequence for long backgrounds
   - Added early server initialization on app launch

2. **Sources/CachingPlayerItem/LocalHTTPServer.swift**
   - Added stop synchronization in `start()`
   - Added stale listener cleanup in `startServer()`
   - Improved state management during restart

## Related Issues

- **Background Video Recovery Fix** - This fix builds on previous background recovery work
- **Port Conflict Fix** - Addresses port binding issues during restart
- **Progressive Video IP Caching** - Works with LocalHTTPServer for IP-independent caching

## Impact

- ✅ Videos work after short backgrounds
- ✅ Videos work after long backgrounds
- ✅ No more race conditions during server restart
- ✅ No more port mismatch issues
- ✅ Cleaner lifecycle management
- ✅ Better resource management (server stays alive when possible)

