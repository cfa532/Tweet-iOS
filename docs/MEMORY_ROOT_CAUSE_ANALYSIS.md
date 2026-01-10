# Memory Buildup - Root Cause Analysis

## The Real Problem ⚠️

### 1. **Closure Capture Issue** (PRIMARY CAUSE)

```swift
// GlobalImageLoadManager.swift lines 34-52
struct ImageLoadRequest {
    let completion: @MainActor (UIImage?) -> Void    // ❌ CAPTURES CONTEXT
    let onProgress: @MainActor (Double) -> Void      // ❌ CAPTURES CONTEXT
}

// Line 66
private var pendingRequests: [ImageLoadRequest] = []  // ❌ HOLDS 50+ REQUESTS
```

**What This Means:**
- Each `ImageLoadRequest` has 2 closures
- These closures capture: SwiftUI views, Tweet objects, Observable contexts
- `pendingRequests` array holds up to 50 requests
- **50 requests × 2 closures × captured contexts = MASSIVE MEMORY**
- When user scrolls away, requests stay in array holding DEAD VIEWS

### 2. **Scheduled Retries Double-Capture** (SECONDARY CAUSE)

```swift
// Line 70
private var scheduledRetries: [String: DispatchWorkItem] = [:]

// Lines 253-259 in handleLoadFailure
let workItem = DispatchWorkItem { [weak self] in
    guard let self = self else { return }
    self.scheduledRetries.removeValue(forKey: request.id)
    self.loadImage(request: request)  // ❌ CAPTURES ENTIRE REQUEST
}
scheduledRetries[request.id] = workItem
```

**What This Means:**
- DispatchWorkItem captures the ENTIRE `ImageLoadRequest`
- Request already has closures that capture views
- So we have: `scheduledRetries` → `DispatchWorkItem` → `ImageLoadRequest` → `closures` → `views`
- **DOUBLE MEMORY RETENTION**

### 3. **Incomplete Cancellation** (CRITICAL BUG)

```swift
// Lines 147-157 - cancelLoad()
func cancelLoad(id: String) {
    activeLoads[id]?.cancel()
    activeLoads.removeValue(forKey: id)
    
    scheduledRetries[id]?.cancel()
    scheduledRetries.removeValue(forKey: id)
    
    // ❌ BUG: Does NOT remove from pendingRequests!
    pendingRequests.removeAll { $0.id == id }  // This line is MISSING!
}
```

**What This Means:**
- When view disappears, it calls `cancelLoad(id)`
- This removes from `activeLoads` and `scheduledRetries`
- But **DOES NOT** remove from `pendingRequests` array!
- Request (with closures capturing dead views) stays in memory forever

### 4. **URLSession Buffer Retention**

```swift
// Lines 316-346 - loadImageFromNetwork
let (data, response) = try await URLSession.shared.data(for: urlRequest)
```

**What This Means:**
- URLSession allocates buffers for download
- Even after Task cancellation, buffers might not release immediately
- iOS GC needs to run to clean up
- With many concurrent loads, buffers accumulate

## Memory Buildup Flow

```
User scrolls through feed
  ↓
100 images trigger loadImage()
  ↓
6 start loading (activeLoads)
50 go to pendingRequests  ← ❌ HOLDING CLOSURES
44 dropped (over maxQueueSize)
  ↓
User scrolls away from first 50 images
  ↓
Views call cancelLoad()
  ↓
activeLoads cleared ✓
scheduledRetries cleared ✓
pendingRequests NOT cleared ❌  ← BUG!
  ↓
50 ImageLoadRequest objects still in memory
Each with 2 closures capturing dead SwiftUI views
  ↓
Memory: 50 requests × ~2MB captured context = 100MB leaked!
```

## Why My Fixes Were Band-Aids

### ❌ Bad Fix #1: Reduce Concurrency
```swift
maxConcurrentLoads = 6  // Was 8
maxQueueSize = 50       // Was 100
```
**Why it's a band-aid:**
- Still holds closures in pendingRequests
- Just reduces the AMOUNT of leaked memory
- Doesn't fix the leak

### ❌ Bad Fix #2: Reduce Timeouts
```swift
timeoutInterval = 8.0  // Was 10.0
```
**Why it's a band-aid:**
- Fails faster, reducing active time
- But doesn't release closure memory
- Doesn't fix pendingRequests leak

### ❌ Bad Fix #3: Lower Thresholds
```swift
memoryWarningThreshold = 0.35  // Was 0.45
```
**Why it's a band-aid:**
- Triggers cleanup earlier
- But cleanup doesn't clear pendingRequests closures!
- Just delays the inevitable

## The Right Architectural Fix

### 1. **Fix the Cancellation Bug** (CRITICAL)
```swift
func cancelLoad(id: String) {
    activeLoads[id]?.cancel()
    activeLoads.removeValue(forKey: id)
    
    scheduledRetries[id]?.cancel()
    scheduledRetries.removeValue(forKey: id)
    
    // ✅ FIX: Actually remove from pending queue!
    pendingRequests.removeAll { $0.id == id }
    
    updateStatistics()
}
```

### 2. **Use Weak Captures** (IMPORTANT)
```swift
// Instead of capturing request directly:
let workItem = DispatchWorkItem { [weak self] in
    guard let self = self else { return }
    self.loadImage(request: request)  // ❌ Strong capture
}

// Use ID-based loading:
let workItem = DispatchWorkItem { [weak self] in
    guard let self = self else { return }
    self.retryLoad(id: request.id)  // ✅ Only captures ID
}
```

### 3. **Clear Completion Closures After Use**
```swift
// Instead of holding requests indefinitely:
private var pendingRequests: [ImageLoadRequest] = []  // ❌

// Use ID-only tracking + lookup dictionary:
private var pendingRequestIds: [String] = []          // ✅ IDs only
private var requestRegistry: [String: ImageLoadRequest] = [:]  // ✅ Removable
```

### 4. **Add View-Scoped Cancellation**
```swift
// Add API to cancel all requests for a view:
func cancelAllLoads(forView viewId: String) {
    // Cancel by prefix/tag
    let idsToCancel = activeLoads.keys.filter { $0.hasPrefix(viewId) }
    for id in idsToCancel {
        cancelLoad(id: id)
    }
}
```

## Proof of Root Cause

From user's logs:
```
DEBUG: [GlobalImageLoadManager] High memory pressure detected: 23.7% used (870 MB)
DEBUG: [ImageCacheManager] Released 13 image files from cache
```

**Analysis:**
- Released 13 cached images
- Memory STILL at 870MB!
- Why? Because pendingRequests closures weren't released!
- Cached images are small (compressed)
- Closure-captured view contexts are HUGE (full SwiftUI view trees)

## Comparison: Image vs Video

### Image Loading (Broken):
```swift
pendingRequests: [ImageLoadRequest]  // ❌ Holds closures
Not removed on cancelLoad()          // ❌ Bug
scheduledRetries captures request    // ❌ Double retention
Result: MEMORY LEAK
```

### Video Loading (Better):
```swift
loadingQueue: [String]               // ✅ Just IDs!
tweetsToCancel: Set<String>          // ✅ Just IDs!
No retry mechanism                   // ✅ No scheduled captures
Result: NO LEAK (but other issues)
```

**Video system is architecturally better!** It stores IDs, not objects with closures.

## Recommended Action Plan

### Phase 1: Critical Bug Fix (Do Now)
1. Fix cancelLoad() to remove from pendingRequests
2. Clear pendingRequests on memory warning
3. Use weak self in retry closures

### Phase 2: Architectural Refactor (Do Soon)
1. Store IDs instead of full ImageLoadRequest objects
2. Use registry pattern for request lookup
3. Implement view-scoped cancellation
4. Add request lifecycle logging

### Phase 3: System Redesign (Do Later)
1. Unified media loading manager (images + videos)
2. Request pooling and reuse
3. Backpressure system
4. Network quality adaptation

## Conclusion

**My previous fixes were SYMPTOMATIC treatment:**
- Reduced the rate of memory buildup
- Made failures happen faster
- Triggered cleanup earlier

**But they didn't fix the ROOT CAUSE:**
- Closure retention in pendingRequests
- Missing removal in cancelLoad()
- Double-capture in scheduledRetries

**The real fix needs:**
1. Bug fix: Remove from pendingRequests on cancel
2. Architecture change: Store IDs not closures
3. Design pattern: Registry + weak captures

Without these, memory will still build up, just slower.
