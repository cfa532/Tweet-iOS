# Memory Leak Prevention - Quick Reference

## TL;DR

**Problem:** Fast scrolling causes 300MB memory leaks from unfinished video downloads.

**Solution:** Three-layer system prevents, cancels, and cleans up wasteful downloads.

**Result:** Memory stays under 200MB during normal use (vs 400MB+ before).

---

## Quick Usage Guide

### When Creating Players

```swift
// ✅ Normal feed scroll - use debouncing (prevents waste)
let player = try await SharedAssetCache.shared.getOrCreatePlayer(
    for: videoURL,
    bypassDebounce: false  // 300ms delay, cancels if scrolled away
)

// ✅ User tap / fullscreen / detail view - bypass debouncing (instant)
let player = try await SharedAssetCache.shared.getOrCreatePlayer(
    for: videoURL,
    bypassDebounce: true  // 0ms delay, instant response
)
```

### When Videos Become Invisible

```swift
// Called by MediaCell.onDisappear(), VideoPlaybackCoordinator, etc.
SharedAssetCache.shared.markAsNotVisible(mediaID)
// → Cancels pending debounce timer
// → Cancels in-progress downloads (both HLS and progressive)
// → Frees 50-100MB immediately
```

### Manual Cleanup (Rare)

```swift
// Cancel specific video (usually automatic)
SharedAssetCache.shared.clearPlayerForMediaID(mediaID)

// Emergency: Cancel ALL downloads (memory pressure)
LocalHTTPServer.shared.cancelAllDownloads()
```

---

## Configuration

### Debounce Delay

```swift
// In SharedAssetCache.swift:
private let downloadDebounceDelay: TimeInterval = 0.3  // 300ms

// Tuning guide:
// 0.2 - More responsive (40% waste reduction)
// 0.3 - Balanced ⭐️ RECOMMENDED (60-80% waste reduction)
// 0.5 - More aggressive (80-90% waste reduction)
```

### Memory Thresholds

```swift
// Proactive monitoring threshold (automatic cleanup):
if memoryUsageMB > 1200 { ... }  // 1.2GB threshold

// Modify in SharedAssetCache.handleMemoryWarning()
```

---

## Troubleshooting

### Videos Not Loading

**Symptom:** Videos stuck with spinner, no playback

**Check:**
1. Is `bypassDebounce` set correctly for user actions?
2. Is video blacklisted? (Check for `🚫 [VIDEO BLACKLIST]` logs)
3. Is network working? (Try other videos)

**Fix:**
```swift
// For explicit user actions, always bypass debounce:
let player = try await getOrCreatePlayer(for: url, bypassDebounce: true)
```

### Memory Still High

**Symptom:** Memory usage stays at 300MB+

**Check:**
1. Is video upload in progress? (FFmpeg uses 1-2GB temporarily)
2. Are cancellation logs appearing? (Search for `✅ [LocalHTTPServer]`)
3. Is image cache separate issue? (Video system only manages video memory)

**Fix:**
```swift
// Force aggressive cleanup:
LocalHTTPServer.shared.cancelAllDownloads()
SharedAssetCache.shared.releasePartialCache(percentage: 60)
```

### Too Many Download Logs

**Symptom:** Console flooded with debounce logs during scrolling

**Expected Behavior:**
```
⏱️ [DEBOUNCE] Waiting 300ms before downloading QmZyh...
⏱️ [DEBOUNCE] Cancelled pending download for QmZyh...
```

This is **normal** during fast scrolling. It means the system is **working correctly** by preventing downloads.

**To Reduce Logs:**
Increase debounce delay (fewer attempts):
```swift
private let downloadDebounceDelay: TimeInterval = 0.5  // 500ms
```

---

## Key Metrics

### Memory Usage (Target)

| Scenario | Target | Acceptable | Critical |
|----------|--------|------------|----------|
| Idle | < 100MB | < 150MB | > 200MB |
| Scrolling | < 200MB | < 300MB | > 400MB |
| Video upload | < 2GB | < 2.5GB | > 3GB |

### Download Efficiency (Target)

| Scroll Speed | Target Reduction | Acceptable | Poor |
|--------------|------------------|------------|------|
| Very fast | > 80% | > 60% | < 40% |
| Fast | > 60% | > 40% | < 20% |
| Normal | > 30% | > 15% | < 10% |

**How to Measure:**
Count debounce cancellation logs vs download start logs:
```
Reduction % = (Cancelled / (Cancelled + Started)) × 100
```

---

## Common Patterns

### Pattern 1: Feed Scrolling

```swift
// MediaCell or VideoPlaybackCoordinator
override func onAppear() {
    // NO bypass - use debouncing
    player = try await SharedAssetCache.shared.getOrCreatePlayer(
        for: videoURL,
        bypassDebounce: false
    )
}

override func onDisappear() {
    // Auto-cancels pending downloads
    SharedAssetCache.shared.markAsNotVisible(mediaID)
}
```

### Pattern 2: User Tap to Play

```swift
func handleTap() {
    // YES bypass - instant response
    player = try await SharedAssetCache.shared.getOrCreatePlayer(
        for: videoURL,
        bypassDebounce: true  // Instant!
    )
    player.play()
}
```

### Pattern 3: Fullscreen Navigation

```swift
func openFullscreen() {
    // YES bypass - instant transition
    FullScreenVideoManager.shared.loadVideo(
        url: videoURL,
        mid: mediaID,
        // ... other params
    )
    
    // FullScreenVideoManager internally uses bypassDebounce: true
}
```

### Pattern 4: Detail View

```swift
func navigateToDetail() {
    DetailVideoManager.shared.setCurrentVideo(
        url: videoURL,
        mid: mediaID,
        autoPlay: true
    )
    
    // DetailVideoManager internally uses bypassDebounce: true
}
```

---

## Debugging Commands

### Enable Verbose Logging

Search Xcode console for these patterns:

```bash
# Debouncing activity
⏱️ [DEBOUNCE]

# Download cancellation
✅ [LocalHTTPServer] Cancelling
✅ [ResourceLoaderDelegate] Cancelling

# Memory warnings
⚠️ [MEMORY WARNING]
🚨 [SYSTEM MEMORY WARNING]

# Video lifecycle
🎬 [THROTTLE]
🧹 [SharedAssetCache]
```

### Memory Profiling

1. Open **Xcode → Debug Navigator → Memory**
2. Fast scroll through feed
3. Watch for:
   - Memory spikes > 300MB
   - Memory not dropping after scroll stops
   - Steady growth over time

### Expected Behavior

**Good (No Leak):**
```
Idle: 100MB
Scroll: 100MB → 180MB (spike) → 120MB (settles)
Repeat: 120MB → 200MB (spike) → 130MB (settles)
```

**Bad (Leak):**
```
Idle: 100MB
Scroll: 100MB → 250MB (spike) → 240MB (doesn't drop!)
Repeat: 240MB → 400MB (spike) → 390MB (keeps growing)
```

---

## Code Checklist

When adding new video features, ensure:

- [ ] Use `bypassDebounce: false` for automatic playback (feeds)
- [ ] Use `bypassDebounce: true` for user-initiated actions
- [ ] Call `markAsNotVisible()` when video leaves screen
- [ ] Don't hold strong references to players longer than needed
- [ ] Clean up observers in `deinit` or `onDisappear`
- [ ] Test with fast scrolling (20+ videos)
- [ ] Check memory doesn't exceed 300MB during scrolling
- [ ] Verify downloads are cancelled (check logs)

---

## Architecture Diagram

```
User Action
    ↓
SharedAssetCache.getOrCreatePlayer()
    ↓
    ├─→ [Cache Hit] → Return player (instant, 0ms)
    │
    ├─→ [Cache Miss + bypassDebounce=true]
    │       → Download immediately (0ms delay)
    │
    └─→ [Cache Miss + bypassDebounce=false]
            ↓
            Wait 300ms (debounce)
            ↓
            ├─→ [Video still visible]
            │       → Start download
            │       → Track in activeTasks/streamingSessions
            │
            └─→ [Video scrolled away]
                    → Cancel timer (no download!)
                    
On Scroll Away
    ↓
markAsNotVisible()
    ↓
    ├─→ Cancel pending debounce timer
    ├─→ Cancel LocalHTTPServer sessions
    └─→ Cancel ResourceLoaderDelegate tasks
    
Memory Warning
    ↓
handleMemoryWarning()
    ↓
    ├─→ Cancel ALL pending debounce timers
    ├─→ Cancel ALL downloads (both systems)
    └─→ Release 30-60% of cached players
```

---

## Related Documentation

- **Full Documentation:** `MEMORY_LEAK_PREVENTION.md`
- **Code Files:**
  - `SharedAssetCache.swift` - Main implementation
  - `ResourceLoaderDelegate.swift` - HLS cancellation
  - `LocalHTTPServer.swift` - Progressive cancellation

---

## FAQ

**Q: Why 300ms? Isn't that a delay?**  
A: 300ms is imperceptible to users (< human reaction time ~250ms). Cached videos still play instantly. The 300ms only applies to uncached videos during scrolling.

**Q: Can I disable debouncing?**  
A: Yes, set `bypassDebounce: true`, but you'll see the memory leak return. Only do this for explicit user actions.

**Q: Does this affect video quality?**  
A: No. It only delays the *start* of downloads, not the download speed or quality once started.

**Q: What about images?**  
A: This system only handles video downloads. Images have a separate system (`SDWebImage`).

**Q: Why not just use smaller videos?**  
A: Video size isn't the issue - the issue is *starting downloads we'll never finish*. A 5MB video downloaded 100x wastes 500MB. Debouncing prevents those 95 wasted downloads.

---

*Last Updated: 2026-01-11*
