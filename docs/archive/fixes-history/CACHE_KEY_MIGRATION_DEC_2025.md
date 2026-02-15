# Cache Key Migration: main_feed → appUser.mid

## Date
December 2025

## Overview

Migrated the main feed cache key from `"main_feed"` to `appUser.mid` to enable user-specific caching that persists across logout/login cycles.

## Problem

The previous `"main_feed"` cache key had limitations:
1. **Shared cache**: All users shared the same cache key, causing potential cross-user contamination
2. **Cache cleared on logout**: Users lost their cached tweets when logging out, requiring full reload on re-login
3. **Commented tweets appearing in feed**: When commenting on a non-followed user's tweet, the tweet would be cached to `"main_feed"` and appear in the main feed

## Solution

### Cache Key Change
- **Before**: `"main_feed"` (shared across all users)
- **After**: `appUser.mid` (user-specific)

### Cache Persistence Policy
- **Cache NOT cleared on logout** - persists across sessions
- In-memory tweets are cleared on logout, but cache remains
- When user logs in, cache is loaded using the new `appUser.mid`
- Different users have completely separate caches

### Cache Clearing
- **Periodic**: Tweets older than 2 weeks are automatically deleted
- **Manual**: User can clear cache from settings
- **NOT on logout**: Provides faster re-login experience

## Implementation Changes

### TweetCacheManager.swift

```swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    // All tweets go to appUser.mid cache to persist across logouts
    // Cache is cleared periodically or manually by user, not on logout
    saveTweet(tweet, userId: appUserId)
}
```

**Before:**
```swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    if tweet.authorId == appUserId && tweet.isPrivate == true {
        saveTweet(tweet, userId: appUserId)
    } else {
        saveTweet(tweet, userId: "main_feed")
    }
}
```

### FollowingsTweetView.swift

```swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: viewModel.hproseInstance.appUser.mid, 
    page: page, 
    pageSize: size, 
    currentUserId: viewModel.hproseInstance.appUser.mid)
```

**Before:**
```swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: "main_feed", 
    page: page, 
    pageSize: size, 
    currentUserId: appUser.mid)
```

### FollowingsTweetViewModel.swift

```swift
func clearTweets() {
    tweets.removeAll()
    // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
}
```

**Before:**
```swift
func clearTweets() {
    tweets.removeAll()
    TweetCacheManager.shared.clearCacheForUser(userId: "main_feed")
}
```

### HproseInstance.swift

```swift
func logout() async {
    preferenceHelper?.setUserId(nil as String?)
    
    // Don't clear tweet cache on logout - cache persists per user and is cleared periodically or manually
    ChatCacheManager.shared.clearAllCache()
    await CachingPlayerItem.clearAllCache()
    
    // Reset appUser to guest user
    let guestUser = User.getInstance(mid: Constants.GUEST_ID)
    await MainActor.run {
        guestUser.baseUrl = appUser.baseUrl
        guestUser.followingList = Gadget.getAlphaIds()
        self.appUser = guestUser
    }
    
    Task {
        await fetchAlphaIdUserForGuest()
    }
}
```

**Before:**
```swift
func logout() async {
    // ... 
    TweetCacheManager.shared.clearCacheOnSignout()
    // ...
}
```

## Files Modified

1. **`Sources/Core/TweetCacheManager.swift`**
   - `updateTweetInAppUserCaches()`: Simplified to save all tweets to `appUserId`
   - Removed conditional logic for `"main_feed"` vs `appUser.mid`

2. **`Sources/Features/Home/FollowingsTweetView.swift`**
   - Cache loading now uses `appUser.mid` instead of `"main_feed"`

3. **`Sources/Features/Home/FollowingsTweetViewModel.swift`**
   - All cache save operations use `appUser.mid`
   - `clearTweets()` no longer clears cache
   - Removed `clearCacheForUser()` call

4. **`Sources/Features/Profile/ProfileTweetsSection.swift`**
   - Cache loading now uses `appUser.mid` instead of `"main_feed"`
   - Profile filters by `authorId` to show appropriate tweets

5. **`Sources/Core/HproseInstance.swift`**
   - `logout()` no longer calls `clearCacheOnSignout()`
   - `initAppEntry()` calls `deleteExpiredTweets()` for periodic cleanup

## Benefits

- ✅ **User Isolation**: Each user has their own cache, no cross-user data leakage
- ✅ **Faster Re-login**: Cache persists across logout, providing instant load on re-login
- ✅ **Simplicity**: Single cache key instead of multiple keys
- ✅ **Flexibility**: Profile filters by `authorId`, allowing proper display of public/private tweets
- ✅ **Periodic Cleanup**: Old tweets automatically expire after 2 weeks
- ✅ **Commented Tweets**: Tweets from non-followed users (when commented) appear temporarily in feed (by design)

## Migration Notes

- Existing `"main_feed"` cache entries will gradually expire (2-week TTL)
- New tweets are cached to `appUser.mid` immediately
- No manual migration needed - transparent transition
- Users logging back in will see their cached tweets from previous sessions

---

## Update: Dual-Strategy Cache (January 2026)

### Context-Based Caching Strategy

The cache strategy was refined to use a **dual-strategy approach** based on context:

**Main Feed:**
- **Cache Key**: `appUser.mid`
- All tweets in main feed cached under `appUser.mid`
- Efficient single-cache lookup for aggregate main feed
- Used by main feed and appUser's profile (with filtering)

**Profile View:**
- **Cache Key**: `tweet.authorId`
- Tweets cached under their author's ID
- Author-specific cache for direct profile lookup
- Used by other users' profiles

**Single Tweet:**
- **Cache Key**: `authorId`
- Consistent with profile caching strategy

**Benefits:**
- ✅ **Performance**: Main feed uses single cache lookup (appUser.mid) for all tweets
- ✅ **Flexibility**: Profile uses author-specific cache (authorId) for direct lookup
- ✅ **Efficiency**: No unnecessary filtering for main feed, direct lookup for profiles
- ✅ **Consistency**: Single tweet strategy matches profile strategy (authorId)

**Implementation:**

```swift
// Main feed: Cache under appUser.mid
TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)

// Profile: Cache under authorId
TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)

// Single tweet: Cache under authorId
TweetCacheManager.shared.saveTweet(tweet, userId: authorId)
```

**Cache Loading:**

```swift
// Main feed: Load from appUser.mid
fetchCachedTweets(for: appUser.mid, ...)

// AppUser's profile: Load from appUser.mid with filtering
fetchCachedTweets(for: appUser.mid, currentUserId: appUser.mid)
// Automatically filters to show only appUser's tweets

// Other user's profile: Load from userId (authorId)
fetchCachedTweets(for: userId, ...)
// Direct lookup from author's cache
```

**Note:** See `docs/TWEET_CACHE_STRATEGY.md` for complete documentation.
