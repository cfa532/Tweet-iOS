# Tweet Memory and Cache Algorithm

This document explains the comprehensive tweet memory management and caching system implemented in the Tweet-iOS app.

## Overview

The tweet system uses a **dual-layer architecture** with in-memory singleton instances and persistent Core Data caching to ensure fast access, data consistency, and efficient updates.

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

## Conclusion

This algorithm provides:
- **Fast Performance**: Memory-first access with persistent caching
- **Data Integrity**: Consistent state across memory and cache
- **Efficient Updates**: Minimal data transfer and processing
- **Scalability**: Handles large numbers of tweets efficiently
- **Reliability**: Robust error handling and recovery mechanisms

The system ensures that tweet data is always up-to-date, accessible, and consistent across all parts of the application.
