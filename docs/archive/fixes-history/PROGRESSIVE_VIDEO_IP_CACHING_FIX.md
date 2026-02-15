# Progressive Video IP-Independent Caching Fix

## Date
October 16, 2025

## Bug Description

Progressive (MP4) videos showed **black screens** after IP address changes, while HLS videos continued to work correctly. The issue occurred when:
1. User watches an MP4 video → video loads fine
2. App goes to background
3. Server IP changes (e.g., `192.168.1.10` → `192.168.1.20`)
4. App returns to foreground → appUser IP refreshed ✅
5. User tries to watch the SAME MP4 video → **black screen** ❌

HLS videos worked fine in the same scenario.

## Root Cause

Progressive (MP4) videos were NOT using the IP-independent caching system. They were created with **plain `AVURLAsset`** using URLs that included the IP address.

### The Bug in Code

**SharedAssetCache.swift lines 367-370:**
```swift
} else {
    // For progressive videos, use plain AVURLAsset (matching AVPlayer branch)
    asset = AVURLAsset(url: resolvedURL)  // ❌ BUG: URL contains IP address!
    print("DEBUG: [SHARED ASSET CACHE] Created plain AVURLAsset for progressive video")
}
```

**SharedAssetCache.swift lines 640-645:**
```swift
} else {
    // Create fresh progressive video player item (matching AVPlayer branch)
    let asset = AVURLAsset(url: url)  // ❌ BUG: URL contains IP address!
    let playerItem = AVPlayerItem(asset: asset)
    
    NSLog("DEBUG: [SHARED ASSET CACHE] Created fresh progressive player item for singleton for mediaID: \(extractedMediaID)")
    return playerItem
}
```

### Why This Caused Black Screens

```
1. First Load:
   URL: http://192.168.1.10/ipfs/ABC123/video.mp4
   AVURLAsset created with this URL
   ✅ Video plays

2. LocalHTTPServer Caching:
   LocalHTTPServer.registerMediaMapping:
     mediaID "ABC123" → http://192.168.1.10/ipfs/ABC123/video.mp4
   Cached data in: Caches/ABC123/ranges/...

3. IP Changes:
   Server moves to 192.168.1.20
   AppUser IP refreshed ✅
   
4. Second Load (After IP Change):
   URL: http://192.168.1.20/ipfs/ABC123/video.mp4  // ← NEW IP!
   AVURLAsset created with NEW URL
   ❌ Doesn't match cached localhost mapping
   ❌ LocalHTTPServer can't find cache
   ❌ Black screen
```

### Why HLS Worked But MP4 Didn't

**HLS videos:**
```swift
let cachingPlayerItem = CachingPlayerItem(hlsURL: resolvedURL, mediaID: extractedMediaID, ...)
// ✅ Uses LocalHTTPServer with mediaID-based lookup
// ✅ Localhost URL: http://localhost:8081/ABC123/master.m3u8
// ✅ Cache lookup by mediaID, not real URL
// ✅ IP changes don't affect localhost URLs
```

**MP4 videos (before fix):**
```swift
let asset = AVURLAsset(url: resolvedURL)
// ❌ Uses raw URL with IP address
// ❌ URL: http://192.168.1.10/ipfs/ABC123/video.mp4
// ❌ No LocalHTTPServer registration
// ❌ Cache lookup fails when IP changes
```

## The Fix

Make progressive videos ALSO use LocalHTTPServer with mediaID-based registration, exactly like HLS videos.

### Code Changes

**1. loadAsset() method (lines 367-378):**
```swift
} else {
    // For progressive videos, use LocalHTTPServer for IP-independent caching
    LocalHTTPServer.shared.start()
    
    // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
    let localURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: resolvedURL)
    
    asset = AVURLAsset(url: localURL)  // ✅ Uses localhost URL
    print("DEBUG: [SHARED ASSET CACHE] Created AVURLAsset with LocalHTTPServer for progressive video")
    print("DEBUG: [SHARED ASSET CACHE]   MediaID: \(mediaID)")
    print("DEBUG: [SHARED ASSET CACHE]   Local URL: \(localURL.absoluteString)")
    print("DEBUG: [SHARED ASSET CACHE]   Real URL: \(resolvedURL.absoluteString)")
}
```

**2. getOrCreatePlayerItem() method (lines 647-660):**
```swift
} else {
    // Create fresh progressive video player item using LocalHTTPServer for IP-independent caching
    LocalHTTPServer.shared.start()
    
    // Register with LocalHTTPServer (handles mediaID-based caching and IP changes)
    let localURL = LocalHTTPServer.shared.registerAndGetURL(for: extractedMediaID, realURL: url)
    
    let asset = AVURLAsset(url: localURL)  // ✅ Uses localhost URL
    let playerItem = AVPlayerItem(asset: asset)
    
    NSLog("DEBUG: [SHARED ASSET CACHE] Created fresh progressive player item for singleton with LocalHTTPServer")
    NSLog("DEBUG: [SHARED ASSET CACHE]   MediaID: \(extractedMediaID)")
    NSLog("DEBUG: [SHARED ASSET CACHE]   Local URL: \(localURL.absoluteString)")
    NSLog("DEBUG: [SHARED ASSET CACHE]   Real URL: \(url.absoluteString)")
    return playerItem
}
```

## How It Works Now

### Flow After Fix

```
1. First Load:
   MediaID: ABC123
   Real URL: http://192.168.1.10/ipfs/ABC123/video.mp4
   
   ↓ registerAndGetURL(mediaID: "ABC123", realURL: http://192.168.1.10/...)
   
   LocalHTTPServer mapping:
     mediaID "ABC123" → http://192.168.1.10/ipfs/ABC123/video.mp4
   
   Local URL: http://localhost:8081/ABC123/video.mp4  ✅
   AVURLAsset created with localhost URL
   
   ↓ Player requests from localhost:8081
   
   LocalHTTPServer:
     1. Lookup mediaID "ABC123"
     2. Check cache: Caches/ABC123/ranges/...
     3. Cache miss → Fetch from real URL
     4. Cache the data
     5. Serve to player
   
   ✅ Video plays and caches

2. IP Changes (App in Background):
   Server moves to 192.168.1.20
   AppDelegate.refreshAppUserIP() updates IPs ✅

3. Second Load (After IP Change):
   MediaID: ABC123 (same!)
   Real URL: http://192.168.1.20/ipfs/ABC123/video.mp4  // ← NEW IP
   
   ↓ registerAndGetURL(mediaID: "ABC123", realURL: http://192.168.1.20/...)
   
   LocalHTTPServer mapping UPDATE:
     mediaID "ABC123" → http://192.168.1.20/ipfs/ABC123/video.mp4  ← Updated!
   
   Local URL: http://localhost:8081/ABC123/video.mp4  ✅ Same as before!
   AVURLAsset created with same localhost URL
   
   ↓ Player requests from localhost:8081
   
   LocalHTTPServer:
     1. Lookup mediaID "ABC123"
     2. Check cache: Caches/ABC123/ranges/... ✅ HIT!
     3. Serve from cache instantly
   
   ✅ Video plays immediately from cache!
   ✅ No black screen!
```

### Key Insight

The localhost URL is **IP-independent**:
- `http://localhost:8081/ABC123/video.mp4` (always the same)

The mediaID mapping is **IP-updateable**:
- `registerAndGetURL()` updates the real URL when IP changes
- Cache lookup uses mediaID, not the real URL
- Cached data remains valid regardless of IP changes

## Benefits

### 1. Consistent Behavior
- ✅ HLS and progressive videos now use the same caching strategy
- ✅ Both are resilient to IP address changes
- ✅ Unified codebase, easier to maintain

### 2. Cache Preservation
- ✅ Cached progressive videos remain valid after IP changes
- ✅ No re-downloads when only the IP changed
- ✅ Faster playback from cache

### 3. User Experience
- ✅ No more black screens after returning from background
- ✅ Instant playback of previously watched videos
- ✅ Seamless experience across IP changes

### 4. Network Efficiency
- ✅ Reduced bandwidth usage (no re-downloads)
- ✅ Faster startup for cached videos
- ✅ Better offline capabilities

## Testing

### Test 1: Progressive Video After IP Change
```
1. Play an MP4 video → wait for full load
2. Note mediaID from logs
3. Send app to background
4. Change server IP address
5. Bring app to foreground → verify IP refresh
6. Play the SAME MP4 video
7. ✅ Should play instantly from cache
8. ✅ Check logs: "Serving cached byte range"
9. ✅ No black screen
```

### Test 2: HLS vs Progressive Consistency
```
1. Play HLS video → cache
2. Play MP4 video → cache
3. Change IP
4. Play both videos again
5. ✅ Both should play from cache
6. ✅ Both should use localhost URLs
7. ✅ Both should be fast
```

### Test 3: Cache Directory Structure
```
After playing videos, check:

Caches/
  ABC123/  (HLS video)
    _master.m3u8
    720p/
      segment000.ts
      segment001.ts
  
  DEF456/  (Progressive video)
    ranges/
      r_0_8191
      r_8192_16383
      ...

✅ Both use mediaID-based directories
✅ IP address not in cache paths
```

## Files Modified

**`/Sources/Core/SharedAssetCache.swift`**
- Lines 367-378: Progressive videos in `loadAsset()` now use LocalHTTPServer
- Lines 647-660: Progressive videos in `getOrCreatePlayerItem()` now use LocalHTTPServer

## Related Issues

This fix complements the appUser IP refresh fix:
- AppDelegate refreshes appUser IP on foreground ✅
- LocalHTTPServer updates mediaID mappings with new IPs ✅
- Cached data remains valid via mediaID lookup ✅
- Videos play seamlessly after IP changes ✅

## Conclusion

Progressive (MP4) videos now have the same IP-independent caching as HLS videos. By using LocalHTTPServer with mediaID-based registration, cached videos remain playable even when server IP addresses change. This eliminates black screens and provides a seamless user experience.

**Recovery Time:** Instant (cache hit even with new IP)
**User Impact:** Zero (transparent fix)
**Performance:** Improved (faster from cache, no re-downloads)

