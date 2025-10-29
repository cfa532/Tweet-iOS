# Memory and Cache Algorithm

This document explains the comprehensive memory management and caching system for both tweets and users implemented in the Tweet-iOS app.

## Overview

The system uses a **dual-layer architecture** with in-memory singleton instances and persistent Core Data caching to ensure fast access, data consistency, and efficient updates. This architecture is applied to both tweets and users with specific optimizations for each.

## Architecture

### 1. Memory Layer (Singleton Pattern)
- **Purpose**: Fast in-memory access and real-time updates
- **Implementation**: `Tweet.getInstance()` singleton pattern
- **Key Feature**: Automatic instance reuse and update

### 2. Cache Layer (Core Data)
- **Purpose**: Persistent storage and offline access
- **Implementation**: `TweetCacheManager` with Core Data
- **Key Feature**: Dual-cache strategy (main_feed + user profile)

## Memory Management Algorithm

### Tweet Singleton Pattern

```swift
class Tweet: Identifiable, Codable, ObservableObject {
    // Singleton dictionary to store all tweet instances
    private static var instances: [MimeiId: Tweet] = [:]
    private static let instanceLock = NSLock()
    
    static func getInstance(mid: MimeiId, authorId: MimeiId, ...) -> Tweet {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        
        if let existingInstance = instances[mid] {
            // Update existing instance with new values
            existingInstance.favoriteCount = favoriteCount
            existingInstance.bookmarkCount = bookmarkCount
            existingInstance.retweetCount = retweetCount
            existingInstance.commentCount = commentCount
            if let favorites = favorites { existingInstance.favorites = favorites }
            // ... other updates
            return existingInstance
        }
        
        // Create new instance if none exists
        let newInstance = Tweet(...)
        instances[mid] = newInstance
        return newInstance
    }
}
```

**Benefits:**
- ✅ **No Duplicates**: Same tweet ID always returns same instance
- ✅ **Automatic Updates**: Existing instances are updated with new data
- ✅ **Memory Efficiency**: Prevents multiple instances of same tweet
- ✅ **Thread Safety**: NSLock ensures thread-safe access

## Cache Management Algorithm

### Dual-Cache Strategy

The system maintains two separate caches:

1. **Main Feed Cache** (`uid: "main_feed"`)
   - Used by `FollowingTweetView`
   - Contains tweets from user's following feed
   - Separate from profile browsing

2. **User Profile Cache** (`uid: appUser.mid`)
   - Used by `ProfileView` (only for appUser's profile)
   - Contains tweets from appUser's profile
   - Not used for other users' profiles

### Cache Update Policy

```swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    // Always update in main_feed cache
    saveTweet(tweet, userId: "main_feed")
    
    // Also update in appUser's profile cache if the tweet belongs to the appUser
    if tweet.authorId == appUserId {
        saveTweet(tweet, userId: appUserId)
    }
}
```

**Benefits:**
- ✅ **Consistency**: Updates reflected in both caches
- ✅ **Efficiency**: Only caches appUser's own tweets in profile cache
- ✅ **Separation**: Main feed and profile data are isolated

## Complete Data Flow

### 1. Server Update → Memory

```swift
// Example: User favorites a tweet
func toggleFavorite(_ tweet: Tweet) async throws -> (Tweet?, User?) {
    // 1. Server call returns updated tweet data
    let response = client.invoke("runMApp", withArgs: [entry, params])
    
    // 2. Update in-memory tweet instance
    if let tweetDict = response["tweet"] as? [String: Any] {
        updatedTweet = try Tweet.from(dict: tweetDict)
        // Memory instance is automatically updated via singleton pattern
    }
    
    // 3. Save updated tweet to both caches
    TweetCacheManager.shared.updateTweetInAppUserCaches(updatedTweet!, appUserId: appUser.mid)
    
    return (updatedTweet, updatedUser)
}
```

### 2. Memory → Cache Storage

```swift
func saveTweet(_ tweet: Tweet, userId: String) {
    context.performAndWait {
        // Check if tweet already exists in cache
        let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
        request.predicate = NSPredicate(format: "tid == %@", tweet.mid)
        
        if let existingTweet = try? context.fetch(request).first {
            // Update existing cache entry
            cdTweet = existingTweet
        } else {
            // Create new cache entry
            cdTweet = CDTweet(context: context)
        }
        
        // Always save the current in-memory tweet state to cache
        // This ensures that any updates made to the tweet in memory are preserved
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let tweetData = try? encoder.encode(tweet) {
            cdTweet.tweetData = tweetData
        }
        
        // Update metadata
        cdTweet.tid = tweet.mid
        cdTweet.uid = userId
        cdTweet.timestamp = tweet.timestamp
        cdTweet.timeCached = Date()
        
        try? context.save()
    }
}
```

### 3. Cache → Memory (Loading)

```swift
func fetchCachedTweets(for userId: String, page: UInt, pageSize: UInt) async -> [Tweet?] {
    return await withCheckedContinuation { continuation in
        context.perform {
            let request: NSFetchRequest<CDTweet> = CDTweet.fetchRequest()
            request.predicate = NSPredicate(format: "uid == %@", userId)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.fetchOffset = Int(page * pageSize)
            request.fetchLimit = Int(pageSize)
            
            if let cdTweets = try? self.context.fetch(request) {
                var tweets: [Tweet?] = []
                for cdTweet in cdTweets {
                    do {
                        // Decode cached tweet data
                        let tweet = try Tweet.from(cdTweet: cdTweet)
                        // Tweet.getInstance() ensures singleton pattern is maintained
                        tweets.append(tweet)
                    } catch {
                        tweets.append(nil)
                    }
                }
                continuation.resume(returning: tweets)
            } else {
                continuation.resume(returning: [])
            }
        }
    }
}
```

## Cache Loading Strategy

### FollowingTweetView
```swift
// Load from main_feed cache
if isFromCache {
    let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
        for: "main_feed", page: page, pageSize: size, currentUserId: appUser.mid)
    return cachedTweets
}
```

### ProfileView
```swift
// Load from user profile cache (only for appUser)
if isFromCache {
    if user.mid == hproseInstance.appUser.mid {
        let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
            for: user.mid, page: page, pageSize: size, currentUserId: appUser.mid)
        return cachedTweets
    } else {
        // Don't cache other users' tweets
        return []
    }
}
```

## Key Features

### 1. No Data Replacement
- ✅ **Memory**: Existing instances are updated, not replaced
- ✅ **Cache**: Existing cache entries are updated, not replaced
- ✅ **Consistency**: All updates preserve existing data structure

### 2. Five Count Fields Updated
When tweets are updated from server, only these fields are modified:
- `favoriteCount`
- `bookmarkCount`
- `retweetCount`
- `commentCount`
- `favorites` (user interaction flags)

### 3. Data Preservation
All other tweet data remains unchanged:
- `content`
- `attachments`
- `isPrivate`
- `downloadable`
- `timestamp`
- `author` information

### 4. Thread Safety
- ✅ **Memory**: NSLock protects singleton dictionary
- ✅ **Cache**: Core Data context performs operations on background queue
- ✅ **Updates**: MainActor ensures UI updates happen on main thread

## Performance Benefits

### 1. Fast Access
- **Memory**: O(1) access to tweet instances
- **Cache**: Indexed Core Data queries for fast retrieval
- **Network**: Cache-first loading strategy

### 2. Memory Efficiency
- **Singleton Pattern**: Prevents duplicate instances
- **Automatic Cleanup**: Core Data manages cache size and expiration
- **Background Operations**: Non-blocking cache operations

### 3. Data Consistency
- **Single Source of Truth**: Memory instances are authoritative
- **Dual Cache Updates**: Changes reflected in both caches
- **Automatic Sync**: Memory and cache stay synchronized

## Error Handling

### 1. Cache Miss
- Fallback to server fetch
- Automatic cache population on successful fetch
- Graceful degradation

### 2. Corrupted Data
- Automatic cleanup of invalid timestamps
- Fallback to server data
- Error logging for debugging

### 3. Memory Warnings
- Automatic cache cleanup
- Memory pressure handling
- Preserved data integrity

## Usage Examples

### Creating/Updating Tweets
```swift
// Always use getInstance to ensure singleton pattern
let tweet = Tweet.getInstance(
    mid: "tweet123",
    authorId: "user456",
    favoriteCount: 42,
    bookmarkCount: 7,
    retweetCount: 15,
    commentCount: 3
)
```

### Caching Tweets
```swift
// Cache in main feed
TweetCacheManager.shared.saveTweet(tweet, userId: "main_feed")

// Cache in user profile (if it's the appUser's tweet)
if tweet.authorId == appUser.mid {
    TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
}
```

### Loading from Cache
```swift
// Load main feed tweets
let mainFeedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: "main_feed", page: 0, pageSize: 20, currentUserId: appUser.mid)

// Load user profile tweets
let profileTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: appUser.mid, page: 0, pageSize: 20, currentUserId: appUser.mid)
```

## User Cache Management Algorithm

The user caching system uses a similar dual-layer architecture but with special handling for IP addresses to support automatic recovery from server IP changes.

### User Singleton Pattern

```swift
class User: ObservableObject, Codable, Identifiable {
    // Singleton dictionary for user instances
    private static var userInstances: [MimeiId: User] = [:]
    private static let userInstancesQueue = DispatchQueue(label: "user.instances.queue")
    
    static func getInstance(mid: MimeiId) -> User {
        return userInstancesQueue.sync {
            if let existingUser = userInstances[mid] {
                return existingUser
            }
            let newUser = User(mid: mid)
            userInstances[mid] = newUser
            return newUser
        }
    }
}
```

**Benefits:**
- ✅ **Single Instance**: Same user ID always returns same instance
- ✅ **Thread Safety**: Serial queue ensures safe concurrent access
- ✅ **Memory Efficiency**: No duplicate user objects
- ✅ **Automatic Updates**: Instance updates propagate to all references

### User Cache Strategy (Two-Tier with IP Optimization)

The user cache has two layers with special handling for server IP addresses:

#### 1. Memory Layer (In-Memory Singleton)
- **Purpose**: Fast access and temporary state
- **Contains**: All user data including resolved IP addresses
- **IP Resolution**: Cached for 30-minute windows
- **Lifetime**: Until app termination or memory pressure

#### 2. Disk Layer (Core Data)
- **Purpose**: Persistent storage and offline access
- **Contains**: User data (username, avatar, hostIds, etc.)
- **IP Storage**: **NOT persisted** (resolved fresh each session)
- **TTL**: 30 minutes before requiring refresh

### IP Address Management

**Key Insight:** Server IP addresses can change while `hostIds` remain constant. To handle this, IPs are treated as **ephemeral** and not persisted to disk.

#### IP Resolution Algorithm

```swift
// 1. Loading from Core Data
static func from(cdUser: CDUser) -> User {
    if let userData = cdUser.userData,
       let decodedUser = try? JSONDecoder().decode(User.self, from: userData) {
        // baseUrl and writableUrl are not persisted to Core Data
        // They will be nil and resolved fresh on first use
        updateUserInstance(with: decodedUser)
    }
    return getInstance(mid: cdUser.mid ?? Constants.GUEST_ID)
}

// 2. Preserving Memory-Cached IPs
static func updateUserInstance(with user: User) {
    let instance = getInstance(mid: user.mid)
    
    // Update all properties
    instance.name = user.name
    instance.hostIds = user.hostIds
    
    // Only update IPs if new value is non-nil
    // This preserves memory-cached IPs when loading from disk
    if let newBaseUrl = user.baseUrl {
        instance.baseUrl = newBaseUrl
    }
    if let newWritableUrl = user.writableUrl {
        instance.writableUrl = newWritableUrl
    }
}

// 3. Re-resolving on Cache Expiry
func updateUserFromServer(_ userId: String) async throws -> User? {
    let user = User.getInstance(mid: userId)
    
    // Always re-resolve IP address from provider
    // Even if we have a cached baseUrl, the hostId might now resolve to a different IP
    guard let providerIP = try await self.getProviderIP(userId) else {
        throw NSError(...)
    }
    user.baseUrl = URL(string: "http://\(providerIP)")!
    
    // Fetch user data from server
    try await updateUserFromServerInternal(user)
    return user
}

// 4. Checking Cache Validity
func fetchUser(_ userId: String) async throws -> User? {
    let cachedUser = TweetCacheManager.shared.fetchUser(mid: userId)
    
    // Return cached user only if:
    // 1. Valid username exists
    // 2. Cache hasn't expired (< 30 minutes)
    // 3. IP address is resolved (baseUrl != nil)
    if cachedUser.username != nil && !cachedUser.hasExpired && cachedUser.baseUrl != nil {
        return cachedUser
    }
    
    // Re-resolve if baseUrl is nil (loaded from disk)
    if cachedUser.username != nil && cachedUser.baseUrl == nil {
        // Fall through to updateUserFromServer
    }
    
    // Update from server
    return try await updateUserFromServer(userId)
}
```

### IP Resolution Lifecycle

```
App Start
  ↓
Load User from Core Data (baseUrl = nil, writableUrl = nil)
  ↓
Memory Instance (baseUrl = nil preserved, not overwritten)
  ↓
First API Call Needs User
  ↓
fetchUser() → Detects baseUrl == nil
  ↓
updateUserFromServer() → Calls getProviderIP()
  ↓
Resolve IP: 192.168.1.10 → Cache in Memory
  ↓
Next 30 minutes
  ├─ API calls → Use cached IP (no re-resolution) ✅
  ├─ fetchUser() → Returns memory instance (instant) ✅
  └─ Load from Core Data → Preserves memory IP ✅
  ↓
After 30 minutes (Cache Expires)
  ↓
fetchUser() → Detects hasExpired == true
  ↓
updateUserFromServer() → Calls getProviderIP()
  ↓
Get Fresh IP: 192.168.1.20 (if changed) ✅
  ↓
Update Memory & Core Data → New 30-minute window
```

### User Data Encoding/Decoding

```swift
// Encoding: Don't persist IPs to disk
func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    
    try container.encode(mid, forKey: .mid)
    // Don't encode baseUrl/writableUrl - resolved fresh each session
    // try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
    // try container.encodeIfPresent(writableUrl, forKey: .writableUrl)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(username, forKey: .username)
    try container.encodeIfPresent(hostIds, forKey: .hostIds)
    // ... other fields
}

// Decoding: IPs will be nil after decoding from disk
required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    mid = try container.decode(String.self, forKey: .mid)
    baseUrl = try container.decodeIfPresent(URL.self, forKey: .baseUrl)  // Will be nil
    writableUrl = try container.decodeIfPresent(URL.self, forKey: .writableUrl)  // Will be nil
    name = try container.decodeIfPresent(String.self, forKey: .name)
    // ... other fields
}
```

### Performance Characteristics

#### IP Resolution Frequency

| Scenario | Resolution Calls | Performance |
|----------|-----------------|-------------|
| **App Start** | 1 per user | First access only |
| **Within 30-min window** | 0 | Instant (memory cache) ✅ |
| **Cache expiry (30 min)** | 1 per user | Once per window |
| **Load from Core Data** | 0 | Preserves memory cache ✅ |

#### Example Timeline
```
00:00 - App start, load user from disk (baseUrl = nil)
00:01 - First access → Resolve IP → Cache in memory
00:10 - API call → Use memory cache (0 calls) ✅
00:20 - fetchUser() → Use memory cache (0 calls) ✅
00:30 - Cache expires → Re-resolve IP → Cache in memory
00:40 - API call → Use memory cache (0 calls) ✅
01:00 - Cache expires → Re-resolve IP → Cache in memory
```

**Total:** ~2 IP resolutions per hour per user = **0.0005 calls/second** (negligible)

### Benefits of IP-Optimized Strategy

#### 1. Automatic IP Change Recovery
- ✅ Server IPs can change without breaking the app
- ✅ Recovery within 30 minutes (next cache expiry)
- ✅ No manual cache clearing required

#### 2. Performance Optimization
- ✅ IPs cached in memory for 30-minute windows
- ✅ No unnecessary re-resolutions between cache periods
- ✅ ~99% of calls use memory cache (instant access)

#### 3. Correctness
- ✅ Always get fresh IPs after cache expiry
- ✅ Memory cache preserved when loading from disk
- ✅ Handles app restarts gracefully

#### 4. Minimal Overhead
- ✅ 1 lightweight network call per 30 minutes per user
- ✅ `getProviderIP()` is a simple lookup (~50-200ms)
- ✅ Acceptable trade-off for resilience

### User Cache TTL and Expiration

```swift
// Check if user cache has expired (30 minutes)
func hasExpired(mid: String) -> Bool {
    var hasExpired = true
    context.performAndWait {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", mid)
        if let cdUser = try? context.fetch(request).first {
            hasExpired = cdUser.timeCached?.timeIntervalSinceNow ?? 0 < -1800 // 30 minutes
        }
    }
    return hasExpired
}
```

**Expiration Policy:**
- **TTL**: 30 minutes from last cache
- **On Expiry**: Trigger IP re-resolution and data refresh
- **Long-Term**: Core Data cleanup removes users cached > 1 month

### User Cache Update Flow

```swift
// Complete user cache update flow
func saveUser(_ user: User) {
    context.performAndWait {
        let request: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        request.predicate = NSPredicate(format: "mid == %@", user.mid)
        let cdUser = (try? context.fetch(request).first) ?? CDUser(context: context)
        
        cdUser.mid = user.mid
        cdUser.timeCached = Date()
        
        // Encode user data (without IPs)
        if let userData = try? JSONEncoder().encode(user) {
            cdUser.userData = userData
        }
        
        try? context.save()
    }
}
```

## Comparison: Tweet vs User Caching

| Aspect | Tweet Caching | User Caching |
|--------|--------------|--------------|
| **Memory** | Singleton instances | Singleton instances |
| **Disk** | Full data persisted | Full data except IPs |
| **TTL** | 30 days | 30 minutes |
| **Update Frequency** | On user interaction | On cache expiry |
| **Cache Key** | Tweet ID + User ID | User ID only |
| **Dual Cache** | main_feed + profile | Single cache |
| **Special Handling** | Count fields | IP addresses |

## Conclusion

This comprehensive caching algorithm provides:
- **Fast Performance**: Memory-first access with persistent caching
- **Data Integrity**: Consistent state across memory and cache
- **Efficient Updates**: Minimal data transfer and processing
- **Scalability**: Handles large numbers of tweets and users efficiently
- **Reliability**: Robust error handling and recovery mechanisms
- **IP Resilience**: Automatic recovery from server IP changes within 30 minutes
- **Optimal Balance**: Performance (memory caching) + Correctness (periodic re-resolution)

The system ensures that both tweet and user data is always up-to-date, accessible, and consistent across all parts of the application, with special optimizations for handling dynamic server infrastructure.
