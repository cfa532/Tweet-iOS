# BaseURL Resolution & Instant Cache Rendering

**Last Updated:** October 22, 2025  
**Status:** ⚠️ **DEPRECATED** - Simplified approach implemented

> **⚠️ IMPORTANT:**  
> This document describes a **complex workaround system** that is **NO LONGER USED**.  
>  
> **What happened:**
> - This system assigned dummy localhost baseUrls to cached tweets
> - Then updated them to real IPs later
> - Required ~34 lines of complex synchronization code
>  
> **Why it was removed:**
> - Root cause was blocking renders in `TweetItemView.swift`
> - Fixed by rendering immediately with placeholders
> - Background fetches now get complete author data (including baseUrl)
> - User singletons automatically propagate baseUrl updates
> - **Result: All this complexity became unnecessary**
>  
> **Current approach:**  
> See [CACHED_TWEETS_BLOCKING_FIX.md](fixes/CACHED_TWEETS_BLOCKING_FIX.md) for the **simpler solution**.

---

## Historical Overview (Deprecated System)

The following describes how the app **used to** achieve instant rendering through a complex baseUrl assignment system. This is kept for historical reference only.

## Core Problem

Tweets cached locally have authors with no `baseUrl` (server IP). Without a baseUrl:
- Avatar URLs can't be constructed
- Video URLs can't be constructed
- Media won't load until server responds

**Goal:** Render cached tweets **instantly** without waiting for network.

---

## The Solution: Multi-Stage BaseURL Resolution

### Stage 1: Localhost Proxy (Instant - 0ms delay)
Cached tweets render immediately with `localhost:port` as baseUrl.

```swift
// TweetCacheManager returns tweets with NO baseUrl
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(...)

// FollowingsTweetView assigns localhost on MainActor BEFORE returning
await MainActor.run {
    let resolvedBaseUrl = appUser.baseUrl ?? URL(string: "http://127.0.0.1:18136")!
    for tweet in cachedTweets {
        if tweet.author?.baseUrl == nil {
            tweet.author?.baseUrl = resolvedBaseUrl
        }
    }
}
```

**Why localhost works:**
- LocalHTTPServer acts as a proxy
- Proxies requests to cached content OR real server
- No network required for cached media
- Videos/images load instantly from disk

### Stage 2: Real IP Update (Background)
After app initialization, all users get updated from `localhost:18136` → real IP.

```swift
// In HproseInstance.initAppEntry()
// 1. Resolve provider IP
let providerIp = "125.229.161.122:8080"

// 2. Set appUser.baseUrl on MainActor
await MainActor.run {
    user.baseUrl = URL(string: "http://\(providerIp)")!
}

// 3. Update ALL cached users from localhost → real IP
await User.updateAllUsersWithLocalhostToRealIP(realIP: user.baseUrl!)

// 4. Mark app as initialized
await MainActor.run {
    isInitializationComplete = true
}

// 5. Fetch followings/blacklist in background (non-blocking)
Task.detached(priority: .background) {
    let followings = try? await getListByType(...)
    let blackList = try? await getListByType(...)
}
```

**Result:**
- Cached tweets render with localhost in ~8ms
- Real IP resolves in ~400ms
- UI updates smoothly to real IP
- Videos continue playing without interruption

---

## Timing Sequence

### App Launch Timeline

```
T+0ms   App starts
        ├─ LocalHTTPServer starts on port 18136
        ├─ Core Data loads
        └─ HproseInstance.appUser initialized (baseUrl: nil)

T+50ms  User sees HomeView
        └─ TweetListView appears

T+60ms  Cache fetch begins
        └─ 📋 [FEED LOAD] Fetching page 0 from CACHE

T+68ms  Cache returns (FAST!)
        ├─ ✅ [FEED LOAD] Cache returned 10 tweets in 7.9ms
        ├─ Authors have baseUrl: nil
        └─ FollowingsTweetView assigns localhost:18136

T+70ms  Tweets render IMMEDIATELY
        ├─ ⚡ [TWEET RENDER] rendering with baseUrl: http://127.0.0.1:18136
        ├─ Avatars load via localhost proxy
        └─ Videos setup via localhost proxy

T+100ms Server fetch starts (parallel to rendering)
        └─ 🌐 [FEED LOAD] Fetching page 0 from SERVER

T+2000ms Provider IP resolves (domain resolution)
        └─ provider ip: 125.229.161.122:8080

T+2100ms App init completes
        ├─ 🔄 [INIT] Fetching user data for appUser...
        ├─ ✅ [INIT] User data fetched
        └─ 🔄 [INIT] Updating all users from localhost to real IP...

T+2150ms All users updated to real IP
        ├─ ✅ [User] Updated 3 users from localhost to real IP
        ├─ ✅ [INIT] App initialized with real IP
        └─ Tweets re-render with real IP (seamless)

T+2500ms Followings/blacklist loaded (background)
        ├─ ✅ [INIT] Followings fetched: 7
        └─ ✅ [INIT] Blacklist fetched: 0
```

**Key Insight:** Cached tweets render at T+70ms, while server init completes at T+2150ms. Without localhost fallback, users would wait **2+ seconds** for first render!

---

## BaseURL Resolution Hierarchy

### Priority Order (High to Low)

1. **User.baseUrl** - Real server IP (e.g., `http://125.229.161.122:8080`)
   - Set after app initialization
   - Most reliable for media loading
   - Used for all network requests

2. **HproseInstance.appUser.baseUrl** - Current user's IP
   - Available after login/init
   - Shared across all views
   - Updated on IP refresh

3. **Localhost Proxy** - `http://127.0.0.1:18136`
   - **ALWAYS available** (LocalHTTPServer starts on app launch)
   - Works offline for cached content
   - Fallback when real IP not available

### Code Example

```swift
// In MediaCell.swift
private var baseUrl: URL {
    return parentTweet.author?.baseUrl 
        ?? HproseInstance.shared.appUser.baseUrl 
        ?? URL(string: "http://127.0.0.1:\(LocalHTTPServer.shared.port)")!
}

// In User.swift (avatarUrl)
let effectiveBaseUrl = baseUrl 
    ?? HproseInstance.shared.appUser.baseUrl 
    ?? URL(string: "http://127.0.0.1:\(LocalHTTPServer.shared.port)")!
```

**Why the hierarchy works:**
- Real IP provides best performance (direct connection)
- Localhost ensures app never freezes waiting for IP
- Media loads immediately from cache via proxy

---

## Cache Rendering Flow

### 1. Tweet Cache Fetch (TweetCacheManager)

```swift
func fetchCachedTweets(...) async -> [Tweet?] {
    return await withCheckedContinuation { continuation in
        context.perform {
            // Fetch tweets from Core Data
            let cdTweets = try? context.fetch(request)
            
            for cdTweet in cdTweets {
                let tweet = Tweet.from(cdTweet: cdTweet)
                
                // Get author singleton
                let authorSingleton = User.getInstance(mid: cdTweet.authorId)
                
                // If cached data exists, update singleton
                if let cdUser = fetchCDUser(mid: cdTweet.authorId) {
                    _ = User.from(cdUser: cdUser)
                }
                
                tweet.author = authorSingleton
                // NOTE: baseUrl NOT assigned here (avoids threading issues)
            }
            
            continuation.resume(returning: tweets)
        }
    }
}
```

**Key Points:**
- Returns tweets with authors but **NO baseUrl**
- Fast (7-10ms for 10 tweets)
- Runs on Core Data's background context
- No `@Published` updates on background thread

### 2. BaseURL Assignment (FollowingsTweetView)

```swift
tweetFetcher: { page, size, isFromCache, shouldCache in
    if isFromCache {
        // Fetch from cache (fast, no baseUrl)
        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(...)
        
        // CRITICAL: Assign baseUrl on MainActor BEFORE returning
        await MainActor.run {
            let resolvedBaseUrl = appUser.baseUrl ?? localhost
            for tweet in cachedTweets {
                if tweet.author?.baseUrl == nil {
                    tweet.author?.baseUrl = resolvedBaseUrl
                }
            }
        }
        
        return cachedTweets  // Now ready to render!
    }
}
```

**Why this works:**
- `await MainActor.run` ensures thread-safe `@Published` updates
- Happens BEFORE tweets reach UI
- Adds ~3-5ms delay but eliminates threading warnings
- Tweets render once with correct baseUrl

### 3. Tweet Rendering (TweetItemView)

```swift
.task {
    // Check if author needs loading
    if tweet.author == nil || tweet.author?.username == nil {
        // Fetch from cache/server
        tweet.author = try? await fetchUser(tweet.authorId)
    } else {
        // Author exists with baseUrl - render immediately!
        print("⚡ [TWEET RENDER] Tweet \(tweet.mid) rendering IMMEDIATELY")
    }
}
```

**Result:**
```
⚡ [TWEET RENDER] Tweet xxx rendering IMMEDIATELY (username: mini, baseUrl: http://127.0.0.1:18136)
⚡ [TWEET RENDER] Tweet yyy rendering IMMEDIATELY (username: mini, baseUrl: http://127.0.0.1:18136)
⚡ [TWEET RENDER] Tweet zzz rendering IMMEDIATELY (username: mini, baseUrl: http://127.0.0.1:18136)
```

---

## LocalHTTPServer: The Critical Component

### Purpose

LocalHTTPServer enables **offline media playback** by acting as a local proxy:

```
[SwiftUI View] → requests http://127.0.0.1:18136/mediaID/ipfs/...
                ↓
      [LocalHTTPServer]
                ↓
        Check disk cache
                ↓
    ┌─────────┴─────────┐
    │                   │
  Cache Hit         Cache Miss
    │                   │
Serve from disk   Fetch from server
    │              (real IP required)
    │                   │
    └───────┬───────────┘
            ↓
    Return to AVPlayer
```

### Port Assignment

```swift
// On app launch
LocalHTTPServer.shared.start()
// Tries saved port (18136) or finds available port
// Port is stable across app launches
```

### URL Transformation

**Original URL:**
```
http://125.229.161.122:8080/ipfs/QmABC...?dig=1234
```

**Localhost Proxy URL:**
```
http://127.0.0.1:18136/QmABC.../ipfs/QmABC...
```

**Real URL (registered internally):**
```
http://125.229.161.122:8080/ipfs/QmABC...
```

When app initializes and real IP is available, LocalHTTPServer uses real URL for cache misses.

---

## User Singleton Pattern

### Memory Singletons

All `User` objects are **singletons** stored in memory:

```swift
class User: ObservableObject {
    @Published var baseUrl: URL?
    @Published var username: String?
    @Published var avatar: String?
    
    private static var userInstances: [String: User] = [:]
    
    static func getInstance(mid: String) -> User {
        userInstancesQueue.sync {
            if let existing = userInstances[mid] {
                return existing
            }
            let newUser = User(mid: mid)
            userInstances[mid] = newUser
            return newUser
        }
    }
}
```

**Benefits:**
- **Single source of truth** - updating one user updates everywhere
- **Memory efficient** - one User object per unique user
- **Automatic UI updates** - `@Published` triggers SwiftUI refreshes
- **Thread-safe** - protected by `userInstancesQueue`

### BaseURL Update Propagation

When `User.updateAllUsersWithLocalhostToRealIP()` is called:

```swift
@MainActor
static func updateAllUsersWithLocalhostToRealIP(realIP: URL) {
    var usersToUpdate: [(String, User)] = []
    
    // Collect localhost users
    userInstancesQueue.sync {
        for (mid, user) in userInstances {
            if user.baseUrl?.absoluteString.contains("127.0.0.1") == true {
                usersToUpdate.append((mid, user))
            }
        }
    }
    
    // Update all on MainActor (single batch)
    for (mid, user) in usersToUpdate {
        user.baseUrl = realIP  // Triggers @Published update
    }
}
```

**Result:**
- All tweet authors pointing to same user get updated simultaneously
- SwiftUI observes `@Published` change
- Avatars/videos switch from localhost → real IP seamlessly
- No re-renders, just URL updates

---

## Thread Safety & MainActor

### The Challenge

Swift Combine requires `@Published` property updates on main thread:

```swift
class User: ObservableObject {
    @Published var baseUrl: URL?  // MUST update on MainActor!
}
```

### The Solution

All baseUrl assignments go through MainActor:

#### In HproseInstance (App Init)
```swift
// WRONG (crashes with warnings)
user.baseUrl = URL(string: "http://\(providerIp)")!

// CORRECT
await MainActor.run {
    user.baseUrl = URL(string: "http://\(providerIp)")!
}
```

#### In TweetCacheManager (Cache Fetch)
```swift
// WRONG (20+ threading warnings)
func fetchCachedTweets(...) {
    context.perform {
        for tweet in tweets {
            tweet.author?.baseUrl = resolvedBaseUrl  // Background thread!
        }
    }
}

// CORRECT
// TweetCacheManager returns tweets WITHOUT baseUrl
// Caller (FollowingsTweetView) assigns on MainActor
await MainActor.run {
    for tweet in cachedTweets {
        tweet.author?.baseUrl = resolvedBaseUrl
    }
}
```

#### In User Update
```swift
@MainActor  // Entire function runs on main thread
static func updateAllUsersWithLocalhostToRealIP(realIP: URL) {
    for (mid, user) in usersToUpdate {
        user.baseUrl = realIP  // Safe!
    }
}
```

---

## App Initialization Flow

### Non-Blocking Init (Critical for UX)

**Old Flow (BLOCKING):**
```
App Launch → Wait for IP → Wait for followings → Wait for blacklist → Show UI
Total: 2500ms before first tweet renders ❌
```

**New Flow (NON-BLOCKING):**
```
App Launch
  ├─ LocalHTTPServer starts (instant)
  ├─ Show UI immediately
  ├─ Cache renders with localhost (70ms)
  │
  └─ Background: IP resolution
      ├─ Resolve domain → IP (2000ms)
      ├─ Fetch user data (100ms)
      ├─ Update users localhost → real IP (instant)
      ├─ Mark app initialized
      └─ Fetch followings/blacklist (background)

First render: 70ms ✅
Full init: 2500ms (but non-blocking)
```

### Code

```swift
// In HproseInstance.initAppEntry()
if let user = user {
    // Set IPs
    HproseInstance.baseUrl = URL(string: "http://\(providerIp)")!
    await MainActor.run {
        user.baseUrl = HproseInstance.baseUrl
    }
    
    // Update cached users IMMEDIATELY
    await User.updateAllUsersWithLocalhostToRealIP(realIP: user.baseUrl!)
    
    // Mark app initialized (unblocks UI)
    await MainActor.run {
        isInitializationComplete = true
        User.updateUserInstance(with: user)
        _appUser = User.getInstance(mid: user.mid)
    }
    
    // Notify UI
    await MainActor.run {
        NotificationCenter.default.post(name: .appUserReady, object: nil)
    }
    
    // Load followings/blacklist in background (NON-BLOCKING!)
    Task.detached(priority: .background) {
        let followings = try? await getListByType(user: user, entry: .FOLLOWING)
        let blackList = try? await getListByType(user: user, entry: .BLACK_LIST)
        await MainActor.run {
            user.followingList = followings
            user.userBlackList = blackList
        }
    }
}
```

**Why this matters:**
- Old system: `getListByType()` could hang for seconds
- UI blocked until followings loaded
- Cached tweets couldn't render
- New system: followings load in background while tweets are already visible

---

## Offline Support

### Without Network Connection

1. **App Launch:**
   - LocalHTTPServer starts on saved port
   - Core Data loads cached tweets/users
   - `appUser.baseUrl` remains `nil`

2. **Cache Fetch:**
   ```
   📋 [FEED LOAD] Fetching page 0 from CACHE
   ✅ [FEED LOAD] Cache returned 10 tweets in 8.2ms
   ```

3. **BaseURL Assignment:**
   ```swift
   // appUser.baseUrl is nil, so use localhost
   let resolvedBaseUrl = appUser.baseUrl ?? URL(string: "http://127.0.0.1:18136")!
   // Result: http://127.0.0.1:18136
   ```

4. **Rendering:**
   ```
   ⚡ [TWEET RENDER] rendering with baseUrl: http://127.0.0.1:18136
   ```

5. **Media Loading:**
   - Avatar: `http://127.0.0.1:18136/ipfs/QmAvatar...`
   - Video: `http://127.0.0.1:18136/QmVideo.../ipfs/QmVideo...`
   - LocalHTTPServer serves from disk cache
   - **No network required!**

### Network Recovery

When network returns:
1. `HproseInstance` resolves domain → IP
2. `User.updateAllUsersWithLocalhostToRealIP()` updates all users
3. UI updates smoothly (thanks to `@Published`)
4. New content fetches from real server

---

## Tweet Author Loading

### In-Memory First Strategy

```swift
// In TweetCacheManager.fetchCachedTweets()
for cdTweet in cdTweets {
    // 1. Always get singleton first (creates if needed)
    let authorSingleton = User.getInstance(mid: cdTweet.authorId)
    
    // 2. If singleton has data, use it (FAST!)
    if authorSingleton.username != nil {
        tweet.author = authorSingleton
        continue  // Skip Core Data lookup
    }
    
    // 3. Otherwise, check Core Data
    if let cdUser = fetchCDUser(mid: cdTweet.authorId) {
        _ = User.from(cdUser: cdUser)  // Updates singleton
    }
    
    // 4. Use singleton (either populated or placeholder)
    tweet.author = authorSingleton
}
```

**Performance:**
- In-memory check: <1ms
- Core Data fetch: ~2-5ms per user
- Singleton pattern ensures each user loaded once

---

## Video Playback with BaseURL

### Progressive Video (MP4)

```swift
// Original URL
let originalUrl = "http://\(author.baseUrl)/ipfs/QmVideo..."

// LocalHTTPServer proxy
let proxyUrl = "http://127.0.0.1:\(port)/QmVideo.../ipfs/QmVideo..."

// CachingPlayerItem plays from proxy
let playerItem = CachingPlayerItem(url: proxyUrl)

// LocalHTTPServer registers real URL for cache misses
LocalHTTPServer.registerRealURL(for: mediaId, realURL: originalUrl)
```

**Flow:**
1. Video player requests via localhost
2. LocalHTTPServer checks disk cache
3. Cache hit → serve from disk (no network)
4. Cache miss → fetch from real URL (uses author.baseUrl)

### HLS Video (Adaptive Streaming)

```swift
// Check if playlist cached
if let cachedPlaylist = findCachedPlaylist(mediaID) {
    // Reconstruct URL with current baseUrl
    let reconstructedUrl = "http://\(author.baseUrl)/ipfs/\(mediaID)/master.m3u8"
    
    // Use cached playlist, update base URL
    let proxyUrl = "http://127.0.0.1:\(port)/\(mediaID)/ipfs/\(mediaID)/master.m3u8"
    LocalHTTPServer.registerRealURL(for: mediaID, realURL: reconstructedUrl)
}
```

**Why this works:**
- HLS playlists cached to disk
- BaseURL can change without re-downloading playlist
- LocalHTTPServer rewrites segment URLs on the fly
- Seamless transition localhost → real IP

---

## Critical Design Decisions

### 1. Why NOT Assign BaseURL in TweetCacheManager?

**Problem:**
```swift
context.perform {  // Core Data background context
    author.baseUrl = url  // Updates @Published on background thread
}
// Result: "Publishing from background threads is not allowed"
```

**Solution:**
Return tweets without baseUrl, let **caller** assign on MainActor.

### 2. Why Wait for BaseURL Assignment?

**Problem (fire-and-forget):**
```swift
let tweets = await fetchCachedTweets()
Task { @MainActor in
    assign baseUrl
}
return tweets  // Returns before Task completes!
// Result: Tweets render with NIL → Task completes → UI updates mid-render → crashes
```

**Solution (blocking):**
```swift
let tweets = await fetchCachedTweets()
await MainActor.run {  // WAIT for completion
    assign baseUrl
}
return tweets  // BaseURL guaranteed to be set
// Result: Tweets render ONCE with correct baseUrl
```

### 3. Why Localhost Fallback is Essential?

Without localhost fallback:
- App hangs waiting for domain resolution (2+ seconds)
- Offline mode completely broken
- Cache can't be used without network
- Poor user experience

With localhost fallback:
- Renders in <100ms
- Works offline
- Smooth network recovery
- Excellent UX

---

## Debugging

### Key Logs

**Cache Fetch:**
```
📋 [FEED LOAD] Fetching page 0 from CACHE
✅ [FEED LOAD] Cache returned 10 tweets in 7.9ms
```
**Expected:** 5-15ms for 10 tweets

**Tweet Render:**
```
⚡ [TWEET RENDER] Tweet xxx rendering IMMEDIATELY (username: mini, baseUrl: http://127.0.0.1:18136)
```
**Good:** Shows localhost during init, then real IP after

**Init Flow:**
```
provider ip: 125.229.161.122:8080
🔄 [INIT] Fetching user data for appUser...
✅ [INIT] User data fetched, got user: true
🔄 [INIT] Updating all users from localhost to real IP...
✅ [User] Updated 3 users from localhost to real IP
✅ [INIT] App initialized with real IP: 125.229.161.122:8080
🔄 [INIT] Fetching followings and blacklist in background...
```
**Good:** Init completes quickly, followings in background

### Common Issues

**Issue:** Tweets wait for server before rendering
```
⏳ [TWEET RENDER] Tweet xxx WAITING for author fetch
```
**Fix:** Author should be loaded from cache/memory, not server

**Issue:** "Publishing from background threads" warnings
**Fix:** Ensure all `user.baseUrl` assignments use `await MainActor.run`

**Issue:** Cache returns slow (>50ms)
```
✅ [FEED LOAD] Cache returned 10 tweets in 64.1ms
```
**Fix:** MainActor is blocked - likely from threading warnings

**Issue:** Videos won't play offline
```
⚠️ [LocalHTTPServer] App not initialized, refusing NETWORK request
```
**Fix:** LocalHTTPServer needs app initialization flag removed for cache hits

---

## Performance Metrics

### Target Performance

| Operation | Target | Actual |
|-----------|--------|--------|
| Cache fetch (10 tweets) | <15ms | 7.9ms ✅ |
| Tweet render (with cache) | <100ms | 70ms ✅ |
| App init (background) | <3000ms | 2150ms ✅ |
| Localhost → Real IP update | <10ms | 5ms ✅ |
| Video load from cache | <200ms | 150ms ✅ |

### Real-World Timeline

```
0ms     App launch
70ms    First 10 tweets visible (localhost)
500ms   Videos start playing from cache
2150ms  Real IP resolved, URLs updated
2500ms  Background data loaded (followings/blacklist)
```

**User Experience:** Tweets appear almost instantly, videos play smoothly, network updates happen transparently.

---

## Related Files

### Core Components
- `Sources/Core/HproseInstance.swift` - Network & init flow
- `Sources/Core/TweetCacheManager.swift` - Tweet/user caching
- `Sources/DataModels/User.swift` - User singleton pattern
- `Sources/DataModels/Tweet.swift` - Tweet singleton pattern
- `Sources/CachingPlayerItem/LocalHTTPServer.swift` - Media proxy

### UI Components
- `Sources/Features/Home/FollowingsTweetView.swift` - Main feed
- `Sources/Tweet/TweetItemView.swift` - Individual tweet rendering
- `Sources/Features/MediaViews/MediaCell.swift` - Media display

### Related Documentation
- [VIDEO_SYSTEM.md](VIDEO_SYSTEM.md) - Video playback architecture
- [NETWORK_RESILIENCE.md](NETWORK_RESILIENCE.md) - Offline support
- [ARCHITECTURE.md](ARCHITECTURE.md) - Overall app architecture

---

## Future Improvements

1. **Predictive IP Caching**
   - Cache provider IPs to disk
   - Use last known IP as initial baseUrl
   - Validate in background

2. **Progressive BaseURL Updates**
   - Update visible tweets first
   - Background tweets update lazily
   - Reduce MainActor contention

3. **Smart Localhost Detection**
   - Automatically detect when localhost is needed
   - Skip localhost for fresh server data
   - Optimize for online vs offline scenarios

---

## Summary

The baseUrl resolution system enables:
- ✅ **Instant cache rendering** (7.9ms)
- ✅ **Offline support** (localhost proxy)
- ✅ **Smooth network recovery** (background updates)
- ✅ **Thread-safe updates** (MainActor)
- ✅ **Memory efficient** (singleton pattern)

**Key Principle:** Never block UI waiting for network. Use localhost as a bridge between cache and real server.

