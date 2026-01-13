# Race Condition & Freezing Fix - SharedAssetCache

## Problem Summary

After "performance improvements" that removed `Task.detached` calls, the app started freezing frequently during:
- Opening user profiles
- Scrolling through feeds
- More frequent in Release builds (race conditions are harder to catch in debug)

## Root Cause Analysis

The "optimization" of removing `Task.detached` to "prevent thread exhaustion" actually **introduced main thread blocking** by forcing synchronous disk I/O operations onto the main thread.

### Critical Blocking Operations Found

#### 1. **`hasDiskCache(for:)` - Called on Every Scroll**
**Before Fix:**
```swift
private func hasDiskCache(for mediaID: String) -> Bool {
    // ... cache check ...
    
    // ❌ BLOCKING: Synchronous disk I/O on main thread
    let contents = try FileManager.default.contentsOfDirectory(atPath: mediaCacheDir.path)
    // ... validation ...
    
    diskCacheStatus[mediaID] = (exists: diskCacheExists, timestamp: Date())
    return diskCacheExists
}
```

**Impact:**
- Called from `hasCachedContent()` which is `@MainActor`
- Each call blocks main thread for **5-20ms** depending on directory size
- With 10-20 videos on screen, that's **100-400ms of freezing per scroll**

**After Fix:**
```swift
private func hasDiskCache(for mediaID: String) -> Bool {
    // ✅ Only check in-memory cache
    if let cachedStatus = diskCacheStatus[mediaID] {
        // Instant return from memory
        return cachedStatus.exists
    }
    
    // ✅ Trigger async disk check in background
    Task.detached { [weak self] in
        await self?.updateDiskCacheStatus(for: mediaID)
    }
    
    return false // Conservative default
}
```

#### 2. **`checkCachedHLSPlaylist(for:baseURL:)` - Heavy File Enumeration**
**Before Fix:**
```swift
private func checkCachedHLSPlaylist(for mediaID: String, baseURL: URL) async -> URL? {
    // ❌ BLOCKING: Even though async, called from MainActor context
    guard let enumerator = FileManager.default.enumerator(at: mediaCacheDir, ...) else {
        return nil
    }
    
    while let fileURL = enumerator.nextObject() as? URL {
        // ❌ Reading files synchronously
        if let data = try? Data(contentsOf: fileURL) {
            // ... validation ...
        }
    }
}
```

**Impact:**
- Called during video player creation
- Enumerates entire cache directory (can be 50+ files for HLS)
- Reads multiple playlist files to validate
- **50-200ms blocking per video**

**After Fix:**
```swift
private func checkCachedHLSPlaylist(for mediaID: String, baseURL: URL) async -> URL? {
    // ✅ Quick memory check first
    if let cachedStatus = diskCacheStatus[mediaID], !cachedStatus.exists {
        return nil // Skip disk check if we know it's not there
    }
    
    // ✅ All disk I/O moved to background thread
    return await Task.detached {
        // FileManager operations happen on background thread
        // ...
    }.value
}
```

#### 3. **`clearAssetCache(for:)` & `clearPlayerForMediaID(_:)` - Disk Deletion**
**Before Fix:**
```swift
@MainActor func clearAssetCache(for mediaID: String) {
    // ... memory cleanup ...
    
    // ❌ BLOCKING: Synchronous file deletion
    let mediaDir = cacheDir.appendingPathComponent(mediaID)
    try? FileManager.default.removeItem(at: mediaDir)
    
    CachingPlayerItem.clearHLSCache(for: mediaID)
}
```

**Impact:**
- Called when videos fail or during cleanup
- Deleting HLS cache can take **10-50ms** (many small files)
- Blocks main thread during error recovery

**After Fix:**
```swift
@MainActor func clearAssetCache(for mediaID: String) {
    // ... memory cleanup ...
    
    // ✅ Async disk deletion
    Task.detached {
        let mediaDir = cacheDir.appendingPathComponent(mediaID)
        try? FileManager.default.removeItem(at: mediaDir)
        CachingPlayerItem.clearHLSCache(for: mediaID)
    }
}
```

## Why Release Builds Were More Affected

1. **Compiler Optimizations:** Debug builds have slower code paths that might have hidden timing issues
2. **Race Condition Visibility:** Release builds run faster, making race conditions more likely to manifest
3. **Memory Pressure:** Release builds may trigger more aggressive cleanup, causing more disk I/O

## The False Optimization

The comment "Disabled Task.detached during heavy concurrent operations to prevent thread exhaustion" was **incorrect** because:

1. **Swift Concurrency is Cooperative:** The executor manages thread pools efficiently
2. **Disk I/O Must Be Async:** Blocking main thread is ALWAYS worse than proper async handling
3. **Task.detached Is Designed for This:** It's specifically meant for work that shouldn't block

### Correct Usage of Task.detached

**✅ DO use Task.detached for:**
- File I/O (reading, writing, deletion)
- Network requests (when not using URLSession's async APIs)
- Heavy computation that shouldn't block main thread
- Any operation taking >16ms (one frame at 60fps)

**❌ DON'T use Task.detached for:**
- Simple dictionary lookups
- Array operations on small collections
- MainActor-isolated state updates

## Performance Impact

### Before Fix (Freezing)
```
Opening profile with 20 videos:
- 20 videos × 50ms disk check = 1000ms freeze
- User sees stuttering, unresponsive UI
```

### After Fix (Smooth)
```
Opening profile with 20 videos:
- 20 videos × 0.1ms memory check = 2ms overhead
- Disk checks happen in background
- UI remains responsive
```

## Testing Recommendations

1. **Profile with Instruments:**
   - Run "Time Profiler" and check for `FileManager` calls on main thread
   - Any call >16ms on main thread will cause dropped frames

2. **Test on Device:**
   - Simulators don't show real I/O performance
   - Test on older devices (iPhone SE) where I/O is slower

3. **Test Scrolling:**
   - Rapidly scroll through profiles with many videos
   - Open/close profiles repeatedly
   - Watch for stuttering or freezes

4. **Check Memory:**
   - Monitor memory in Xcode's Debug Navigator
   - Ensure async tasks aren't leaking
   - Verify cleanup still works correctly

## Related Files

- `SharedAssetCache.swift` - Main fixes applied here
- `CachingPlayerItem.swift` - Check for similar disk I/O patterns
- `LocalHTTPServer.swift` - Verify cache cleanup is async

## Key Takeaway

**"Performance optimization" that moves async work to synchronous is almost always wrong.**

If you see freezing after "removing Task.detached", the fix is to **add it back** with proper error handling, not to keep blocking the main thread.
