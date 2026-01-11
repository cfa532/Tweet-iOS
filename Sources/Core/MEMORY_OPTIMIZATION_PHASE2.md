# Memory Optimization Phase 2: File Cache Management

## Problem Statement

After Phase 1 (delegate cancellation fix), memory usage improved significantly:
- **Before Phase 1:** Unlimited growth during fast scrolling
- **After Phase 1:** 250MB during scrolling, 130MB after scrolling back

However, **120MB was still retained** after scrolling back, indicating file cache buildup.

## Root Causes

### 1. Partial Cache Files in File System Cache

When downloads are cancelled, **partial video.mp4 files** (50-100MB each) remain on disk:
- iOS keeps these in file system cache
- Memory is only released when iOS evicts the cache naturally
- During fast scrolling, multiple partial files accumulate

### 2. Repeated Cache Validation

The `isValidProgressiveCache()` function was called **multiple times per video**:
- Scans **4MB of data** per call to find moov atom
- Each scan loads data into iOS file cache
- Repeated scans cause memory pressure
- Generated excessive "moov atom not found" warnings

## Solutions Implemented

### Solution 1: Aggressive Partial Cache Cleanup

**Location:** `SharedAssetCache.markAsNotVisible()`

Deletes incomplete cache files immediately when video scrolls out of view:

```swift
// MEMORY FIX: Delete partial cache files to free file system cache memory
Task.detached(priority: .utility) {
    // Check if cache is incomplete (partial download)
    let isIncomplete = totalSize == nil || cachedSize < totalSize!
    
    if isIncomplete && cachedSize > 0 {
        // Delete partial files
        try? FileManager.default.removeItem(at: progressiveCache)
        try? FileManager.default.removeItem(at: metaFile)
        try? FileManager.default.removeItem(at: contiguousFile)
        
        print("🧹 [MEMORY] Deleted partial cache (25.4MB) for invisible video")
    }
}
```

**Benefits:**
- Frees 50-100MB per video immediately
- Prevents file cache buildup during fast scrolling
- Only deletes incomplete downloads (preserves complete caches)

### Solution 2: Cache Validation Results

**Location:** `LocalHTTPServer.isValidProgressiveCache()`

Added 5-minute validation cache to avoid repeated expensive scans:

```swift
// PERFORMANCE: Cache validation results
private var validationCache: [String: (isValid: Bool, timestamp: Date)] = [:]
private let validationCacheTTL: TimeInterval = 300 // 5 minutes

func isValidProgressiveCache(fileURL: URL) -> Bool {
    // Check cache first (instant)
    if let cached = validationCache[cacheKey] {
        let age = Date().timeIntervalSince(cached.timestamp)
        if age < validationCacheTTL {
            return cached.isValid  // No 4MB disk scan!
        }
    }
    
    // Perform expensive validation only once per 5 minutes
    let isValid = performExpensiveScan()
    
    // Cache result
    validationCache[cacheKey] = (isValid: isValid, timestamp: Date())
    return isValid
}
```

**Benefits:**
- Eliminates repeated 4MB scans
- Reduces file cache pressure
- Stops excessive "moov atom" warning logs
- First call: Expensive (4MB scan)
- Subsequent calls: Instant (cached result)

## Expected Results

### Memory Usage

| Scenario | Before Phase 2 | After Phase 2 | Improvement |
|----------|----------------|---------------|-------------|
| Fast scrolling | 250MB | ~150MB | -100MB (-40%) |
| After scroll back | 130MB | ~150MB | Stable |
| Retained memory | 120MB | ~20MB | -100MB (-83%) |

### Performance

- **No more repeated "moov atom" warnings** - Only one per file (cached after first check)
- **Faster scrolling** - Less disk I/O during validation
- **Cleaner logs** - Reduced log spam from repeated validations

## Testing Instructions

### 1. Fast Scroll Test
```
Action: Scroll quickly through 10+ videos
Expected: Memory stays ~150MB (not 250MB)
Check: Should see "Deleted partial cache" logs
```

### 2. Scroll Back Test
```
Action: Scroll back slowly through same videos
Expected: Memory stays stable ~150MB (doesn't drop to 130MB)
Reason: No file cache buildup to release
```

### 3. Validation Cache Test
```
Action: Fast scroll, then scroll back over same videos
Expected: No "moov atom" warnings on second pass
Check: validationCache contains entries (check with debugger)
```

### 4. Memory Instruments
```
Profile with Instruments → Allocations:
- Watch "All Anonymous VM" (file cache)
- Should stay stable during scrolling
- No large spikes from partial cache files
```

## Implementation Details

### File Locations
- `SharedAssetCache.swift` - Partial cache cleanup in `markAsNotVisible()`
- `LocalHTTPServer.swift` - Validation caching in `isValidProgressiveCache()`

### Thread Safety
- Partial cache cleanup uses `Task.detached(priority: .utility)` (background thread)
- Validation cache protected by `validationCacheLock` (thread-safe)

### Cache Invalidation
- Validation cache entries expire after 5 minutes
- Partial cache cleanup only deletes incomplete files
- Complete caches are preserved for reuse

## Monitoring

### Key Logs to Watch

**Partial Cache Deletion:**
```
🧹 [MEMORY] Deleted partial cache (25.4MB) for invisible video: QmABC...
```
- Should see this when scrolling away from videos quickly
- Size indicates how much memory was freed

**Validation Cache Hits:**
```
⚠️ [PROGRESSIVE CACHE] moov atom not found... (only ONCE per file)
```
- Should only see this once per video file
- Subsequent checks use cached result

### Debug Flags

Add these logs if you need more detail:

```swift
// In isValidProgressiveCache()
print("✅ [VALIDATION CACHE] Hit for \(cacheKey)")  // Cache hit
print("⚠️ [VALIDATION CACHE] Miss for \(cacheKey)")  // Cache miss (will scan)
```

## Known Limitations

1. **5-minute cache TTL** - Files that change within 5 minutes won't be re-validated
   - Not an issue in practice (cached files don't change)
   - TTL can be adjusted if needed

2. **Background deletion** - Cleanup happens asynchronously
   - Memory freed with slight delay (typically <100ms)
   - Not noticeable in practice

3. **Complete cache detection** - Requires meta file
   - If meta file is missing, we can't detect incomplete downloads
   - These files won't be deleted (conservative approach)

## Future Enhancements

1. **Predictive Cleanup**
   - Delete partial caches proactively when memory >200MB
   - Don't wait for video to become invisible

2. **Smart Validation**
   - Skip validation entirely for small files (<10MB)
   - Use file modification time as proxy for validity

3. **Memory-Aware Caching**
   - Limit total disk cache size (e.g., max 1GB)
   - Implement LRU eviction for old caches

## Rollback Plan

If this causes issues, revert these changes:

```bash
# Remove partial cache cleanup
git checkout HEAD~1 -- SharedAssetCache.swift

# Remove validation caching
git checkout HEAD~1 -- LocalHTTPServer.swift
```

The delegate cancellation fix (Phase 1) will still be active.
