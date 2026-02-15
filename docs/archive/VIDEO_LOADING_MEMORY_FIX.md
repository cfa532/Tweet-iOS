# Video Loading Memory Fix

## Problem
Video loading system had **WORSE** settings than image loading:
- **8 concurrent loads** (vs 6 for images after fix)
- **15 second timeouts** (vs 8s for images)
- **1.2GB memory threshold** (vs 450MB for images)
- Long-running video loads building up during network issues

## Issues Found

### 1. Too Many Concurrent Loads
```swift
// VideoLoadingManager.swift - BEFORE
private let maxConcurrentLoads: Int = 8  // Same as old image loading!
```
- 8 concurrent video loads = massive memory usage
- Videos are much larger than images
- During network issues, all 8 slots filling with stalled loads

### 2. Very Long Timeouts
```swift
// SharedAssetCache.swift - BEFORE
timeout: TimeInterval = 15.0  // 15 seconds per HLS check!
```
- Each video checks 2 URLs (master.m3u8, playlist.m3u8)
- Total potential timeout: 15s × 2 = 30 seconds per video
- With 8 concurrent: 8 videos × 30s = massive buildup

### 3. High Memory Threshold
```swift
// SharedAssetCache.swift - BEFORE
if memoryUsageMB > 1200 {  // 1.2GB threshold!
```
- Cleanup only triggered at 1.2GB
- User's logs showed 870MB already problematic
- Threshold too high for devices with poor network

### 4. No Retry Logic
- Good: Won't build up scheduled retries like images
- Bad: Videos that fail during load never retry
- User must manually refresh to try again

## Fixes Applied

### 1. Reduced Concurrent Loads (50% Reduction!)
```swift
// BEFORE:
private let maxConcurrentLoads: Int = 8

// AFTER:
private let maxConcurrentLoads: Int = 4  // Reduced by 50%
```

### 2. Faster Timeouts (47% Reduction!)
```swift
// BEFORE:
timeout: TimeInterval = 15.0  // 15s × 2 URLs = 30s total

// AFTER:
timeout: TimeInterval = 8.0   // 8s × 2 URLs = 16s total
```

### 3. Lower Memory Threshold (33% Reduction!)
```swift
// BEFORE:
if memoryUsageMB > 1200 {  // 1.2GB
    print("Over 1.2GB - moderate cleanup")
}
else if memoryUsageMB > 1000 {  // 1GB
    print("Approaching limit")
}

// AFTER:
if memoryUsageMB > 800 {   // 800MB
    print("Over 800MB - moderate cleanup")
}
else if memoryUsageMB > 600 {  // 600MB
    print("Approaching limit")
}
```

## Impact Comparison

### Before:
```
Video Loading:
- 8 concurrent loads
- 15s timeout × 2 URLs = 30s total
- Memory threshold: 1.2GB
- Cleanup at: 1.2GB

Image Loading:
- 8 concurrent loads
- 10s timeout
- Memory threshold: 600MB
- Retry buildup: YES

Result: BOTH systems causing memory issues!
```

### After:
```
Video Loading:
- 4 concurrent loads (-50%)
- 8s timeout × 2 URLs = 16s total (-47%)
- Memory threshold: 800MB (-33%)
- Cleanup at: 800MB

Image Loading:
- 6 concurrent loads (-25%)
- 8s timeout (-20%)
- Memory threshold: 450MB (-25%)
- Retry buildup: FIXED

Result: Both systems conservative and coordinated!
```

## Expected Behavior

### Normal Network:
- Videos load normally with 4 concurrent
- 8s timeout per HLS URL check (fast failure)
- Memory stays under 800MB

### Poor Network:
- Maximum 4 videos loading at once (vs 8)
- Fails faster: 16s total (vs 30s)
- Cleanup triggers at 800MB (vs 1.2GB)
- Combined with image fixes: stable operation

### Memory Management:
```
600MB:  Warning log "Approaching limit"
800MB:  Trigger cleanup (cancel loads, release 30% cache)
System: Aggressive cleanup on iOS memory warning
```

## Combined Image + Video Fixes

Total concurrent network operations reduced:
- **Before**: 8 images + 8 videos = 16 concurrent
- **After**: 6 images + 4 videos = 10 concurrent (-38%)

Total memory thresholds:
- **Before**: 600MB (images) + 1.2GB (videos) = inconsistent
- **After**: 450MB (images) + 800MB (videos) = coordinated

## Files Modified

1. **VideoLoadingManager.swift**
   - Reduced `maxConcurrentLoads` from 8 to 4

2. **SharedAssetCache.swift**
   - Reduced timeout from 15s to 8s (3 locations)
   - Reduced memory threshold from 1.2GB to 800MB
   - Reduced warning threshold from 1GB to 600MB

## Testing Recommendations

1. **Poor Network + Many Videos**:
   - Use Network Link Conditioner
   - Set "Very Bad Network" profile
   - Scroll through feed with many videos
   - Monitor memory usage (should stay < 800MB)

2. **Memory Monitoring**:
   - Watch Xcode memory gauge
   - Look for "Over 800MB" cleanup logs
   - Verify only 4 videos load concurrently
   - Check timeout failures occur at 8s (not 15s)

3. **Combined Load**:
   - Feed with mixed images and videos
   - Total concurrent should be ≤ 10 (6 images + 4 videos)
   - Memory should stay < 800MB
   - Both systems should cleanup together

## Logs to Watch

```
📊 [MEMORY] Approaching limit: 600MB (monitoring)
⚠️ [MEMORY] High usage: 800MB (>800MB) - triggering cleanup
🗑️ [MEMORY WARNING] Over 800MB - moderate cleanup
✅ [MEMORY WARNING] Cleanup complete - released 30% of cache
🚨 [SYSTEM MEMORY WARNING] iOS sent memory warning - aggressive cleanup
```

## Additional Recommendations

If memory issues persist:
1. Reduce video `maxConcurrentLoads` to 3
2. Reduce memory threshold to 600MB
3. Increase cleanup percentage from 30% to 40%
4. Consider adding retry logic with long delays (5-10s)
5. Implement network quality detection to disable video preload

## Why Videos More Critical Than Images

1. **Size**: Video segments 100KB-1MB vs images 50-200KB
2. **Buffering**: AVPlayer buffers ahead, images load once
3. **Multiple requests**: HLS checks 2 URLs + segments
4. **Memory retention**: Video player cache held longer
5. **Impact**: One stalled video = memory of 10+ images

Therefore, video system needed **more aggressive** limits than images!
