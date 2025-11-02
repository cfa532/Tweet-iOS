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

**Implementation in `updateUserFromServer()`:**

```swift
func updateUserFromServer(_ userId: String, baseUrl: String = ...) async throws -> User? {
    for attempt in 1...3 {
        // First attempt: Use provided baseUrl (fast, usually works)
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
- ✅ App initialization (fresh start needs latest IP)
- ✅ Explicit user refresh (pull-to-refresh)
- ✅ After extended background (>30s)
- ✅ Manual profile refresh

**Use Cached IP First** (use default baseUrl):
- ✅ Normal user fetches (author loading, etc.)
- ✅ Background updates
- ✅ Quick lookups

### Flow Example

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

### Benefits

- ⚡ **Faster first attempts** - No unnecessary IP lookups
- 🔄 **Automatic recovery** - IP changes handled on retry
- 💰 **Reduced provider load** - Fewer IP resolution calls
- 🎯 **Smart fallback** - Only re-resolve when needed
- 🛡️ **Handles migrations** - Server moves detected and handled

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
