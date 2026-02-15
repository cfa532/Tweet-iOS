# Port-Independent Playlist Caching Fix

**Date**: October 17, 2025  
**Issue**: Videos showing black screen with broken icon after app backgrounding due to `LocalHTTPServer` port changes  
**Status**: ✅ RESOLVED

## Problem

When the app returned from background, videos would fail to load with error:
```
NSURLErrorDomain Code=-1004 "Could not connect to the server"
```

### Root Cause

The `LocalHTTPServer` was caching HLS playlist files with full URLs including the server port:
```
http://server.com:8081/ipfs/QmHash/720p/playlist.m3u8
http://server.com:8081/ipfs/QmHash/segment000.ts
```

When the server restarted (either normally or after being killed by iOS), it would:
1. Bind to a new available port (e.g., 40808 instead of 8081)
2. Try to serve cached playlists that still referenced the old port
3. AVPlayer would try to connect to `http://127.0.0.1:8081/...` (old port from cache)
4. Connection would fail because server is now on port 40808

### Initial Failed Approach

First attempt tried to strip URLs to only the last 2 path components:
```
http://server.com:8081/ipfs/QmHash/720p/playlist.m3u8 
→ 720p/playlist.m3u8  ❌ (lost critical path information)
```

This broke playlist reconstruction because the `/ipfs/QmHash/` portion was lost.

## Solution

### Implementation

Cache playlists with **absolute paths only** (remove scheme/host/port but keep full path):

```swift
// LocalHTTPServer.swift

private func stripPlaylistToRelativePaths(_ playlistString: String, baseURL: URL) -> String {
    // Pattern to match full URLs: http://anything or https://anything
    let urlPattern = "(https?://[^\\s]+\\.(m3u8|ts))"
    
    for match in urlRegex.matches(in: modified, options: [], range: ...) {
        let fullURL = String(modified[range])
        if let url = URL(string: fullURL) {
            // Extract FULL path (keeps everything after scheme://host:port)
            // "http://server:8081/ipfs/QmHash/720p/playlist.m3u8" 
            // → "/ipfs/QmHash/720p/playlist.m3u8"
            let relativePath = url.path
            modified.replaceSubrange(range, with: relativePath)
        }
    }
    return modified
}
```

When serving cached playlists, inject the **current** server port:

```swift
private func rewritePlaylistURLs(_ playlistString: String, mediaID: String, baseURL: URL) -> String {
    for match in playlistRegex.matches(in: modified, ...) {
        let pathString = String(modified[range])
        let localhostURL: String
        
        if pathString.hasPrefix("/") {
            // Absolute path: inject current port
            // "/ipfs/QmHash/720p/playlist.m3u8" 
            // → "http://127.0.0.1:{currentPort}/mediaID/ipfs/QmHash/720p/playlist.m3u8"
            localhostURL = "http://127.0.0.1:\(port)/\(mediaID)\(pathString)"
        } else {
            // Relative path: use playlist directory
            localhostURL = "http://127.0.0.1:\(port)/\(mediaID)\(playlistDirectory)/\(pathString)"
        }
        modified.replaceSubrange(range, with: localhostURL)
    }
    return modified
}
```

### Files Modified

1. **`Sources/CachingPlayerItem/LocalHTTPServer.swift`**:
   - Updated `stripPlaylistToRelativePaths()` to keep full absolute paths
   - Updated `rewritePlaylistURLs()` to handle both absolute and relative paths
   - Added logic to inject current port when serving cached playlists

2. **`Sources/Core/SharedAssetCache.swift`**:
   - Updated `clearVideoPlayersForBackgroundRecovery()` comment to note HLS cache is now port-independent

## Benefits

1. **✅ Port Independence**: Cached playlists work regardless of which port the server binds to
2. **✅ Faster Recovery**: No need to re-download playlists after backgrounding
3. **✅ No Connection Errors**: AVPlayer always uses the correct current port
4. **✅ Persistent Cache**: HLS cache survives server restarts

## Testing

### Test Case 1: Normal Background/Foreground
1. Launch app, play video
2. Background app for 2+ minutes
3. Return to foreground
4. **Expected**: Videos resume playing immediately
5. **Result**: ✅ PASS

### Test Case 2: Long Background (Server Killed)
1. Launch app, play video
2. Background app for 10+ minutes (iOS kills server)
3. Return to foreground
4. **Expected**: Server restarts on new port, videos load from cache
5. **Result**: ✅ PASS

### Test Case 3: Fresh Install
1. Delete app
2. Install fresh build
3. Login and play videos
4. **Expected**: Videos download and cache with absolute paths
5. **Result**: ✅ PASS

## Verification in Logs

After the fix, you should see:
```
Tweet[PID] <Debug>: DEBUG: [LocalHTTPServer] Stripped playlist to relative paths for caching
Tweet[PID] <Debug>: DEBUG: [LocalHTTPServer] Rewrote playlist URLs for localhost
Tweet[PID] <Debug>: DEBUG: [LocalHTTPServer] Served cached playlist with rewritten URLs
```

No more `NSURLErrorDomain Code=-1004` errors when returning from background.

## Related Issues

- Background video black screen issue (RESOLVED)
- Server port binding conflicts (RESOLVED)
- HLS cache invalidation after backgrounding (RESOLVED)

## Notes

- This fix works for both HLS and progressive videos
- The absolute path format (`/ipfs/QmHash/...`) is standard IPFS URL structure
- The `rewritePlaylistURLs()` method handles both absolute paths (new format) and relative paths (old format) for backward compatibility during the transition period

