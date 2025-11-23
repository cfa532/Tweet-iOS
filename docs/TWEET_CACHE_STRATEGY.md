# Tweet Cache Strategy

## Date
January 2026

## Overview

The tweet caching system uses a **dual-strategy approach** based on context:
- **Main Feed**: All tweets cached under `appUser.mid` for efficient aggregate loading
- **Profile View**: Tweets cached under their `authorId` for author-specific loading
- **Single Tweet Fetch**: Cached under `authorId` for consistency

This strategy balances performance (fast main feed loading) with flexibility (author-specific caching for profiles).

## Cache Strategy Rules

### 1. Main Feed (fetchTweetFeed)

**Caching:** All tweets are cached under `appUser.mid`

```swift
// In HproseInstance.fetchTweetFeed()
TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)
```

**Reasoning:**
- Main feed aggregates tweets from multiple authors
- Caching all under `appUser.mid` allows efficient single-cache loading
- Matches Android behavior where mainfeed cache is shared

**Cache Key:** `appUser.mid`

### 2. Profile View (fetchUserTweets)

**Caching:** Tweets are cached under their `authorId`

```swift
// In HproseInstance.fetchUserTweets()
TweetCacheManager.shared.saveTweet(tweet, userId: tweet.authorId)
```

**Reasoning:**
- Profile views show tweets from a specific author
- Caching by `authorId` enables efficient author-specific queries
- Consistent with single tweet caching strategy

**Cache Key:** `tweet.authorId` (equals `user.mid` for profile view)

### 3. Single Tweet (getTweet)

**Caching:** Tweet cached under its `authorId`

```swift
// In HproseInstance.getTweet()
TweetCacheManager.shared.saveTweet(tweet, userId: authorId)
```

**Reasoning:**
- Single tweets are author-specific
- Consistent with profile caching strategy
- Enables efficient author-based queries

**Cache Key:** `authorId`

### 4. New Tweets & Retweets

**Caching:** 
- New tweets in main feed: Cached under `appUser.mid`
- Retweets: Cached under `retweet.authorId` (which equals `appUser.mid` for retweets)

```swift
// New tweet in main feed
TweetCacheManager.shared.saveTweet(tweet, userId: appUser.mid)

// Retweet
TweetCacheManager.shared.saveTweet(retweet, userId: retweet.authorId)
```

## Cache Loading Strategy

### Main Feed Loading

**Source:** `appUser.mid` cache

```swift
// In FollowingsTweetView.swift
let cachedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: viewModel.hproseInstance.appUser.mid, 
    page: page, 
    pageSize: size, 
    currentUserId: viewModel.hproseInstance.appUser.mid,
    isProfileView: false)  // No authorId filtering
```

**Behavior:**
- Loads all tweets from `appUser.mid` cache
- **No filtering by authorId** - shows tweets from all authors in the cache
- Filters out private tweets (all private tweets are hidden)
- Returns paginated results

### Profile Loading

**Important:** For any profile view (appUser or other users), the strategy is the same:
- Load cached tweets from `userId` cache (which equals `authorId` for profile views)
- Filter tweets by `authorId` to ensure only that user's tweets are shown

**Source:** Loads from `userId` cache and filters by `authorId`

```swift
// In ProfileTweetsSection.swift
fetchCachedTweets(
    for: user.mid,  // userId (equals authorId for profile view)
    page: page, 
    pageSize: size, 
    currentUserId: appUser.mid, 
    isProfileView: true  // Enable filtering by authorId
)
```

**Behavior (Same for All Profiles):**
- Loads from `userId` cache (which is the profile user's `authorId`)
- Filters to only include tweets where `tweet.authorId == userId`
- Ensures only the profile user's tweets are shown, even if cache contains tweets from other authors
- **Private tweets visibility:**
  - Visible only if `appUser == visited user` (viewing your own profile)
  - Filtered out when viewing other users' profiles
- Fetches 3x pageSize to account for filtering

## Data Flow Examples

### Example 1: Main Feed Load

```
1. User opens main feed
   ↓
2. Load from cache: appUser.mid
   ↓
3. Returns all tweets from mainfeed cache (multiple authors)
   ↓
4. Filter out private tweets
   ↓
5. Display paginated results
```

### Example 2: AppUser's Profile Load

```
1. User opens their own profile
   ↓
2. Load from cache: appUser.mid (same as mainfeed)
   ↓
3. Filter: tweet.authorId == appUser.mid
   ↓
4. Returns only appUser's tweets
   ↓
5. Display paginated results
```

### Example 3: Other User's Profile Load

```
1. User opens another user's profile
   ↓
2. Load from cache: userId (equals authorId)
   ↓
3. Returns tweets from that user's cache
   ↓
4. Display paginated results
```

### Example 4: New Tweet in Main Feed

```
1. AppUser posts a tweet
   ↓
2. Tweet saved to server
   ↓
3. Notification: .newTweetCreated
   ↓
4. Cache tweet under: appUser.mid
   ↓
5. Main feed shows tweet immediately
   ↓
6. AppUser's profile also shows tweet (loaded from appUser.mid cache + filtered)
```

### Example 5: Viewing Other User's Profile

```
1. User opens UserA's profile
   ↓
2. fetchUserTweets() called for UserA
   ↓
3. Server returns UserA's tweets
   ↓
4. Cache each tweet under: tweet.authorId (UserA's mid)
   ↓
5. Display tweets
   ↓
6. Next time: Load from UserA's authorId cache (fast!)
```

## Benefits

### 1. Performance
- ✅ **Main Feed**: Single cache lookup (appUser.mid) for all tweets
- ✅ **Profile**: Direct author-based cache lookup (authorId)
- ✅ **Efficient Loading**: No need to query multiple caches for main feed

### 2. Consistency
- ✅ **Main Feed**: All tweets in one place (appUser.mid)
- ✅ **Profile**: Author-specific caching (authorId)
- ✅ **Single Tweet**: Consistent with profile strategy (authorId)

### 3. Flexibility
- ✅ **AppUser Profile**: Uses mainfeed cache with filtering (shared cache)
- ✅ **Other Profiles**: Uses author-specific cache (isolated)
- ✅ **Matches Android**: Same shared-cache strategy for appUser's profile

### 4. Cache Efficiency
- ✅ **Main Feed**: One cache key for all aggregated tweets
- ✅ **Profile**: Direct author lookup without filtering needed
- ✅ **No Duplication**: Tweets cached appropriately based on context

## Implementation Details

### Cache Key Summary

| Context | Cache Key | Filtering |
|---------|-----------|-----------|
| Main Feed (fetchTweetFeed) | `appUser.mid` | Filter private tweets |
| Main Feed (loading) | `appUser.mid` | Filter private tweets, no authorId filtering |
| Profile (fetchUserTweets) | `tweet.authorId` | None |
| Profile (appUser, loading) | `appUser.mid` | **Filter by `authorId == appUser.mid`** |
| Profile (other user, loading) | `appUser.mid` + `userId` | **Filter by `authorId == userId`** |
| Single Tweet (getTweet) | `authorId` | None |
| New Tweet (main feed) | `appUser.mid` | None |
| Retweet | `retweet.authorId` | None |

### Important Notes

1. **Profile Filtering**: For **any user profile** (appUser or other users), the strategy is identical:
   - Load from `userId` cache (which equals `authorId` for profile views)
   - Filter by `authorId == userId` to show only that user's tweets
   - No difference between appUser's profile and other users' profiles

2. **Cache Sources for Profiles**:
   - All profiles: Load from `userId` cache (which is their `authorId`)
   - Filter by `authorId` to ensure only that user's tweets are shown
   - Same logic for appUser and other users

3. **Cache Filtering**: 
   - Main feed: Shows all tweets without filtering (aggregate from all authors), but private tweets are filtered out
   - Profile views: 
     - Always filter by `authorId` to show only profile user's tweets
     - Private tweets are only visible if `appUser == visited user` (viewing your own profile)
     - Private tweets are filtered out when viewing other users' profiles

3. **Original Tweets**: When fetching tweets that reference original tweets (retweets), original tweets are cached under their `authorId`, not `appUser.mid`. This ensures original tweets don't appear in main feed when their author is different.

4. **Persistence**: Cache persists across logout/login cycles and is cleared periodically (2 weeks) or manually by user.

## Migration Notes

This strategy evolved from earlier approaches:

1. **October 2025**: Used `"main_feed"` cache key for public tweets, separate `appUser.mid` cache for private tweets
2. **December 2025**: Migrated to `appUser.mid` for all main feed tweets, unified cache
3. **January 2026**: Implemented dual-strategy:
   - Main feed: `appUser.mid` (aggregate)
   - Profile: `authorId` (author-specific)
   - Single tweet: `authorId` (consistent)

## Files Involved

1. **`Sources/Core/HproseInstance.swift`**
   - `fetchTweetFeed()`: Caches under `appUser.mid`
   - `fetchUserTweets()`: Caches under `tweet.authorId`
   - `getTweet()`: Caches under `authorId`

2. **`Sources/Core/TweetCacheManager.swift`**
   - `fetchCachedTweets()`: Implements cache key selection and filtering logic
   - `saveTweet()`: Saves tweets to appropriate cache based on context

3. **`Sources/Features/Home/FollowingsTweetView.swift`**
   - Loads from `appUser.mid` cache for main feed

4. **`Sources/Features/Profile/ProfileTweetsSection.swift`**
   - Uses `userId` (authorId) for profile loading

5. **`Sources/Features/Home/FollowingsTweetViewModel.swift`**
   - Caches new tweets under `appUser.mid` for main feed

