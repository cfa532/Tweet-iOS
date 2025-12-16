# Unified Cache Strategy for Tweet Storage

## Date
October 16, 2025 (Initial implementation)
December 2025 (Updated to user-specific cache with persistence)

## Overview

Implemented a **unified cache strategy** that eliminates duplication and properly handles private tweets while ensuring data consistency across main feed and profile views.

**Latest Update (January 2026):** Implemented dual-strategy caching:
- **Main Feed**: All tweets cached under `appUser.mid` for efficient aggregate loading
- **Profile View**: Tweets cached under their `authorId` for author-specific loading
- **Single Tweet**: Cached under `authorId` for consistency

This balances performance (fast main feed loading) with flexibility (author-specific caching for profiles). Cache persists across logouts and is cleared periodically (2 weeks) or manually by user.

**Previous Update (December 2025):** Cache key changed from `"main_feed"` to `appUser.mid` to enable user-specific caching that persists across logouts.

## Previous Architecture (Problems)

### Dual-Cache Approach
```
Main Feed:
  - All tweets (including appUser's) → "main_feed" cache

Profile View:
  - AppUser's tweets → appUser.mid cache
  - Separate from main_feed
```

**Problems:**
1. ❌ AppUser's public tweets stored in TWO caches (duplication)
2. ❌ Wasted disk space
3. ❌ Inconsistency between caches
4. ❌ Profile sometimes showed "No tweets" when main feed had them

## New Architecture (Solution)

### Dual-Strategy Cache (Current - January 2026)

```
Cache Structure:
  Main Feed (appUser.mid cache):
    - All tweets visible in main feed cached under appUser.mid
    - Aggregates tweets from multiple authors
    - Efficient single-cache loading for main feed
    - Used for main feed and appUser's profile (with filtering)
  
  Profile (authorId cache):
    - Tweets cached under their author's ID (authorId)
    - Author-specific cache for profile views
    - Direct lookup without filtering needed
    - Used for other users' profiles
  
  Persistence:
    - Cache persists across logout/login cycles
    - Cleared periodically (2 weeks) or manually by user
```

**Previous Strategy (December 2025):**
```
  appUser.mid cache:
    - All tweets visible to current user (following feed, public, private)
    - User-specific cache key (each user has separate cache)
    - Persists across logout/login cycles
    - Cleared periodically (2 weeks) or manually by user
```

**Previous Architecture (October 2025):**
```
  "main_feed" cache:
    - Following users' public tweets
    - AppUser's public tweets ← Unified!
  
  appUser.mid cache:
    - AppUser's private tweets ONLY ← Privacy!
```

## Implementation Details

### Caching Logic - Current (January 2026)

**Main Feed:**
```swift
// In HproseInstance.fetchTweetFeed()
TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
```

**Profile View:**
```swift
// In HproseInstance.fetchUserTweets()
TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
```

**Single Tweet:**
```swift
// In HproseInstance.getTweet()
TweetCacheManager.shared.saveTweet(tweet, userId: authorId)
```

**Update Method:**
```swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    // Cache main feed tweets under appUser.mid
    saveTweet(tweet, userId: appUserId)
}
```

**Previous Implementation (October 2025):**
```swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    if tweet.authorId == appUserId && tweet.isPrivate == true {
        // AppUser's private tweet - save only to profile cache
        saveTweet(tweet, userId: appUserId)
    } else {
        // Public tweet (any user) - save to unified main_feed cache
        saveTweet(tweet, userId: "main_feed")
    }
}
```

### Cache Loading Logic - Current (January 2026)

**Main Feed:**
```swift
// In FollowingsTweetView.swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: viewModel.hproseInstance.appUser.mid, 
    page: page, 
    pageSize: size, 
    currentUserId: viewModel.hproseInstance.appUser.mid)
```

**Profile Loading (TweetCacheManager.fetchCachedTweets):**
```swift
// For appUser's profile: Use mainfeed cache with filtering
if let currentUserId = currentUserId, userId == currentUserId {
    cacheKey = currentUserId  // appUser.mid
    shouldFilterByAuthorId = true  // Filter to show only appUser's tweets
} else {
    // For other users' profiles: Use their authorId cache
    cacheKey = userId  // equals authorId
    shouldFilterByAuthorId = false
}
```

**Profile View:**
```swift
// In ProfileTweetsSection.swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: user.mid,  // userId for profile (equals authorId)
    page: page, 
    pageSize: size, 
    currentUserId: hproseInstance.appUser.mid)
```

**Previous Implementation (October 2025):**
```swift
if isFromCache {
    if user.mid == hproseInstance.appUser.mid {
        // 1. Load public tweets from main_feed cache
        let mainFeedTweets = await fetchCachedTweets(for: "main_feed", ...)
        
        // 2. Load private tweets from profile cache
        let privateTweets = await fetchCachedTweets(for: user.mid, ...)
        
        // 3. Merge both caches
        var allTweets = (mainFeedTweets + privateTweets).compactMap { $0 }
        // ... rest of logic
    }
}
```

### Profile Caching Logic - Current (January 2026)

```swift
// Profile tweets are cached under their authorId
for tweet in filteredTweets.compactMap({ $0 }) {
    TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
}
```

**Note:** Profile tweets use `authorId` as cache key, which equals `userId` for profile view. This enables direct author-based cache lookup without filtering.

**Previous Implementation (October 2025):**
```swift
if shouldCache && user.mid == hproseInstance.appUser.mid {
    for tweet in filteredTweets.compactMap({ $0 }) {
        if tweet.isPrivate == true {
            // Private → profile cache only
            saveTweet(tweet, userId: user.mid)
        } else {
            // Public → unified main_feed cache
            saveTweet(tweet, userId: "main_feed")
        }
    }
}
```

## Data Flow Examples

### Example 1: AppUser Posts Public Tweet

```
1. User creates public tweet
   ↓
2. Tweet saved to server
   ↓
3. Notification: .newTweetCreated
   ↓
4. Main Feed: updateTweetInAppUserCaches()
   ↓
5. Cache: "main_feed" ✅
   ↓
6. Profile loads from cache:
   - Load "main_feed" → Finds tweet ✅
   - Filter by authorId → Shows tweet ✅
```

### Example 2: AppUser Posts Private Tweet

```
1. User creates private tweet
   ↓
2. Tweet saved to server
   ↓
3. Notification: .newTweetCreated
   ↓
4. Main Feed: Skips (isPrivate == true)
   ↓
5. Profile: updateTweetInAppUserCaches()
   ↓
6. Cache: appUser.mid only ✅
   ↓
7. Main Feed loads from cache:
   - Load "main_feed" → NOT found ✅ (privacy preserved)
   ↓
8. Profile loads from cache:
   - Load "main_feed" → Public tweets
   - Load appUser.mid → Finds private tweet ✅
   - Shows both ✅
```

### Example 3: Privacy Toggle (Public → Private)

```
1. User toggles public tweet to private
   ↓
2. Server updates tweet.isPrivate = true
   ↓
3. Notification: .tweetPrivacyChanged
   ↓
4. updateTweetInAppUserCaches() called
   ↓
5. Cache UPDATE:
   - Delete from "main_feed" (if exists)
   - Save to appUser.mid ✅
   ↓
6. Main Feed removes tweet (no longer public)
   ↓
7. Profile keeps tweet (still visible to owner)
```

## Benefits

### 1. Storage Efficiency
- **Before:** AppUser's 100 public tweets × 2 caches = 200 cache entries
- **After:** AppUser's 100 public tweets × 1 cache = 100 cache entries
- **Savings:** 50% reduction in duplicate storage ✅

### 2. Data Consistency
- ✅ Single source of truth for public tweets
- ✅ Main feed and profile show identical public tweets
- ✅ No sync issues between caches

### 3. Privacy Compliance
- ✅ Private tweets never appear in main_feed cache
- ✅ Private tweets only in profile-specific cache
- ✅ Clear separation of public/private data

### 4. Performance
- ✅ Faster cache loading (less data to fetch)
- ✅ Reduced disk I/O
- ✅ More efficient memory usage

### 5. Correctness
- ✅ Profile always shows all appUser's tweets
- ✅ Main feed never shows private tweets
- ✅ No "No tweets yet" when tweets exist

## Cache Distribution

### Main Feed Cache (appUser.mid)
```
Contents:
  - All tweets visible in main feed (from multiple authors)
  - Aggregated cache for efficient main feed loading

Used By:
  - FollowingTweetView (main feed)
  - ProfileView (appUser's profile, with filtering)

Cache Key:
  - appUser.mid

Privacy Level:
  - Public tweets only (private filtered out during loading)
```

### Profile Cache (authorId)
```
Contents:
  - Tweets from a specific author
  - Author-specific cache for profile views

Used By:
  - ProfileView (other users' profiles)

Cache Key:
  - tweet.authorId (equals userId for profile view)

Privacy Level:
  - Author's tweets (public and private, filtered by visibility rules)
```

## Testing Scenarios

### Test 1: Public Tweet in Both Views
```
1. Create public tweet
2. Check main feed → ✅ Appears
3. Check profile → ✅ Appears
4. Check cache:
   - "main_feed" → ✅ Has tweet
   - appUser.mid → ❌ Doesn't have tweet (no duplication)
```

### Test 2: Private Tweet in Profile Only
```
1. Create private tweet
2. Check main feed → ❌ Doesn't appear (privacy)
3. Check profile → ✅ Appears
4. Check cache:
   - "main_feed" → ❌ Doesn't have tweet (privacy)
   - appUser.mid → ✅ Has tweet
```

### Test 3: Privacy Toggle
```
1. Create public tweet (in main_feed cache)
2. Toggle to private
3. Check main feed → ❌ Removed
4. Check profile → ✅ Still visible
5. Check cache:
   - "main_feed" → ❌ Removed
   - appUser.mid → ✅ Moved here
```

### Test 4: Profile Cache Loading
```
1. View profile → loads tweets from server
2. Caching happens:
   - Public tweets → "main_feed"
   - Private tweets → appUser.mid
3. Navigate away and back
4. Profile loads from cache:
   - Merges "main_feed" + appUser.mid
   - Filters by appUser.mid
   - ✅ Shows all tweets instantly
```

## Files Modified

1. **`/Sources/Core/TweetCacheManager.swift`**
   - Lines 286-294: Updated `updateTweetInAppUserCaches()` with unified strategy

2. **`/Sources/Features/Profile/ProfileTweetsSection.swift`**
   - Lines 193-220: Load from both caches and merge
   - Lines 72-80: Save public tweets to "main_feed"
   - Lines 105-111: Cache new tweets with privacy handling

3. **`/docs/MEMORY_CACHE_ALGORITHM.md`**
   - Updated cache strategy documentation

## Migration Impact

**Existing Cache:**
- Old "main_feed" cache: Still valid ✅
- Old appUser.mid cache: May have duplicates
- Over time: Old duplicates expire (30-day TTL)
- No manual migration needed

**User Experience:**
- Transparent migration
- No data loss
- Gradual cleanup of duplicates

## Conclusion

The unified cache strategy eliminates duplication of public tweets while properly isolating private tweets. AppUser's public tweets are stored once in the "main_feed" cache and appear in both main feed and profile views. Private tweets are isolated to the profile cache for proper privacy handling.

**Key Benefits:**
- ✅ 50% reduction in cache duplication
- ✅ Consistent data across views
- ✅ Proper privacy isolation
- ✅ Better performance and efficiency

---

## Update: User-Specific Cache with Persistence (December 2025)

### Changes Made

The cache strategy was further refined to use user-specific cache keys that persist across logouts:

1. **Cache Key Change**: `"main_feed"` → `appUser.mid`
   - Each user now has their own cache identified by their `mid`
   - Eliminates cross-user cache contamination
   - Enables cache persistence across logout/login cycles

2. **Cache Persistence Policy**
   - Cache is **NOT cleared on logout** - persists across sessions
   - In-memory tweets are cleared on logout, but cache remains
   - When user logs in, cache is loaded using the new `appUser.mid`
   - Different users have completely separate caches

3. **Simplified Cache Logic**
   - All tweets (public and private) go to `appUser.mid` cache
   - Profile view filters by `authorId` to show appropriate tweets
   - No more dual-cache merging logic

4. **Cache Clearing**
   - Periodic cleanup: Tweets older than 2 weeks are automatically deleted
   - Manual clearing: User can clear cache from settings
   - **NOT cleared on logout** - provides faster re-login experience

### Updated Implementation

```swift
// TweetCacheManager.swift
func updateTweetInAppUserCaches(_ tweet: Tweet, appUserId: String) {
    // All tweets go to appUser.mid cache to persist across logouts
    // Cache is cleared periodically or manually by user, not on logout
    saveTweet(tweet, userId: appUserId)
}
```

```swift
// FollowingsTweetView.swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: viewModel.hproseInstance.appUser.mid, 
    page: page, 
    pageSize: size, 
    currentUserId: viewModel.hproseInstance.appUser.mid)
```

```swift
// FollowingsTweetViewModel.swift
func clearTweets() {
    tweets.removeAll()
    // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
}
```

### Benefits of User-Specific Cache

- ✅ **User Isolation**: Each user has their own cache, no cross-user data leakage
- ✅ **Faster Re-login**: Cache persists across logout, providing instant load on re-login
- ✅ **Simplicity**: Single cache key instead of multiple keys
- ✅ **Flexibility**: Profile filters by `authorId`, allowing proper display of public/private tweets
- ✅ **Periodic Cleanup**: Old tweets automatically expire after 2 weeks

### Migration from "main_feed" to appUser.mid

- Existing `"main_feed"` cache entries will gradually expire (2-week TTL)
- New tweets are cached to `appUser.mid` immediately
- No manual migration needed - transparent transition
- Users logging back in will see their cached tweets from previous sessions

