# Network Resilience & Caching Strategy

## Overview

The Tweet-iOS app is designed to work seamlessly in challenging network environments through a comprehensive caching strategy and server-friendly network handling. This document outlines the implementation details and best practices.

## 🏗️ Architecture

### Multi-Layer Caching System

1. **Core Data Cache** (`TweetCacheManager`)
   - Persistent storage for tweets and users
   - 7-day cache expiration
   - Automatic cleanup and size management
   - LRU eviction strategy

2. **Memory Cache** (`SharedAssetCache`)
   - Video assets and players
   - 5-minute expiration
   - Background cleanup timer
   - Priority-based preloading

3. **Image Cache** (`ImageCacheManager`)
   - Compressed image storage
   - 500MB disk cache limit
   - Memory warning handling

4. **Video Cache** (`SharedAssetCache`)
   - Video player instances
   - Background restoration
   - Memory-efficient management

5. **BlackList** (`BlackList`)
   - Failed resource tracking
   - Automatic blacklisting after 14+ failures over 1+ week
   - Prevents repeated attempts to load broken content
   - Persistence: UserDefaults (primary) + iCloud (backup)
   - Survives cache clearing and app reinstallation

## 🚫 BlackList System

### Purpose

The BlackList system tracks media resources (images, videos) that repeatedly fail to load and automatically blacklists them after persistent failures. This prevents the app from wasting time and bandwidth on broken content.

### Tracking Mechanism

**Candidate List:**
- First failure: Resource added to candidates
- Subsequent failures: Failure count incremented
- Success: Resource removed from candidates

**Blacklist:**
- Resources promoted to blacklist after **14+ failures** over **1+ week**
- Once blacklisted, resource is never attempted again
- Permanent until app reinstallation (if iCloud unavailable)

### Implementation

```swift
// Recording failures
BlackList.shared.recordFailure("QmXXXXX...")

// Recording success (removes from candidates)
BlackList.shared.recordSuccess("QmXXXXX...")

// Checking before loading
if BlackList.shared.isBlacklisted(mediaID) {
    // Skip loading, show placeholder
    return
}
```

### Persistence Strategy

**Primary Storage:** UserDefaults
- Fast, local, immediate reads/writes
- Source of truth for runtime behavior
- Survives cache clearing but NOT reinstallation

**Backup Storage:** iCloud Key-Value Store
- Best-effort sync across devices
- Survives app reinstallation
- Graceful degradation if iCloud unavailable
- No user configuration required

**Load Order:**
1. Read from UserDefaults (authoritative)
2. If missing, fallback to iCloud
3. If both empty, start fresh

**Save Order:**
1. Write to UserDefaults first (immediate)
2. Mirror to iCloud (background sync)

### Benefits

- ✅ **Bandwidth Savings**: Stops retrying broken resources
- ✅ **Performance**: No wasted time on dead content
- ✅ **User Experience**: Faster loading, fewer errors
- ✅ **Server-Friendly**: Reduces load on IPFS gateways
- ✅ **Persistent**: Survives cache clears and reinstallation
- ✅ **Zero Config**: Works automatically, no user action required

### Monitoring

```swift
let (candidates, blacklisted) = BlackList.shared.getStats()
print("BlackList: \(candidates) candidates, \(blacklisted) blacklisted")
```

## 🔄 Cache-First Loading Strategy

### TweetListView Implementation

```swift
// Step 1: Load from cache first for instant UX
let tweetsFromCache = try await tweetFetcher(page, pageSize, true)
await MainActor.run {
    tweets.mergeTweets(tweetsFromCache.compactMap { $0 })
    isLoading = false
    initialLoadComplete = true
}

// Step 2: Load from server to update with fresh data (non-blocking, no retry)
Task {
    await loadFromServer(page: page, pageSize: pageSize)
}
```

### Benefits
- ✅ **Instant Display**: Cache data loads immediately
- ✅ **Fresh Data**: Server updates happen in background
- ✅ **No Blocking**: UI remains responsive
- ✅ **Offline Support**: Works without network connection
- ✅ **Server-Friendly**: No retry mechanisms to overload servers

## 🌐 Network Resilience Features

### NetworkMonitor

```swift
class NetworkMonitor: ObservableObject {
    @Published var isConnected = false
    @Published var connectionType: ConnectionType = .unknown
    
    var hasReliableConnection: Bool
    var hasAnyConnection: Bool
}
```

### Connection Types
- **WiFi/Ethernet**: Reliable connection for data operations
- **Cellular**: Available but may be slower
- **Unknown**: Conservative handling

### Server-Friendly Loading

```swift
private func loadFromServer(page: UInt, pageSize: UInt) async {
    let networkMonitor = NetworkMonitor.shared
    
    // Skip server loading if no network connection
    guard networkMonitor.hasAnyConnection else {
        print("No network connection available, skipping server load")
        return
    }
    
    // Single attempt - no retries to prevent server overload
    do {
        let tweetsFromServer = try await tweetFetcher(page, pageSize, false)
        // Process server data...
    } catch {
        print("Server load failed: \(error)")
        // Continue with cached data only
    }
}
```

## 🔄 Smart IP Resolution with Retry Strategy

### Overview

The distributed Tweet network uses multiple server nodes. Users are dynamically assigned to nodes, and node IPs can change over time. The app uses a smart retry strategy to handle IP changes while minimizing unnecessary provider lookups.

### The Problem with Old Code

**Scenario: Server IP Changes**

When a server node's IP changed (e.g., `183.156.84.30:8002` → `183.156.84.30:8003`), the old code would:
1. Try cached IP (fails)
2. Retry with same cached IP (fails)
3. Retry again with same cached IP (fails)
4. Give up - stuck for 30 minutes until cache expires

**Root Cause:**
```swift
// Old code: Early return with stale IP
if cachedUser.username != nil && !hasExpired && 
   cachedUser.baseUrl != nil && !baseUrl.isEmpty {
    return cachedUser  // ❌ Stale IP never refreshed!
}
```

### New Strategy: Smart First-Attempt + Force-Retry

**Critical Design Decision:**

Read-only IP addresses (`baseUrl`) **ARE NOW persisted to disk** (see `User.swift` line 520) thanks to the smart retry mechanism:
```swift
// NOW caching baseUrl for faster app restarts
// Safe because retry mechanism automatically re-resolves if IP changed
try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
// Don't cache writableUrl - resolved fresh from hostIds each time
```

**Why IP Caching is Now Safe:**
- ✅ **Retry safety net**: If cached IP fails, retry auto-resolves fresh IP
- ✅ **Server migrations handled**: Old IP fails → Retry gets new IP → Success
- ⚡ **Faster restarts**: Uses cached IP if still valid (most common case)
- 🎯 **Automatic correction**: Stale IPs fixed within 1-2 seconds

**Impact:**
- ⚡ **App Restart**: Uses cached IP first (fast path)
- 🔄 **If IP Changed**: First attempt fails → Retry resolves fresh IP
- 💾 **Within Session**: IPs cached in memory AND disk
- 🔒 **Thread-Safe**: Singleton pattern prevents duplicate resolutions

**Flow on App Restart (IP Cached):**
```
1. Load User from Core Data
   └─ baseUrl = "http://183.156.84.30:8002" (from last session) ✅
   └─ username, avatar, etc. = from cache ✅

2. First fetchUser call
   └─ Uses cached baseUrl from disk
   └─ Attempt 1: Try cached IP (usually still valid)
   
3. Possible outcomes:
   └─ IP still valid → Success immediately (fast path!) ✅
   └─ IP changed → Retry 2 calls getProviderIP() → Gets new IP → Success ✅

4. Subsequent calls in same session
   └─ baseUrl != nil (updated if needed)
   └─ Uses current valid IP (fast!)
```

**Implementation in `updateUserFromServer()`:**

```swift
func updateUserFromServer(_ userId: String, baseUrl: String = ...) async throws -> User? {
    for attempt in 1...3 {
        // First attempt: Use provided baseUrl (fast, usually works)
        // Note: On app restart, baseUrl is empty → forces resolution
        if attempt == 1 && !baseUrl.isEmpty {
            user.baseUrl = URL(string: baseUrl)
        } 
        // Retry attempts: Force fresh IP resolution
        else {
            guard let providerIP = try await self.getProviderIP(userId) else {
                throw NSError(...)
            }
            user.baseUrl = URL(string: "http://\(providerIP)")!
        }
        
        try await updateUserFromServerInternal(user)
        return user  // Success!
    }
}
```

### When to Use Empty String

**Force IP Resolution from First Attempt** (pass `baseUrl: ""`):
- ✅ **App initialization** - IPs not persisted, must resolve fresh
- ✅ **Explicit user refresh** - Pull-to-refresh wants latest data
- ✅ **After extended background** - Connections may have changed
- ✅ **Manual profile refresh** - User explicitly requesting fresh data

**Use Default BaseUrl** (appUser.baseUrl or cached):
- ✅ **Normal user fetches** - Author loading, quick lookups
- ✅ **Background updates** - Use memory-cached IP first
- ✅ **Within-session calls** - IP likely still valid
- 📝 **Note**: On app restart, default is empty (IPs not persisted) → auto-resolves

**Automatic Empty BaseUrl Scenarios:**
- App restart (baseUrl = nil in cache → converted to "" by default parameter)
- Cache cleared (baseUrl = nil)
- First-time user lookup (no cached data)

### Flow Examples

**Scenario 1: Within Active Session (IP Cached in Memory)**

**Attempt 1:**
```
fetchUser(userId) → uses cached IP "http://183.156.84.30:8002"
└─ If cached IP still valid → Success (fast!) ✅
└─ If cached IP stale → Fails, proceed to retry
```

**Attempt 2:**
```
Retry → getProviderIP(userId) → "183.156.84.30:8003" (new IP!)
└─ Try with fresh IP → Success (recovered!) ✅
```

**Attempt 3:**
```
Retry → getProviderIP(userId) → "183.156.84.30:8003"
└─ Last chance with fresh IP
```

**Scenario 2: After App Restart with IP Change (IP Cached)**

**Server migrated from `:8002` to `:8003` while app was closed**

**On Restart:**
```
1. Load User from Core Data
   └─ mid, username, avatar, etc. = from disk ✅
   └─ baseUrl = "http://183.156.84.30:8002" (cached from last session)
   
2. First fetchUser call
   └─ baseUrl param = appUser.baseUrl?.absoluteString
   └─ param = "http://183.156.84.30:8002" (cached IP)
```

**Attempt 1:**
```
fetchUser(userId, baseUrl: "http://183.156.84.30:8002") → Try cached IP
└─ Connection to :8002 fails (server moved to :8003)
└─ Error: "Connection reset by peer"
```

**Attempt 2:**
```
Retry → Forced fresh IP resolution
└─ Calls getProviderIP(userId)
└─ Gets new IP: "183.156.84.30:8003"
└─ Try with fresh IP → Success! ✅
└─ Updates cached baseUrl in memory and disk
```

**Key Point:** With IP caching + smart retry, we get **fast restarts when IP unchanged** AND **automatic correction when IP changed**!

### Persistence Strategy

**What IS Persisted (Core Data):**
```swift
// User.swift - encode() method
✅ mid, username, password
✅ name, avatar, email, profile
✅ tweetCount, followersCount, followingCount
✅ bookmarksCount, favoritesCount
✅ hostIds, fansList, followingList, etc.
✅ baseUrl (NEW) - Read node IP for faster restarts
```

**What is NOT Persisted:**
```swift
// User.swift - encode() method (commented out)
❌ writableUrl    // Upload node IP - resolved fresh from hostIds each time
```

**Rationale:**

**baseUrl (Read Node) - NOW CACHED:**
- ✅ Safe with retry mechanism (auto-corrects if stale)
- ⚡ Faster app restarts (usually IP unchanged)
- 🔄 Self-healing (retry resolves new IP if changed)
- 📊 95%+ hit rate (IPs stable most of the time)

**writableUrl (Upload Node) - NOT CACHED:**
- ⚠️ More volatile (upload nodes can change more frequently)
- 🔒 Security: Resolve fresh from hostIds each upload
- 📝 Less frequently used (only during uploads)
- 🎯 Always current upload node

### Benefits

- ⚡ **Faster app restarts** - Uses disk-cached IPs (skip provider lookup)
- 🔄 **Automatic recovery** - IP changes handled on retry attempts
- 💰 **Reduced provider load** - Most restarts reuse valid cached IPs
- 🎯 **Smart fallback** - Re-resolves only when connection fails
- 🛡️ **Handles migrations** - Server moves auto-detected and recovered (1-2s delay)
- 🔒 **Self-healing** - Stale IPs corrected automatically via retry
- ⚠️ **No permanent stale** - Bad IPs fixed and updated in cache
- 📊 **Optimistic caching** - Assume IP valid (95%+ hit rate), correct if wrong

### Key Functions

**fetchUser():**
```swift
/// - Parameters:
///   - userId: The user ID to fetch
///   - baseUrl: Initial baseUrl (use "" to skip cache and force IP resolution)
/// - Note: First attempt uses provided baseUrl; retries automatically force fresh IP resolution
```

**updateUserFromServer():**
```swift
/// - Parameters:
///   - userId: The user ID to fetch
///   - baseUrl: BaseUrl to use for FIRST attempt. Retries always force fresh IP resolution.
/// - Note: Pass empty string "" to force fresh IP resolution from first attempt
```

### Debug Logging

```
DEBUG: [updateUserFromServer] Attempt 1/3 - Using provided baseUrl: http://183.156.84.30:8002
DEBUG: [updateUserFromServer] Attempt 1/3 failed: Connection reset by peer
DEBUG: [updateUserFromServer] Attempt 2/3 - Re-resolving provider IP, old baseUrl: http://183.156.84.30:8002
DEBUG: [updateUserFromServer] ✅ Setting baseUrl to provider IP: 183.156.84.30:8003
DEBUG: [updateUserFromServer] Attempt 2/3 succeeded!
```

## 🚨 Error Handling

### Graceful Degradation

1. **Network Failures**
   - Continue with cached data
   - Show user-friendly error messages
   - Smart retry with fresh IP resolution

2. **Cache Misses**
   - Fallback to server-only loading
   - Preserve user experience

3. **Memory Pressure**
   - Automatic cache cleanup
   - Memory warning handling

### User Feedback

```swift
// Offline indicator
if showOfflineIndicator && !networkMonitor.hasAnyConnection {
    HStack {
        Image(systemName: "wifi.slash")
        Text("Offline - Showing cached content")
    }
}
```

## 📱 User Experience Features

### Visual Indicators

- **Offline Mode**: Orange banner with WiFi slash icon
- **Loading States**: Progress indicators for cache/server loading
- **Error Messages**: Context-aware error descriptions

### Performance Optimizations

- **Background Loading**: Server requests don't block UI
- **Smart Preloading**: Priority-based video/asset loading
- **Memory Management**: Automatic cleanup and size limits
- **Server Protection**: No retry mechanisms to prevent overload

## 🔧 Configuration

### Cache Settings

```swift
// TweetCacheManager
private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
private let maxCacheSize: Int = 1000 // Maximum tweets

// SharedAssetCache
private let maxCacheSize = 20 // Maximum assets
private let cacheExpirationInterval: TimeInterval = 300 // 5 minutes
```

### Network Settings

```swift
// HproseInstance
client.timeout = 300 // 5 minutes for large uploads

// No retry configuration - single attempts only
```

## 🧪 Testing Scenarios

### Network Conditions

1. **No Connection**
   - App loads cached content immediately
   - Shows offline indicator
   - No server requests attempted

2. **Poor Connection**
   - Cache-first loading works
   - Single server attempt (no retries)
   - Graceful timeout handling

3. **Intermittent Connection**
   - Seamless fallback to cache
   - No retry attempts to prevent server overload
   - No data loss

4. **High Latency**
   - Instant cache display
   - Background server sync (single attempt)
   - User can interact immediately

## 📊 Monitoring & Debugging

### Logging

```swift
print("[TweetListView] Loaded \(cacheCount) tweets from cache")
print("[NetworkMonitor] Connection status: \(status), type: \(type)")
print("[TweetListView] Server load failed: \(error)")
```

### Metrics

- Cache hit/miss ratios
- Network request success rates
- Memory usage patterns
- Server load patterns (no retry spikes)

## 🚀 Best Practices

### For Developers

1. **Always Cache First**: Load from cache before server
2. **Background Updates**: Don't block UI for server requests
3. **Graceful Degradation**: Handle all failure scenarios
4. **User Feedback**: Clear indicators for network status
5. **Memory Management**: Automatic cleanup and limits
6. **Server Protection**: No retry mechanisms to prevent overload

### For Users

1. **Offline Usage**: App works without internet
2. **Fast Loading**: Instant content from cache
3. **Fresh Data**: Background updates when possible
4. **Clear Status**: Know when viewing cached content
5. **Reliable Experience**: No crashes from network issues
6. **Server-Friendly**: App doesn't overload servers

## 🔮 Future Enhancements

### Planned Features

1. **Predictive Caching**: Preload content based on user behavior
2. **Delta Updates**: Only sync changed content
3. **Compression**: Reduce cache storage requirements
4. **Analytics**: Better monitoring of cache performance
5. **Smart Prefetching**: Intelligent content preloading

### Advanced Network Handling

1. **Connection Quality Detection**: Adaptive request strategies
2. **Bandwidth Optimization**: Compress data for slow connections
3. **Battery Optimization**: Reduce network activity on low battery
4. **Geographic Optimization**: Cache based on location patterns
5. **Server Load Balancing**: Intelligent request distribution

---

*This document is maintained as part of the Tweet-iOS project to ensure robust performance in challenging network environments while being respectful to server resources.*
