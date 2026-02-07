# BlackList Integration for Images and Videos

## Summary
Integrated existing `BlackList.swift` system with image and video loading to prevent wasting resources on repeatedly failed media.

## Problem
The `BlackList` system existed and was being used for tweets and users, but **not for images and videos**. This meant:
- Failed images kept retrying across sessions
- Failed videos wasted bandwidth repeatedly
- No persistent tracking of bad media resources
- Memory and network wasted on known-broken files

## Solution
Integrated `BlackList.shared` into both `GlobalImageLoadManager` and `SharedAssetCache`.

## How BlackList Works

### Smart Failure Tracking:
```
Resource fails
    ↓
Added to candidates (first failure)
    ↓
Fails again → increment counter
    ↓
After 14+ failures over 1+ week
    ↓
Moved to permanent blacklist
    ↓
Never tried again
```

### Persistence:
- Saves to UserDefaults (local)
- Mirrors to iCloud (backup)
- Survives app reinstall
- Syncs across devices

## Integration Points

### 1. Images (GlobalImageLoadManager)

#### Check Before Loading:
```swift
func loadImage(request: ImageLoadRequest) {
    let mediaID = MimeiId(request.attachment.mid)
    
    // ✅ Check blacklist first
    if BlackList.shared.isBlacklisted(mediaID) {
        print("🚫 [IMAGE BLACKLIST] Skipping: \(mediaID)")
        request.completion(nil)  // Update UI
        return
    }
    
    // ... proceed with load
}
```

#### Record Results:
```swift
if let image = image {
    // ✅ Success
    BlackList.shared.recordSuccess(mediaID)
    request.completion(image)
} else {
    // ❌ Failure
    BlackList.shared.recordFailure(mediaID)
    request.completion(nil)
}
```

### 2. Videos (SharedAssetCache)

#### Check Before Loading:
```swift
func getOrCreatePlayer(for url: URL, ...) async throws -> AVPlayer {
    let mediaID = extractMediaID(from: url)
    let mimeiId = MimeiId(mediaID)
    
    // ✅ Check blacklist first
    if BlackList.shared.isBlacklisted(mimeiId) {
        print("🚫 [VIDEO BLACKLIST] Skipping: \(mediaID)")
        throw NSError(..., "Video is blacklisted")
    }
    
    // ... proceed with player creation
}
```

#### Record Results:
```swift
// HLS Videos:
do {
    let player = try await createCachingPlayerWithRetry(...)
    // ✅ Success
    BlackList.shared.recordSuccess(MimeiId(mediaID))
    return player
} catch {
    // ❌ Failure
    BlackList.shared.recordFailure(MimeiId(mediaID))
    throw error
}

// Progressive Videos:
do {
    let player = try await createProgressivePlayerWithRetry(...)
    // ✅ Success
    BlackList.shared.recordSuccess(MimeiId(mediaID))
    return player
} catch {
    // ❌ Failure
    BlackList.shared.recordFailure(MimeiId(mediaID))
    throw error
}
```

## Blacklist Lifecycle

### Resource Failure Timeline:
```
Day 1:    Fail #1  → Added to candidates
Day 2:    Fail #2  → Counter: 2
Day 3:    Fail #3  → Counter: 3
...
Day 7:    Fail #10 → Counter: 10 (still candidate)
Day 8:    Fail #14 → Counter: 14
          ↓
          1 week old + 14 failures
          ↓
          MOVED TO BLACKLIST
          ↓
          Never tried again
```

### Success Removes from Candidates:
```
Fail #1   → Added to candidates
Fail #2   → Counter: 2
Success!  → Removed from candidates ✓
```

### Blacklisted Resources Never Retry:
```
Blacklisted resource
    ↓
isBlacklisted() = true
    ↓
Skip load entirely
    ↓
Call completion(nil) immediately
    ↓
No network request
    ↓
No memory usage
    ↓
No retry attempts
```

## Benefits

### 1. Network Savings:
```
Without Blacklist:
- Failed image retries 2 times per view
- User scrolls past 100 tweets
- 10 images permanently broken
- 10 images × 2 retries × 100 views = 2,000 wasted requests!

With Blacklist:
- Failed image retries 2 times initially
- After 14 failures over 1 week → blacklisted
- Future views: 0 requests
- Savings: 1,986 requests! (99.3%)
```

### 2. Memory Savings:
```
Without Blacklist:
- Each failed request in pendingRequests
- Closure captures 2MB context
- 10 bad images × 2MB = 20MB leaked

With Blacklist:
- Skip load immediately
- No pendingRequests entry
- No closure capture
- 0MB leaked
```

### 3. User Experience:
```
Without Blacklist:
- User sees loading spinner
- Waits 8 seconds
- Sees error
- Next view: spinner again
- Repeat forever

With Blacklist:
- First 14 tries: spinner
- After blacklist: instant skip
- No waiting
- No false hope
```

### 4. Persistence:
```
Scenario: User reinstalls app

Without Persistence:
- All failure history lost
- Bad resources tried again
- Waste network/memory again

With BlackList (UserDefaults + iCloud):
- History restored
- Bad resources still blacklisted
- No wasted resources
```

## Monitoring

### Get Statistics:
```swift
let stats = BlackList.shared.getStats()
print("Candidates: \(stats.candidates)")
print("Blacklisted: \(stats.blacklisted)")
```

### Logs to Watch:
```
[BlackList] Added <mediaID> to candidates after first failure
[BlackList] Resource <mediaID> failed 5 times since <date>
[BlackList] Moving <mediaID> to blacklist after 14 failures
[BlackList] Permanently blacklisted <mediaID> - will never be tried again
🚫 [IMAGE BLACKLIST] Skipping blacklisted image: <mediaID>
🚫 [VIDEO BLACKLIST] Skipping blacklisted video: <mediaID>
[BlackList] Removed <mediaID> from candidates after successful access
```

## Files Modified

1. **GlobalImageLoadManager.swift**
   - Added blacklist check in `loadImage()`
   - Record success/failure in `startLoading()`

2. **SharedAssetCache.swift**
   - Added blacklist check in `getOrCreatePlayer()`
   - Record success/failure for HLS videos
   - Record success/failure for progressive videos

3. **BlackList.swift** (No changes)
   - Already had perfect implementation
   - Already persistent
   - Already thread-safe

## Testing

### Test Image Blacklist:
```swift
1. Find broken image URL
2. Scroll past it 14 times over 1+ week
3. Watch logs for "Moving to blacklist"
4. Scroll past again
5. Should see "Skipping blacklisted image"
6. No network request made
```

### Test Video Blacklist:
```swift
1. Find broken video URL
2. Try to play 14 times over 1+ week
3. Watch logs for "Moving to blacklist"
4. Try to play again
5. Should see "Skipping blacklisted video"
6. Immediate error, no network request
```

### Test Persistence:
```swift
1. Blacklist a resource
2. Force quit app
3. Restart app
4. Try to load same resource
5. Should still be blacklisted
6. Should see "Loaded X blacklisted items from UserDefaults"
```

### Test Success Removal:
```swift
1. Resource fails 3 times
2. Should be in candidates
3. Resource succeeds
4. Should be removed from candidates
5. Check: getStats().candidates should decrease
```

## Why This Works

### No Duplication:
- One `BlackList.swift` for ALL resources
- Tweets, Users, Images, Videos all use same system
- Consistent thresholds (14 failures, 1 week)
- Single source of truth

### Proper Architecture:
- Thread-safe (DispatchQueue)
- Memory-efficient (stores IDs only)
- Persistent (UserDefaults + iCloud)
- Smart thresholds (not too aggressive)

### Integration Points:
- Check BEFORE loading (early exit)
- Record AFTER attempt (success/failure)
- No changes to BlackList.swift needed
- Just wire up existing API

## Comparison with Other Approaches

### ❌ Bad Approach (What I Almost Did):
```swift
private var imageBlacklist: [String: Date] = [:]  // Duplicate!
private var videoBlacklist: [String: Date] = [:]  // Duplicate!
```
**Problems:**
- Duplicate code
- Different thresholds
- No persistence
- Not thread-safe

### ✅ Good Approach (What We Did):
```swift
BlackList.shared.isBlacklisted(mediaID)  // Reuse existing!
```
**Benefits:**
- Single implementation
- Consistent thresholds
- Already persistent
- Already thread-safe

## Key Takeaway

**Don't reinvent the wheel!**
- Search codebase first
- Reuse existing systems
- Follow established patterns
- Integrate, don't duplicate

The `BlackList` system was already perfect. We just needed to wire it up to images and videos. This is proper software engineering! ✅
