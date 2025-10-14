# Memory Management System

**Last Updated:** October 14, 2025  
**Status:** Active

## Overview

The Tweet iOS app implements a comprehensive multi-layered memory management system to prevent OS termination while maintaining optimal performance. The system manages memory across videos, images, avatars, tweets, and chat data with intelligent caching and cleanup strategies.

## Table of Contents

1. [System Architecture](#system-architecture)
2. [Memory Managers](#memory-managers)
3. [Cache Keys & Stability](#cache-keys--stability)
4. [Memory Limits & Thresholds](#memory-limits--thresholds)
5. [Cleanup Strategies](#cleanup-strategies)
6. [Avatar Loading Throttling](#avatar-loading-throttling)
7. [Best Practices](#best-practices)

---

## System Architecture

### Memory Management Layers

```
┌─────────────────────────────────────────────────────────────┐
│                     iOS System Memory Warning                │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Memory Warning Coordination Layer               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         MemoryWarningManager (Coordinator)            │  │
│  │  - Receives system warnings                           │  │
│  │  - Only acts if usage > 1GB                          │  │
│  │  - Prevents false alarm cleanup                       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Active Monitoring & Cap Enforcement             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │    MemoryCapManager (2 instances - synchronized)     │  │
│  │  - Core/MemoryCapManager.swift                       │  │
│  │  - CachingPlayerItem/MemoryCapManager.swift          │  │
│  │  - 2GB hard cap enforcement                          │  │
│  │  - Continuous monitoring (every 5 seconds)           │  │
│  │  - 70%/85%/95% tiered thresholds                     │  │
│  │  - Only cleanup if usage > 1GB on warnings          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                   Domain-Specific Managers                   │
│  ┌────────────────┬──────────────────┬──────────────────┐  │
│  │ Video Cache    │  Image Cache     │   Data Cache     │  │
│  ├────────────────┼──────────────────┼──────────────────┤  │
│  │SharedAssetCache│ImageCacheManager │TweetCacheManager │  │
│  │- AVPlayer cache│- Avatar throttle │- Tweet objects   │  │
│  │- AVAsset cache │- Image compress  │- User objects    │  │
│  │- HLS playlists │- Disk cache      │- Core Data       │  │
│  │- Preload queue │- Memory cache    │                  │  │
│  │                │                  │ChatCacheManager  │  │
│  │                │GlobalImageLoad   │- Chat messages   │  │
│  │                │- Priority queue  │- Session data    │  │
│  │                │- Concurrency(8)  │                  │  │
│  └────────────────┴──────────────────┴──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Memory Managers

### 1. MemoryWarningManager
**Location:** `Sources/Core/MemoryWarningManager.swift`

**Responsibilities:**
- Receives iOS system memory warnings
- Acts as first-line coordinator
- **Only responds if memory > 1GB** (prevents false alarm cleanup)

**Threshold:**
```swift
if memoryUsageMB > 1024 {
    // Release 20% of caches (gentle cleanup)
    SharedAssetCache.shared.releasePartialCache(percentage: 20)
    ImageCacheManager.shared.releasePartialCache(percentage: 20)
}
```

**Key Feature:** Ignores false positive warnings from iOS at low memory usage (~100MB).

---

### 2. MemoryCapManager
**Locations:** 
- `Sources/Core/MemoryCapManager.swift`
- `Sources/CachingPlayerItem/MemoryCapManager.swift`

**Responsibilities:**
- Enforces 2GB hard memory cap
- Continuous active monitoring (every 5 seconds)
- Tiered cleanup based on thresholds
- **Only responds to system warnings if memory > 1.4GB**

**Configuration:**
```swift
private let maxMemoryLimit: UInt64 = 2 * 1024 * 1024 * 1024  // 2GB
private let warningThreshold: Double = 0.70   // 70% = 1.4GB
private let criticalThreshold: Double = 0.85  // 85% = 1.7GB  
private let emergencyThreshold: Double = 0.95 // 95% = 1.9GB
```

**Cleanup Tiers:**

| Threshold | Action | Video Cache | Image Cache | Tweet Cache | Chat Cache |
|-----------|--------|-------------|-------------|-------------|------------|
| 70% (1.4GB) | Preventive | 30% release | Old cleanup | - | - |
| 85% (1.7GB) | Aggressive | 60% release | Old cleanup | Clear | Clear |
| 95% (1.9GB) | Emergency | 80% release | Old cleanup | Clear | Clear + VideoStateCache |

**System Warning Handling:**
```swift
@objc private func handleMemoryWarning() {
    let memoryUsageMB = currentMemoryUsage / (1024 * 1024)
    
    if memoryUsageMB > 1400 {  // 1.4GB - aligned with preventive threshold
        // Only cleanup if actually high usage
        forceMemoryCleanup()
    } else {
        // Ignore false alarm (e.g., 100MB usage)
        logger.info("Memory usage under 1.4GB, ignoring system warning")
    }
}
```

---

### 3. SharedAssetCache
**Location:** `Sources/Core/SharedAssetCache.swift`

**Responsibilities:**
- AVPlayer and AVAsset lifecycle management
- HLS playlist caching
- Video preload queue management
- LRU (Least Recently Used) eviction

**Key Features:**
- **Cache Keys:** Uses stable `mediaID` (IPFS hash), NOT URLs
- **Preload Tasks:** Throttled and deduplicated by `mediaID`
- **Memory Warning:** Only acts if > 1.4GB

**Caching Strategy:**
```swift
// Player Cache (per tweet/mode)
playerCache[tweetId ?? mediaID] = player

// Asset Cache (shared)
assetCache[mediaID] = asset

// Preload Tasks (deduplicated)
preloadTasks[mediaID] = task
```

**Partial Release:**
```swift
func releasePartialCache(percentage: Int) {
    // Sort by last access time (LRU)
    let sortedAssets = assetCache.sorted { 
        cacheTimestamps[$0.key] ?? .distantPast < 
        cacheTimestamps[$1.key] ?? .distantPast 
    }
    
    // Remove oldest percentage
    let countToRemove = (assetCache.count * percentage) / 100
    // ... remove and pause players
}
```

---

### 4. ImageCacheManager
**Location:** `Sources/Core/ImageCacheManager.swift`

**Responsibilities:**
- Image memory cache (NSCache)
- Image disk cache (compressed to ~300KB)
- Avatar loading throttling (NEW)
- Old cache cleanup

**Configuration:**
```swift
cache.countLimit = 100               // Max 100 images in memory
cache.totalCostLimit = 50 * 1024 * 1024  // 50MB memory limit
maxDiskCacheSize = 500 * 1024 * 1024     // 500MB disk limit
maxCompressedImageSize = 300 * 1024      // 300KB per image
```

**Cache Keys:**
```swift
private func getCacheKey(for attachment: MimeiFileType, baseUrl: URL) -> String {
    if !attachment.mid.isEmpty {
        return attachment.mid  // ✅ Stable IPFS hash
    }
    
    // Fallback (logs warning)
    print("WARNING: MimeiFileType has empty mid!")
    return url.lastPathComponent  // ⚠️ Unstable
}
```

**Avatar Throttling (NEW):**
```swift
private let maxConcurrentAvatarLoads = 4
private var activeAvatarLoads: [String: Task<UIImage?, Never>] = [:]
private var pendingAvatarRequests: [...] = []

func loadAndCacheAvatar(from url: URL, ...) async -> UIImage? {
    // Check cache first
    if let cached = getCompressedImage(...) { return cached }
    
    // Throttle concurrent loads
    if activeAvatarLoads.count < maxConcurrentAvatarLoads {
        return await startAvatarLoad(...)
    } else {
        // Queue request
        return await withCheckedContinuation { ... }
    }
}
```

---

### 5. GlobalImageLoadManager
**Location:** `Sources/Core/GlobalImageLoadManager.swift`

**Responsibilities:**
- Global image loading coordination
- Priority queue management
- Concurrency control (max 8 concurrent)
- Request deduplication

**Configuration:**
```swift
private let maxConcurrentLoads = 8
private let maxQueueSize = 100
```

**Priority Levels:**
```swift
enum ImageLoadingPriority: Int {
    case low = 0        // Preloading
    case normal = 1     // Grid thumbnails
    case high = 2       // Visible images
    case critical = 3   // User interaction
}
```

**Memory Warning:** Only acts if > 1GB

---

### 6. TweetCacheManager
**Location:** `Sources/Core/TweetCacheManager.swift`

**Responsibilities:**
- Tweet object memory cache
- User object memory cache
- Core Data persistence
- Cache expiration (30 minutes)

**Strategy:**
```swift
func clearMemoryCache() {
    // Clear in-memory caches only
    // Core Data persists to disk
}
```

---

### 7. ChatCacheManager
**Location:** `Sources/Core/ChatCacheManager.swift`

**Responsibilities:**
- Chat message memory cache
- Chat session data
- Core Data persistence

---

## Cache Keys & Stability

### ✅ Correct: Stable Identifiers

All caching now uses **stable identifiers** that don't change when servers/URLs change:

| Resource | Cache Key | Example | Why Stable |
|----------|-----------|---------|------------|
| **Videos** | `mediaID` (IPFS hash) | `QmXyZ123...` | Extracted from URL, content-addressable |
| **Images** | `attachment.mid` | `QmAbc456...` | IPFS hash from server |
| **Avatars** | `user.avatar` | `QmDef789...` | User's avatar MimeiId |
| **Tweets** | `tweet.mid` | `ikJwDEsob7H...` | Tweet's unique ID |
| **Users** | `user.mid` | `iFG4GC9r0fF...` | User's unique ID |

### ❌ Incorrect: URL-Based Keys (Fixed)

**Before (Wrong):**
```swift
// Avatar - WRONG ❌
let cacheKey = URL(string: urlString)?.lastPathComponent
// "avatar_abc123.jpg" - breaks when URL changes

// Video Preload - WRONG ❌  
let cacheKey = url.absoluteString
// "http://192.168.1.1/ipfs/Qm..." - breaks when server changes
```

**After (Fixed):**
```swift
// Avatar - CORRECT ✅
let cacheKey = user.avatar ?? url.lastPathComponent
// "QmXyZ..." - stable MimeiId

// Video Preload - CORRECT ✅
let cacheKey = tweetId ?? mediaID  
// "QmXyZ..." - stable mediaID
```

### Benefits of Stable Keys

1. **Cache survives server changes** - Switching servers doesn't invalidate cache
2. **Better deduplication** - Same content = same key = single cache entry
3. **Offline resilience** - Cached content accessible regardless of current server
4. **Reduced network usage** - No re-downloads when server IP changes

---

## Memory Limits & Thresholds

### Hard Limits

| Component | Memory Limit | Disk Limit | Notes |
|-----------|--------------|------------|-------|
| **App Total** | 2GB | - | Hard cap enforced by MemoryCapManager |
| **Image Memory Cache** | 50MB | 500MB | NSCache auto-evicts under pressure |
| **Image Count** | 100 images | - | NSCache limit |
| **Video Assets** | Dynamic | - | LRU eviction |
| **Video Players** | Dynamic | - | LRU eviction |

### Warning Thresholds

| Usage | Percentage | Bytes | Action Taken |
|-------|------------|-------|--------------|
| Normal | < 70% | < 1.4GB | No action |
| Warning | 70-85% | 1.4-1.7GB | Preventive cleanup (30%) |
| Critical | 85-95% | 1.7-1.9GB | Aggressive cleanup (60%) |
| Emergency | > 95% | > 1.9GB | Emergency cleanup (80%) |

### System Warning Handling

**All managers now check actual usage before cleanup:**

```swift
if memoryUsageMB > 1024 {
    // Actually high - cleanup needed
    performCleanup()
} else {
    // False alarm - ignore
    logger.info("Memory usage under 1GB, ignoring warning")
}
```

This prevents unnecessary cleanup at startup when iOS sends false positive warnings at ~100MB usage.

---

## Cleanup Strategies

### 1. Preventive Cleanup (70% threshold)

**Goal:** Prevent reaching critical levels

**Actions:**
- Release 30% of video cache (oldest first)
- Clean old image files (>7 days)
- Keep all memory caches intact

```swift
private func performPreventiveCleanup() {
    SharedAssetCache.shared.releasePartialCache(percentage: 30)
    ImageCacheManager.shared.cleanupOldCache()
}
```

### 2. Aggressive Cleanup (85% threshold)

**Goal:** Rapidly reduce memory to safe levels

**Actions:**
- Release 60% of video cache
- Clean old image files
- Clear tweet memory cache
- Clear chat memory cache
- Keep disk caches intact

```swift
private func performAggressiveCleanup() {
    SharedAssetCache.shared.releasePartialCache(percentage: 60)
    ImageCacheManager.shared.cleanupOldCache()
    TweetCacheManager.shared.clearMemoryCache()
    ChatCacheManager.shared.clearMemoryCache()
}
```

### 3. Emergency Cleanup (95% threshold)

**Goal:** Enforce 2GB hard cap at all costs

**Actions:**
- Release 80% of video cache
- Clean all old images
- Clear ALL memory caches
- Clear video state cache
- Force garbage collection

```swift
private func performEmergencyCleanup() {
    SharedAssetCache.shared.releasePartialCache(percentage: 80)
    ImageCacheManager.shared.cleanupOldCache()
    TweetCacheManager.shared.clearMemoryCache()
    ChatCacheManager.shared.clearMemoryCache()
    VideoStateCache.shared.clearAllCache()
    
    // Force ARC cleanup
    autoreleasepool { }
}
```

### 4. Background Cleanup

**Trigger:** App enters background

**Actions:**
- Release 50% of video cache
- Clean old images
- Clear tweet cache
- Clear chat cache

### 5. LRU (Least Recently Used) Eviction

**Used by:** SharedAssetCache, ImageCacheManager

**Strategy:**
```swift
// Sort by last access time
let sorted = cache.sorted { 
    timestamps[$0.key] ?? .distantPast < 
    timestamps[$1.key] ?? .distantPast 
}

// Remove oldest entries first
for (key, _) in sorted.prefix(countToRemove) {
    cache.removeValue(forKey: key)
}
```

---

## Avatar Loading Throttling

**Problem Solved:** Network congestion when loading many avatars in user lists

**Solution:** Dedicated throttling system in `ImageCacheManager`

### Configuration

```swift
private let maxConcurrentAvatarLoads = 4  // Max parallel avatar requests
```

### Flow

```
User List View with 20 users
         ↓
┌────────────────────────────────────┐
│    Request 20 avatars              │
└────────────────────────────────────┘
         ↓
┌────────────────────────────────────┐
│  Check cache for each (instant)    │
│  ✓ 5 found in cache → display      │
│  ✗ 15 need network load            │
└────────────────────────────────────┘
         ↓
┌────────────────────────────────────┐
│  Start first 4 network loads       │
│  Queue remaining 11                │
└────────────────────────────────────┘
         ↓
┌────────────────────────────────────┐
│  As each completes:                │
│  - Display loaded avatar           │
│  - Start next queued load          │
└────────────────────────────────────┘
```

### Implementation

```swift
func loadAndCacheAvatar(from url: URL, ...) async -> UIImage? {
    let cacheKey = getCacheKey(for: attachment, baseUrl: baseUrl)
    
    // 1. Check memory cache (instant)
    if let cached = getCompressedImage(...) {
        return cached
    }
    
    // 2. Check if already loading (deduplicate)
    if let existingTask = activeAvatarLoads[cacheKey] {
        return await existingTask.value
    }
    
    // 3. Check concurrency limit
    if activeAvatarLoads.count < maxConcurrentAvatarLoads {
        // Load immediately
        return await startAvatarLoad(...)
    } else {
        // Queue for later
        return await withCheckedContinuation { continuation in
            pendingAvatarRequests.append((cacheKey, url, ..., continuation))
        }
    }
}

private func processNextPendingAvatar() {
    guard activeAvatarLoads.count < maxConcurrentAvatarLoads,
          !pendingAvatarRequests.isEmpty else { return }
    
    let nextRequest = pendingAvatarRequests.removeFirst()
    
    Task {
        let result = await startAvatarLoad(...)
        nextRequest.continuation.resume(returning: result)
    }
}
```

### Benefits

1. **Prevents network congestion** - Max 4 concurrent avatar requests
2. **Deduplication** - Same avatar requested multiple times = single request
3. **Fair queueing** - FIFO queue for pending requests
4. **Cache-first** - Always checks cache before network
5. **Stable cache keys** - Uses `user.avatar` MimeiId

---

## Best Practices

### 1. Always Use Stable Cache Keys

✅ **DO:**
```swift
let cacheKey = attachment.mid  // IPFS hash
let cacheKey = user.avatar     // User's avatar MimeiId
let cacheKey = mediaID         // Extracted from URL
```

❌ **DON'T:**
```swift
let cacheKey = url.lastPathComponent       // Changes with URL
let cacheKey = url.absoluteString          // Changes with server
let cacheKey = "\(userId)_\(timestamp)"   // Changes over time
```

### 2. Check Cache Before Network

```swift
// 1. Memory cache (instant)
if let cached = memoryCache.get(key) { return cached }

// 2. Disk cache (fast)
if let cached = diskCache.get(key) { return cached }

// 3. Network (slow)
let data = try await URLSession.shared.data(from: url)
```

### 3. Respect Memory Thresholds

```swift
// Only cleanup if actually needed
let memoryUsageMB = currentMemoryUsage / (1024 * 1024)

if memoryUsageMB > 1400 {  // 1.4GB threshold
    performCleanup()
} else {
    // Ignore false warnings
}
```

### 4. Use LRU Eviction

```swift
// Track access times
cacheTimestamps[key] = Date()

// Evict oldest when limit reached
let sorted = cache.sorted { 
    timestamps[$0.key] ?? .distantPast < 
    timestamps[$1.key] ?? .distantPast 
}
```

### 5. Throttle Concurrent Requests

```swift
// Limit concurrent operations
if activeRequests.count < maxConcurrent {
    startRequest()
} else {
    queueRequest()
}
```

### 6. Deduplicate Requests

```swift
// Check if already loading
if let existingTask = ongoingRequests[key] {
    return await existingTask.value
}

// Create and track new request
let task = Task { await loadData() }
ongoingRequests[key] = task
```

### 7. Clean Up on App Lifecycle Events

```swift
// Background
NotificationCenter.default.addObserver(
    forName: UIApplication.didEnterBackgroundNotification
) { 
    performBackgroundCleanup()
}

// Foreground
NotificationCenter.default.addObserver(
    forName: UIApplication.willEnterForegroundNotification
) {
    resumeOperations()
}
```

---

## Monitoring & Debugging

### Memory Usage Logging

```swift
let stats = MemoryCapManager.shared.getMemoryStatistics()
print("Memory: \(stats.currentUsage)MB / \(stats.limit)MB (\(Int(stats.percentage * 100))%)")
print("Status: \(stats.status)")  // NORMAL, WARNING, CRITICAL
```

### Cache Statistics

```swift
// Global Image Load Manager
let (active, pending, completed, retries) = GlobalImageLoadManager.shared.getStatistics()

// Shared Asset Cache
let playerCount = SharedAssetCache.shared.playerCache.count
let assetCount = SharedAssetCache.shared.assetCache.count
```

### Debug Logs

Enable detailed logging by searching for:
```swift
print("DEBUG: [MemoryCapManager] ...")
print("DEBUG: [SharedAssetCache] ...")
print("DEBUG: [ImageCacheManager] ...")
```

---

## Recent Improvements (October 2025)

### 1. Fixed False Memory Warnings
- **Problem:** Aggressive cleanup at ~100MB usage
- **Solution:** All managers check usage > 1.4GB before cleanup (aligned with preventive threshold)
- **Impact:** No more unnecessary cleanup at startup; unified threshold design

### 2. Stable Cache Keys
- **Problem:** Cache invalidated when server/URL changed
- **Solution:** Use MimeiId/mediaID instead of URLs
- **Impact:** Cache survives server changes

### 3. Avatar Loading Throttling
- **Problem:** Network congestion in user lists
- **Solution:** Limit to 4 concurrent avatar loads
- **Impact:** Better performance in profile views

### 4. Removed Duplicate MemoryCapManager
- **Problem:** Two instances doing identical work
- **Solution:** Synchronized both with 1GB threshold
- **Impact:** No double cleanup on warnings

---

## Related Documentation

- [VIDEO_SYSTEM.md](VIDEO_SYSTEM.md) - Video caching and playback
- [TWEET_MEMORY_CACHE_ALGORITHM.md](TWEET_MEMORY_CACHE_ALGORITHM.md) - Tweet-specific caching
- [NETWORK_RESILIENCE.md](NETWORK_RESILIENCE.md) - Network error handling
- [UPLOAD_SYSTEM.md](UPLOAD_SYSTEM.md) - Upload memory management

---

## Future Improvements

1. **Predictive Preloading** - ML-based prediction of next content
2. **Adaptive Thresholds** - Adjust based on device memory
3. **Cache Warming** - Pre-populate cache on WiFi
4. **Usage Analytics** - Track cache hit rates
5. **Memory Pressure API** - Use iOS memory pressure notifications

