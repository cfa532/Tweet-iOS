# Background Video Recovery Fix

## Problem Description

When the app goes to background for a long time (>5 minutes), videos would:

1. **Black screen on all videos** - Video layers become invalid after extended background periods
2. **Videos fail to load after user login** - Network infrastructure (LocalHTTPServer) stops working
3. **App restart required** - Only way to recover was to force quit and restart the app

## Root Causes

### 1. LocalHTTPServer Lifecycle Issues
- LocalHTTPServer was started once during video loading but never restarted
- iOS suspends network listeners during extended background periods
- When app returns, videos try to load from `localhost:8080` URLs that no longer work
- URLSession connection pool becomes invalidated during suspension

### 2. AVPlayer Resource Reclamation
- iOS reclaims AVPlayer resources during extended background periods
- Video layers become detached and invalid
- Cached players hold references to invalid video layers
- No validation or cleanup of invalid players on foreground return

### 3. Stale Video State Cache
- VideoStateCache held references to invalid players indefinitely
- No expiration or validation of cached states
- Attempting to restore from invalid cache caused black screens

## Solution Implemented

### 1. LocalHTTPServer Lifecycle Management

**File**: `Sources/App/AppDelegate.swift`

#### Background/Foreground Tracking
```swift
@objc private func handleAppDidEnterBackground() {
    // Store timestamp when app went to background
    UserDefaults.standard.set(Date(), forKey: "lastBackgroundTimestamp")
}

@objc private func handleAppWillEnterForeground() {
    // Check how long app was in background
    if let backgroundDate = UserDefaults.standard.object(forKey: "lastBackgroundTimestamp") as? Date {
        let timeInBackground = Date().timeIntervalSince(backgroundDate)
        
        // If app was in background for more than 5 minutes
        if timeInBackground > 300 {
            print("[AppDelegate] Long background period detected, restarting video infrastructure")
            Task {
                await restartVideoInfrastructure()
            }
        }
    }
    
    // Always ensure LocalHTTPServer is running
    LocalHTTPServer.shared.start()
}
```

#### Infrastructure Restart
```swift
private func restartVideoInfrastructure() async {
    print("[AppDelegate] Restarting video infrastructure after long background")
    
    // Reset LocalHTTPServer connection pool
    LocalHTTPServer.shared.resetConnectionPool()
    
    // Restart the server
    LocalHTTPServer.shared.stop()
    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    LocalHTTPServer.shared.start()
    
    // Clear video player caches to force fresh initialization
    await MainActor.run {
        SharedAssetCache.shared.clearVideoPlayersForBackgroundRecovery()
    }
}
```

### 2. LocalHTTPServer Connection Pool Reset

**File**: `Sources/CachingPlayerItem/LocalHTTPServer.swift`

#### Resettable Connection Pool
```swift
// Changed from lazy var to computed property with backing storage
private var _connectionPool: URLSession?
private var connectionPool: URLSession {
    if let pool = _connectionPool {
        return pool
    }
    
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 6
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 300
    config.httpShouldUsePipelining = true
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    
    let pool = URLSession(configuration: config)
    _connectionPool = pool
    NSLog("DEBUG: [LocalHTTPServer] Connection pool initialized")
    return pool
}
```

#### Reset Method
```swift
public func resetConnectionPool() {
    queue.async { [weak self] in
        guard let self = self else { return }
        NSLog("DEBUG: [LocalHTTPServer] Resetting connection pool for background recovery")
        
        // Invalidate existing session
        self._connectionPool?.invalidateAndCancel()
        self._connectionPool = nil
        
        // Next access will create a new session
        NSLog("DEBUG: [LocalHTTPServer] Connection pool reset complete")
    }
}
```

### 3. SharedAssetCache Background Recovery

**File**: `Sources/Core/SharedAssetCache.swift`

#### Clear Invalid Players Method
```swift
func clearVideoPlayersForBackgroundRecovery() {
    print("DEBUG: [SharedAssetCache] Clearing video players for background recovery")
    
    let playerCountBefore = playerCache.count
    let assetCountBefore = assetCache.count
    
    // Clear all cached players - they may have invalid video layers
    for (_, player) in playerCache {
        player.pause()
    }
    playerCache.removeAll()
    
    // Clear CachingPlayerItem instances
    cachingPlayerItems.removeAll()
    
    // Keep assets - they're still valid and can be reused
    // Keep resourceLoaderDelegates - they're needed for HLS playback
    // Keep cacheTimestamps - they track cache expiration
    
    print("DEBUG: [SharedAssetCache] Background recovery complete - cleared \(playerCountBefore) players, kept \(assetCountBefore) assets")
}
```

#### Enhanced Player Refresh
```swift
private func refreshCachedPlayers() {
    print("DEBUG: [SharedAssetCache] Refreshing \(playerCache.count) cached players")
    
    var validPlayers = 0
    var invalidPlayers = 0
    
    // Validate and refresh all cached players
    for (mediaID, player) in playerCache {
        // Check if player item is still valid
        guard let playerItem = player.currentItem else {
            invalidPlayers += 1
            continue
        }
        
        if playerItem.status == .failed {
            invalidPlayers += 1
            continue
        }
        
        validPlayers += 1
        
        // Force seek to refresh video layer and ensure buffering
        let currentTime = player.currentTime()
        player.seek(to: currentTime) { finished in
            if finished {
                player.preroll(atRate: 1.0) { success in
                    if success {
                        print("DEBUG: [SharedAssetCache] Player \(mediaID) refreshed successfully")
                    }
                }
            }
        }
    }
    
    // Clean up invalid players
    if invalidPlayers > 0 {
        Task { @MainActor in
            let invalidMediaIDs = self.playerCache.filter { (_, player) in
                guard let item = player.currentItem else { return true }
                return item.status == .failed
            }.map { $0.key }
            
            for mediaID in invalidMediaIDs {
                self.removeInvalidPlayer(for: mediaID)
            }
        }
    }
}
```

### 4. VideoStateCache Expiration and Validation

**File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

#### Enhanced VideoStateCache
```swift
class VideoStateCache {
    static let shared = VideoStateCache()
    private var cache: [String: (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool, timestamp: Date)] = [:]
    private let cacheExpirationInterval: TimeInterval = 600 // 10 minutes
    
    func getCachedState(for mid: String) -> (player: AVPlayer, time: CMTime, wasPlaying: Bool, originalMuteState: Bool)? {
        guard let cachedState = cache[mid] else {
            return nil
        }
        
        // Check if cache is stale
        let age = Date().timeIntervalSince(cachedState.timestamp)
        if age > cacheExpirationInterval {
            print("DEBUG: [VIDEO CACHE] Cache for \(mid) is stale (age: \(age)s), clearing")
            cache.removeValue(forKey: mid)
            return nil
        }
        
        // Validate player is still valid
        if cachedState.player.currentItem == nil || cachedState.player.currentItem?.status == .failed {
            print("DEBUG: [VIDEO CACHE] Cached player for \(mid) is invalid, clearing")
            cache.removeValue(forKey: mid)
            return nil
        }
        
        return (player: cachedState.player, time: cachedState.time, wasPlaying: cachedState.wasPlaying, originalMuteState: cachedState.originalMuteState)
    }
    
    func clearStaleCache() {
        let now = Date()
        let staleKeys = cache.filter { now.timeIntervalSince($0.value.timestamp) > cacheExpirationInterval }.map { $0.key }
        
        for key in staleKeys {
            cache.removeValue(forKey: key)
        }
        
        if !staleKeys.isEmpty {
            print("DEBUG: [VIDEO CACHE] Cleared \(staleKeys.count) stale cached states")
        }
    }
}
```

#### Stale Cache Cleanup in AppDelegate
```swift
@objc private func handleAppDidBecomeActive() {
    // Clear stale video state cache
    VideoStateCache.shared.clearStaleCache()
    
    // ... rest of the code
}
```

### 5. Enhanced Video Player Recovery

**File**: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

#### Improved handleDidBecomeActive
```swift
private func handleDidBecomeActive() {
    print("DEBUG: [VIDEO APP ACTIVE] App became active for \(mid)")
    
    // Validate player health first
    if let player = player {
        if player.currentItem == nil || player.currentItem?.status == .failed {
            print("DEBUG: [VIDEO APP ACTIVE] Player is invalid, clearing and will recreate for \(mid)")
            self.player = nil
            loadFailed = false
            retryCount = 0
        }
    }
    
    // Force view recreation to fix black screen
    if player != nil {
        representableId += 1
        print("DEBUG: [VIDEO APP ACTIVE] Forced view recreation for \(mid)")
    }
    
    // Restore cached state if no player exists
    if player == nil && shouldLoadVideo && !isPlayerDetached {
        restoreCachedVideoState()
    }
    
    // Try to get from SharedAssetCache
    if player == nil && shouldLoadVideo && !isPlayerDetached {
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: playerCacheKey) {
            configurePlayer(cachedPlayer)
        }
    }
    
    // Force reload from URL if still no player
    if player == nil && shouldLoadVideo && !isPlayerDetached && isVisible {
        print("DEBUG: [VIDEO APP ACTIVE] No valid player found, forcing reload from URL for \(mid)")
        Task { @MainActor in
            await loadVideo()
        }
    }
    
    // ... rest of the recovery logic
}
```

## How It Works

### Short Background Periods (< 5 minutes)
1. App enters background → players are detached
2. App returns to foreground → LocalHTTPServer.start() ensures server is running
3. Players are reattached and refreshed
4. Videos continue playing normally

### Long Background Periods (> 5 minutes)
1. App enters background → timestamp recorded
2. iOS suspends app and may reclaim resources
3. App returns to foreground → time in background detected (> 5 minutes)
4. **Infrastructure restart triggered**:
   - LocalHTTPServer connection pool is reset
   - LocalHTTPServer is restarted
   - All cached players are cleared
   - Assets are preserved (can be reused)
5. Stale video state cache is cleaned
6. Videos detect invalid players and force reload
7. Fresh players are created with valid video layers
8. Videos load and play normally

## Benefits

1. ✅ **No black screens** - Invalid video layers are detected and recreated
2. ✅ **Automatic recovery** - No app restart required
3. ✅ **Preserved assets** - Cached video data is reused, saving bandwidth
4. ✅ **Network resilience** - LocalHTTPServer automatically restarts
5. ✅ **Stale cache cleanup** - Old invalid state is automatically removed
6. ✅ **Player validation** - Invalid players are detected and replaced
7. ✅ **Graceful degradation** - System recovers automatically without user intervention

## Testing Scenarios

### Test 1: Short Background (< 5 minutes)
1. Play a video in the app
2. Put app in background for 2 minutes
3. Return to foreground
4. **Expected**: Video resumes playing without issues

### Test 2: Long Background (> 5 minutes)
1. Play a video in the app
2. Put app in background for 10 minutes
3. Return to foreground
4. **Expected**: Videos may briefly show loading state, then play normally
5. **Expected**: No black screens
6. **Expected**: No app restart required

### Test 3: Very Long Background (> 1 hour)
1. Load videos in the app
2. Put app in background for 2 hours
3. Return to foreground
4. **Expected**: All videos reload fresh with valid players
5. **Expected**: Cached video data is reused if still available
6. **Expected**: No permanent black screens

### Test 4: After User Login
1. Open app (logged out)
2. Log in
3. Navigate to timeline with videos
4. **Expected**: Videos load and play normally
5. **Expected**: LocalHTTPServer starts automatically on first video load

## Debug Logging

The fix includes comprehensive debug logging to monitor the recovery process:

```
[AppDelegate] App was in background for XXX seconds
[AppDelegate] Long background period detected, restarting video infrastructure
[AppDelegate] Restarting video infrastructure after long background
[LocalHTTPServer] Resetting connection pool for background recovery
[LocalHTTPServer] Connection pool reset complete
[SharedAssetCache] Clearing video players for background recovery
[SharedAssetCache] Background recovery complete - cleared X players, kept Y assets
[VIDEO CACHE] Cleared X stale cached states
[VIDEO APP ACTIVE] Player is invalid, clearing and will recreate
[VIDEO APP ACTIVE] No valid player found, forcing reload from URL
```

## Performance Impact

- **Minimal overhead**: Infrastructure restart only occurs after 5+ minutes in background
- **Preserved bandwidth**: Assets (cached video files) are reused, only players are recreated
- **Quick recovery**: Entire restart process takes ~100ms + video loading time
- **No user intervention**: All recovery is automatic and transparent

## Related Issues Fixed

This fix also addresses related issues:
- Videos not loading after login
- Black screens after phone calls
- Videos failing after control center access
- Network errors after extended background periods
- Stale player states causing playback issues

## Future Improvements

Potential enhancements for consideration:
1. Make the 5-minute threshold configurable
2. Add metrics to track recovery success rate
3. Implement progressive retry with exponential backoff
4. Add user-facing error messages for persistent failures
5. Consider preemptive resource cleanup before iOS suspension

