# User Cache Placeholder Strategy

**Date:** November 22, 2025  
**Status:** ✅ **IMPLEMENTED**  
**Priority:** 🟡 **MEDIUM**

---

## Problem

When the app starts and tweet feed is loaded, tweet authors (different from appUser) were being overwritten by skeleton objects from `getInstance()`, even when cached user data was available. This caused:

1. **Poor UX**: Users saw skeleton/placeholder data instead of cached user information
2. **Unnecessary Overwrites**: Cached user data was ignored in favor of empty skeleton objects
3. **Confusion**: No distinction between "no cached data" vs "server fetch failed"

### Symptoms

```
App Start → Load Tweet Feed
  ↓
Tweet has authorId different from appUser
  ↓
fetchUser(authorId) called
  ↓
❌ Returns skeleton User.getInstance() immediately
  ↓
UI shows empty author (no username, no avatar)
  ↓
Server fetch happens in background
  ↓
Author data appears later (flicker/refresh)
```

**Result:** Cached user data was not being used as placeholder, causing unnecessary UI refreshes and poor initial rendering experience.

---

## Root Cause

The issue had two parts:

### 1. Cached Tweets Not Loading Author Data from Cache

In `TweetCacheManager.fetchCachedTweets()`, when loading tweets from Core Data:
- Authors were set to `User.getInstance(mid: authorId)` which creates skeleton
- Core Data user cache was not being checked
- Even if cached user existed, it was ignored

### 2. Server Fetch Failure Returning Cached User

When `fetchUser()` failed to fetch from server:
- It was returning cached user (even if expired) as fallback
- This masked server errors and showed stale data
- No clear indication that something went wrong

---

## The Solution

### Key Principle: **Use Cached Data as Placeholder, Skeleton Only on Error**

The strategy now follows this priority:

1. **Cached User (Expired or Not)** → Use as placeholder when loading from cache
2. **Skeleton User** → Only when server fetch fails (indicates error)

### 1. Load Cached Users from Core Data

**File:** `Sources/Core/TweetCacheManager.swift`

Updated `fetchCachedTweets()` and `fetchTweet()` to load author data from Core Data cache:

```swift
// Load author from cache (Core Data) if available, otherwise use singleton
if tweet.author == nil {
    // First get the singleton
    let authorSingleton = User.getInstance(mid: tweet.authorId)
    
    // If singleton doesn't have data, try to load from Core Data cache
    if authorSingleton.username == nil {
        let userRequest: NSFetchRequest<CDUser> = CDUser.fetchRequest()
        userRequest.predicate = NSPredicate(format: "mid == %@", tweet.authorId)
        if let cdUser = try? self.context.fetch(userRequest).first {
            // Update singleton with cached data (even if expired)
            _ = User.from(cdUser: cdUser)
        }
    }
    
    // Use the singleton (either populated from cache or skeleton)
    tweet.author = User.getInstance(mid: tweet.authorId)
}
```

**Impact:**
- ✅ Cached users are loaded from Core Data when available
- ✅ Even expired cache is used as placeholder
- ✅ UI shows user data immediately instead of skeleton
- ✅ Background refresh updates the data seamlessly

### 2. Return Skeleton on Server Fetch Failure

**File:** `Sources/Core/HproseInstance.swift`

Updated `fetchUser()` to return skeleton when server fetch fails:

```swift
do {
    let user = try await updateUserFromServer(userId, baseUrl: baseUrl)
    // ... success handling
    return user
} catch {
    // After all retries failed, add userId to blacklist
    blackList.recordFailure(userId)
    
    // Return skeleton instead of cached user when server fetch fails
    // This indicates to the UI that something is wrong
    return User.getInstance(mid: userId)
}
```

**Impact:**
- ✅ Clear visual indication when server fetch fails
- ✅ Prevents showing stale cached data after error
- ✅ UI can distinguish between "loading" vs "error" states

### 3. Updated Error Handling in Feed Loading

**File:** `Sources/Core/HproseInstance.swift`

Updated `fetchTweetFeed()`, `fetchUserTweets()`, and `fetchComments()` to use skeleton on server fetch failure:

```swift
do {
    let author = try await fetchUser(tweet.authorId)
    await MainActor.run {
        tweet.author = author
    }
} catch {
    // Server fetch failed - use skeleton to indicate error
    await MainActor.run {
        tweet.author = User.getInstance(mid: tweet.authorId)
        print("⚠️ Server fetch failed, using skeleton to indicate error")
    }
}
```

**Impact:**
- ✅ Consistent error handling across all feed loading paths
- ✅ Clear distinction between cached data and error state
- ✅ UI shows appropriate placeholder based on state

### 4. Updated TweetItemView Fallback

**File:** `Sources/Tweet/TweetItemView.swift`

Updated to load from cache before falling back to skeleton:

```swift
if tweet.author == nil {
    // Try to load from cache first, then fetch in background
    let cachedAuthor = await TweetCacheManager.shared.fetchUser(mid: tweet.authorId)
    await MainActor.run {
        if cachedAuthor.username != nil {
            // Use cached user as placeholder until refresh succeeds
            tweet.author = cachedAuthor
        } else {
            // No cached user, use skeleton as last resort
            tweet.author = User.getInstance(mid: tweet.authorId)
        }
    }
    Task.detached(priority: .background) {
        _ = try? await hproseInstance.fetchUser(tweet.authorId)
    }
}
```

**Impact:**
- ✅ UI layer also respects cached user priority
- ✅ Consistent behavior across all loading paths
- ✅ Better initial rendering experience

---

## Algorithm Flow

### App Start → Tweet Feed Load

```
App Start
  ↓
Load Cached Tweets from Core Data
  ↓
For each tweet:
  ├─ Check if author singleton has data
  ├─ If not, load from Core Data user cache
  ├─ Update singleton with cached data (even if expired)
  └─ Set tweet.author = singleton
  ↓
UI Renders Immediately with Cached User Data ✅
  ↓
Background: fetchUser() called for each author
  ├─ If cache valid → return immediately
  ├─ If cache expired → fetch from server
  └─ If fetch fails → return skeleton (indicates error)
  ↓
UI Updates when server data arrives
```

### Server Fetch Failure

```
fetchUser(userId) called
  ↓
Check cached user
  ↓
Try updateUserFromServer()
  ├─ Attempt 1: Fail
  ├─ Attempt 2: Fail
  └─ Attempt 3: Fail
  ↓
catch error
  ↓
Return User.getInstance(mid: userId) ← Skeleton
  ↓
UI Shows Skeleton (indicates error) ⚠️
```

---

## Benefits

### Before
- ❌ Cached users ignored, skeleton shown immediately
- ❌ UI flicker as data loads from server
- ❌ No distinction between "no cache" vs "server error"
- ❌ Stale cached data shown after server failure

### After
- ✅ Cached users used as placeholders (even if expired)
- ✅ Immediate UI rendering with user data
- ✅ Skeleton only when server fetch fails (clear error indication)
- ✅ Seamless background refresh updates
- ✅ Better user experience with instant feedback

---

## Related Files

- `Sources/Core/TweetCacheManager.swift` - Cache loading logic
- `Sources/Core/HproseInstance.swift` - User fetching and error handling
- `Sources/Tweet/TweetItemView.swift` - UI layer fallback
- `Sources/DataModels/User.swift` - User singleton pattern

---

## Testing

To verify the fix:

1. **Cache Loading**: Start app with cached tweets → authors should show cached data immediately
2. **Server Failure**: Disable network → skeleton should appear (not stale cache)
3. **Background Refresh**: Enable network → cached data should update seamlessly
4. **Expired Cache**: Wait 30+ minutes → expired cache should still be used as placeholder

---

## Conclusion

The user cache placeholder strategy ensures that:
- Cached user data is always used as placeholder when available
- Skeleton users only appear when server fetch fails
- UI provides instant feedback with user data immediately
- Clear visual distinction between cached data and error states
- Better overall user experience with reduced UI flicker

