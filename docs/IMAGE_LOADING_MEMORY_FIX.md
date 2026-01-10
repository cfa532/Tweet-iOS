# Image Loading Memory Fix

## Problem
When network is slow/unreliable:
- Images fail to load and timeout (8-10s each)
- Retry mechanism schedules retries (3 retries × many images)
- Scheduled retries build up in memory
- Memory consumption reaches 870MB+ and triggers warnings
- App becomes unstable

## Root Causes
1. **Too many concurrent loads**: 8 simultaneous loads × retry queue
2. **Too many retries**: 3 retries per image with short delays (2s, 4s, 6s)
3. **Large pending queue**: 100 images queued
4. **Not aggressive enough cleanup**: Only triggered at 600MB
5. **Scheduled retries not cancelled**: During memory pressure, retries kept running

## Fixes Applied

### 1. Reduced Concurrency
```swift
// Before:
private let maxConcurrentLoads = 8
private let maxQueueSize = 100

// After:
private let maxConcurrentLoads = 6  // Reduced by 25%
private let maxQueueSize = 50       // Reduced by 50%
```

### 2. Reduced Retries & Longer Delays
```swift
// Before: 3 retries with 2s, 4s, 6s delays
// After:  2 retries with 5s, 10s delays

let maxRetries = 2
let delay = Double(newRetryCount) * 5.0  // 5s, 10s
```

### 3. More Aggressive Memory Threshold
```swift
// Before:
private let memoryWarningThreshold = 0.45 // 45%
let isHigh = memoryUsageRatio > 0.45 || memoryUsageMB > 600.0

// After:
private let memoryWarningThreshold = 0.35 // 35%
let isHigh = memoryUsageRatio > 0.35 || memoryUsageMB > 450.0
```

### 4. Cancel Scheduled Retries on Memory Pressure
```swift
// When memory is high, immediately cancel ALL scheduled retries
if isMemoryPressureHigh() {
    print("Cancelling \(scheduledRetries.count) scheduled retries")
    for workItem in scheduledRetries.values {
        workItem.cancel()
    }
    scheduledRetries.removeAll()
    ImageCacheManager.shared.releasePartialCache(percentage: 50)
}
```

### 5. Skip Retry if Memory Pressure Exists
```swift
// Before retry, check memory pressure
if self.isMemoryPressureHigh() {
    print("Skipping retry due to memory pressure")
    self.permanentlyFailedRequests.insert(request.id)
    return
}
```

### 6. Faster Timeout Detection
```swift
// Before: 10s timeout
// After:  8s timeout

urlRequest.timeoutInterval = 8.0
```

### 7. Aggressive Memory Warning Cleanup
On ANY memory warning:
- ✅ Cancel all low/normal priority loads
- ✅ Cancel ALL scheduled retries immediately
- ✅ Clear pending queue (keep only high priority)
- ✅ Clear completed request history
- ✅ Clear retry tracking
- ✅ Clear permanently failed list (allow retry after recovery)
- ✅ Release 70% of image cache

## Impact

### Before:
```
- 8 concurrent loads
- 100 pending queue
- 3 retries × 2s/4s/6s delays
- Memory threshold: 600MB
- Retries kept running during pressure
- Memory usage: 870MB+ → crash
```

### After:
```
- 6 concurrent loads (-25%)
- 50 pending queue (-50%)
- 2 retries × 5s/10s delays (-33% retries, longer delays)
- Memory threshold: 450MB (-25%)
- Retries cancelled during pressure
- Memory usage: Should stay < 450MB
```

## Expected Behavior

### Normal Network:
- Images load normally
- Up to 2 retries on failure
- Memory stays under 450MB

### Poor Network:
- Timeouts fail faster (8s vs 10s)
- Fewer retries (2 vs 3)
- Longer delays between retries (5s, 10s)
- Scheduled retries cancelled when memory high
- Aggressive cleanup on memory warning

### Memory Recovery:
- At 450MB: Cancel retries, release 50% cache
- On warning: Cancel all retries, release 70% cache
- Allows retry after memory recovers

## Testing Recommendations

1. **Poor Network Simulation**:
   - Use Network Link Conditioner
   - Set "Very Bad Network" profile
   - Scroll through feed with many images
   - Monitor memory usage (should stay < 450MB)

2. **Memory Monitoring**:
   - Watch Xcode memory gauge
   - Look for "High memory pressure" logs
   - Verify retries are cancelled
   - Check cleanup logs

3. **Recovery**:
   - After memory warning, verify app recovers
   - Images should retry after cleanup
   - No crashes or freezes

## Logs to Watch

```
🚨 [GlobalImageLoadManager] Memory warning - current usage: XXX MB
🧹 [GlobalImageLoadManager] Performing aggressive cleanup
🧹 [GlobalImageLoadManager] Cancelling X scheduled retries
🧹 [GlobalImageLoadManager] Removed X pending requests
🧹 [GlobalImageLoadManager] Cleared X completed requests
✅ [GlobalImageLoadManager] Cleanup complete
```

## Additional Recommendations

If memory issues persist:
1. Reduce `maxConcurrentLoads` further (to 4)
2. Reduce memory threshold to 400MB
3. Disable retries entirely during poor network
4. Implement network quality detection
5. Add image size limits (max width/height)
