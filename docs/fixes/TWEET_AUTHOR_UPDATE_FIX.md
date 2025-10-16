# Tweet Author Update and Profile Cache Fix

## Date
October 16, 2025

## Bug Description

Two related issues with tweet display:

### Issue 1: Avatar Not Updating in Tweets
AppUser's avatar would update in the app header view but NOT in their tweets. The default avatar would persist in tweet views even though the user object had the correct avatar loaded.

**User Experience:**
```
AppHeadView → Shows updated avatar ✅
Tweet 1 by @user → Shows default avatar ❌
Tweet 2 by @user → Shows default avatar ❌
Tweet 3 by @user → Shows default avatar ❌
```

### Issue 2: Profile Shows No Tweets
Sometimes the appUser's profile would show no tweets, even though the main feed was displaying the appUser's tweets correctly.

**User Experience:**
```
Main Feed → Shows 5 tweets by @appUser ✅
Profile View → Shows "No tweet yet" ❌
```

## Root Causes

### Issue 1 Root Cause: Author Not @Published

In `Tweet.swift` line 82, the `author` property was NOT marked as `@Published`:

```swift
// Display only properties
var author: User?  // ❌ Not @Published - changes don't trigger UI updates
```

**The problem:**
1. Tweet views use `@ObservedObject var tweet: Tweet`
2. They display `tweet.author?.name` and `tweet.author?.avatar`
3. When `tweet.author` was loaded/set, views were NOT notified
4. UI showed stale data (default avatar) even though `author` was correctly populated

**Additionally:** When we removed blocking `fetchUser()` calls from `TweetCacheManager`, we didn't add author loading back to the views, so `tweet.author` was often `nil`.

### Issue 2 Root Cause: Profile Cache Disabled and Separated

In `ProfileTweetsSection.swift` line 190, profile caching was disabled and used a separate cache:

```swift
showTitle: false, shouldCacheServerTweets: false,  // ❌ Caching disabled!
```

**The problems:**
1. Profile tweets loaded from server → NOT cached ❌
2. Profile used separate cache key (`appUser.mid`) instead of unified "main_feed"
3. Public tweets stored in two places (duplication and inconsistency)
4. Next profile view → loads from empty profile cache → "No tweet yet"

## The Fixes

### Fix 1: Make Author @Published (Tweet.swift)

```swift
// Display only properties
@Published var author: User?  // ✅ Now @Published - triggers UI updates
```

**Impact:**
- When `tweet.author` is set, all views observing the tweet get notified
- UI automatically updates to show the loaded author
- Avatar appears in all tweet instances simultaneously

### Fix 2: Add Author Loading to TweetItemView (TweetItemView.swift)

Added author loading in the `.task` modifier (lines 88-95):

```swift
.task {
    isVisible = true
    tweet.isVisible = true
    detailTweet = tweet
    
    // Load author if not already loaded
    if tweet.author == nil {
        if let author = try? await hproseInstance.fetchUser(tweet.authorId) {
            await MainActor.run {
                tweet.author = author  // ✅ Triggers UI update (author is @Published)
            }
        }
    }
}
```

**Impact:**
- Authors lazy-loaded when tweets appear on screen
- Non-blocking (async fetchUser)
- Deduplicated (multiple tweets by same user share the fetchUser request)
- Automatic UI update when author loads

### Fix 3: Unified Cache Strategy (ProfileTweetsSection.swift)

**Caching Strategy (lines 72-80, 105-111):**
```swift
// Cache strategy:
// - Public tweets → "main_feed" cache (they appear in feed anyway)
// - Private tweets → appUser.mid cache only (profile-only visibility)
if tweet.isPrivate == true {
    TweetCacheManager.shared.saveTweet(tweet, userId: user.mid)
} else {
    TweetCacheManager.shared.saveTweet(tweet, userId: "main_feed")
}
```

**Loading Strategy (lines 193-220):**
```swift
// Load from both caches and merge:
// 1. Main feed cache (public tweets)
// 2. Profile cache (private tweets)
let mainFeedTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: "main_feed", page: page, pageSize: size, ...)
let privateTweets = await TweetCacheManager.shared.fetchCachedTweets(
    for: user.mid, page: page, pageSize: size, ...)

// Merge, deduplicate, and filter to show only appUser's tweets
```

**Impact:**
- Public tweets use unified "main_feed" cache (no duplication)
- Private tweets use profile-only cache (proper privacy)
- Profile loads from both caches (shows all tweets)
- Consistent data across main feed and profile

## How It Works Now

### Avatar Update Flow

```
1. Tweet appears on screen
   ↓
2. TweetItemView.task runs
   ↓
3. Check if tweet.author == nil
   ↓
4. If nil: await fetchUser(tweet.authorId)
   ↓
5. Set tweet.author = fetchedUser
   ↓
6. @Published author triggers update
   ↓
7. ✅ ALL views observing this tweet update:
   - TweetItemView (avatar in tweet)
   - TweetItemHeaderView (name/username)
   - TweetDetailView (if open)
   - Any other views
```

### Unified Cache Flow

**Caching Strategy:**
```
AppUser's Public Tweet:
  → Save to "main_feed" cache
  → Appears in both main feed AND profile ✅
  → No duplication

AppUser's Private Tweet:
  → Save to appUser.mid cache ONLY
  → Appears in profile only ✅
  → Privacy preserved
```

**Profile Loading:**
```
1. Profile View loads tweets (isFromCache: true)
   ↓
2. Load from "main_feed" cache → Get public tweets
   ↓
3. Load from appUser.mid cache → Get private tweets
   ↓
4. Merge both → Filter by authorId == appUser.mid
   ↓
5. Deduplicate by tweet.mid
   ↓
6. Sort by timestamp (newest first)
   ↓
7. Apply pagination
   ↓
8. ✅ Profile shows all appUser's tweets instantly!
```

**Benefits:**
- ✅ Public tweets in unified cache (efficient)
- ✅ Private tweets isolated (secure)
- ✅ Profile shows all tweets (public + private)
- ✅ No cache duplication
- ✅ Instant loading from cache

## Testing

### Test 1: Avatar Update in Tweets
```
1. Login as user
2. Open main feed with your tweets
3. All tweets should show default avatar initially
4. After ~1 second, all avatars should update together ✅
5. Scroll to profile view
6. All avatars should match ✅
```

### Test 2: Profile Tweet Caching
```
1. View appUser's profile
2. Note the tweets
3. Navigate away
4. Kill and restart app
5. Navigate to profile again
6. ✅ Tweets should load instantly from cache
7. ✅ Should NOT show "No tweet yet"
```

### Test 3: Author Loading Deduplication
```
1. Scroll to feed with 5 tweets from same user
2. Check network logs
3. ✅ Should see only 1 fetchUser() call for that user
4. ✅ All 5 tweets should show avatar after loading
5. ✅ All should update simultaneously
```

### Test 4: Main Feed and Profile Consistency
```
1. View main feed → see 3 tweets by appUser
2. Navigate to profile view
3. ✅ Should see same 3 tweets
4. ✅ Should NOT show "No tweet yet"
```

## Performance Impact

### Author Loading
**Before:**
- Authors loaded synchronously in TweetCacheManager (blocking)
- Caused UI freezes

**After:**
- Authors loaded async in views (non-blocking)
- Deduplicated (1 request per user)
- UI stays responsive ✅

### Profile Caching
**Before:**
- Profile tweets not cached
- Every profile visit fetched from server
- Slow, wasteful

**After:**
- Profile tweets cached (like main feed)
- Instant load from cache
- Efficient, fast ✅

## Files Modified

1. **`/Sources/DataModels/Tweet.swift`**
   - Line 82: Made `author` property `@Published`

2. **`/Sources/Tweet/TweetItemView.swift`**
   - Lines 88-95: Added author lazy-loading in `.task` modifier

3. **`/Sources/Features/Profile/ProfileTweetsSection.swift`**
   - Line 190: Changed `shouldCacheServerTweets: false` → `true`

## Benefits

### 1. Consistent UI
- ✅ Author info appears in all views simultaneously
- ✅ No mix of default/loaded avatars
- ✅ Profile and main feed show same data

### 2. Better Performance
- ✅ Non-blocking author loading
- ✅ Instant profile loading from cache
- ✅ Reduced network requests

### 3. User Experience
- ✅ Smooth, responsive UI
- ✅ Fast navigation
- ✅ Consistent data across views

## Conclusion

By making `tweet.author` a `@Published` property and adding lazy author loading to views, we ensure that author updates propagate correctly to all tweet displays. By enabling profile tweet caching, we provide instant profile loading and consistency with the main feed.

**Result:** Avatar updates now appear in all tweets simultaneously, and profile views load instantly from cache! ✅

