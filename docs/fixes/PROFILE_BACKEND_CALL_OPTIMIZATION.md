# Profile Backend Call Optimization

## Issue
When users opened a profile screen, the application was making redundant `get_user` backend API calls, resulting in unnecessary network traffic and slower load times.

## Problem Analysis

### iOS (ProfileView.swift)
1. **Double trigger on profile load**:
   - `.task(id: profileRefreshCounter)` would trigger when view appeared
   - `.onAppear` would increment `profileRefreshCounter` if `didLoad` was true
   - This caused `.task` to trigger again, making two `get_user` calls

2. **Redundant resync operation**:
   - `refreshProfileData()` called both `fetchUser()` (get_user) and `resyncUser()` (resync_user)
   - `resyncUser()` is a long-running operation that should only run once per app session

### Android (UserViewModel.kt + ProfileScreen.kt)
1. **Double call on profile open**:
   - ViewModel `init` block called `fetchUser()` when ViewModel was created
   - `ProfileScreen` LaunchedEffect called `refreshUserData()` → `fetchUser()` when screen opened
   - Result: Two `get_user` calls for non-appUser profiles

2. **Redundant calls after follow/unfollow**:
   - Code called `fetchUser()` to get fresh data
   - Then immediately called `refreshUserData()` which called `fetchUser()` again
   - Result: Two consecutive `get_user` calls for the same user

## Solutions Implemented

### iOS Changes (ProfileView.swift)

#### 1. Fixed Double Trigger Issue
**Before:**
```swift
.task(id: profileRefreshCounter) {
    await refreshProfileData()
}
.onAppear {
    if didLoad {
        profileRefreshCounter += 1  // Triggers .task again!
    }
}
```

**After:**
```swift
.task(id: user.mid) {
    // Only fetch if this is the first load for this user
    if !didLoad {
        await refreshProfileData()
        didLoad = true
    }
}
.onChange(of: user.mid) { _, _ in
    // Reset didLoad when user changes
    didLoad = false
}
```

**Changes:**
- Changed `.task` key from `profileRefreshCounter` to `user.mid`
- Added guard to only fetch if `!didLoad`
- Simplified `.onChange` to just reset the flag
- Removed unused `profileRefreshCounter` state variable

#### 2. Optimized Resync Operation
**Added session tracking:**
```swift
/// Track users that have been resynced this app session to avoid redundant operations
private static var resyncedUsersThisSession: Set<String> = []
private static let resyncLock = NSLock()
```

**Modified resync logic:**
```swift
let shouldResync = Self.resyncLock.withLock {
    if Self.resyncedUsersThisSession.contains(userId) {
        return false
    }
    Self.resyncedUsersThisSession.insert(userId)
    return true
}

if shouldResync {
    Task.detached {
        // Run expensive resync_user operation
    }
} else {
    print("DEBUG: [ProfileView] Skipping resync - already resynced this session")
}
```

**Behavior:**
- First profile view per session: Calls `get_user` + `resync_user`
- Subsequent views: Only calls `get_user` (fast fetch for fresh data)

### Android Changes

#### 1. Skip Redundant Refresh on Profile Open (UserViewModel.kt)
**Added tracking flag:**
```kotlin
private var hasInitialUserFetch = false  // track if initial user fetch completed
```

**Modified init block:**
```kotlin
init {
    // ... existing code ...
    
    // Mark initial user fetch as complete
    hasInitialUserFetch = true
}
```

**Updated refreshUserData():**
```kotlin
fun refreshUserData(maxRetries: Int = 2, forceRefresh: Boolean = false) {
    viewModelScope.launch(IO) {
        // Skip refresh if initial fetch just completed, unless forced
        if (hasInitialUserFetch && !forceRefresh) {
            Timber.tag("refreshUserData").d("Skipping refresh - initial fetch just completed")
            hasInitialUserFetch = false  // Reset for future refreshes
            return@launch
        }
        
        refreshUserWithRetry(maxRetries)
        // ... rest of function
    }
}
```

#### 2. Added Cache-Based State Update (UserViewModel.kt)
**New method to update ViewModel without fetching:**
```kotlin
/**
 * Update ViewModel state from cached user data without fetching from server.
 * Use this when you've already fetched fresh user data and just need to update the ViewModel.
 */
fun updateFromCache() {
    viewModelScope.launch(IO) {
        val cachedUser = TweetCacheManager.getCachedUser(userId)
        if (cachedUser != null) {
            _user.value = cachedUser
            _bookmarksCount.value = cachedUser.bookmarksCount
            _favoritesCount.value = cachedUser.favoritesCount
            _followersCount.value = cachedUser.followersCount
            _followingsCount.value = cachedUser.followingCount
            _tweetCount.value = cachedUser.tweetCount
            
            Timber.tag("UserViewModel").d("Updated ViewModel state from cache for user: ${cachedUser.mid}")
        }
    }
}
```

#### 3. Updated Follow/Unfollow Handlers
**ProfileTopBarButtons.kt and ToggleFollowingButton.kt:**

**Before:**
```kotlin
fetchUser(userId)?.let { refreshedUser ->
    TweetCacheManager.saveUser(refreshedUser)
    viewModel.refreshUserData()  // Makes another fetchUser() call!
}
```

**After:**
```kotlin
fetchUser(userId)?.let { refreshedUser ->
    TweetCacheManager.saveUser(refreshedUser)
    viewModel.updateFromCache()  // Just updates ViewModel from cache
}
```

## Configuration

### Retry Behavior

#### iOS
- Uses system-level retry mechanism in `HproseInstance.fetchUser()`
- Retry count: Configurable per call (typically 2 retries)

#### Android
- **Max retries**: 2 (reduced from 3)
- **Backoff strategy**: Exponential
  - Attempt 1: Immediate
  - Attempt 2: 1 second delay
  - Attempt 3: 2 seconds delay (if maxRetries increased)

**Configuration in UserViewModel.kt:**
```kotlin
fun refreshUserData(maxRetries: Int = 2, forceRefresh: Boolean = false)
private suspend fun refreshUserWithRetry(maxRetries: Int = 2)
```

## Results

### Before Optimization
**iOS:**
- First profile view: 2+ backend calls (get_user + multiple triggers)
- Subsequent views: 2+ backend calls (get_user + resync_user every time)

**Android:**
- First profile view: 2 backend calls (init + LaunchedEffect)
- After follow/unfollow: 2 backend calls (explicit fetch + refreshUserData)

### After Optimization
**iOS:**
- First profile view (per session): 2 backend calls (get_user + resync_user)
- Subsequent views (same session): 1 backend call (get_user only)
- **Improvement**: ~50% reduction on subsequent views

**Android:**
- First profile view: 1 backend call (init fetch, LaunchedEffect skipped)
- After follow/unfollow: 1 backend call (explicit fetch, uses cache update)
- **Improvement**: ~50% reduction across all scenarios

## Testing

### iOS
Test that when opening a profile:
1. First time in session: See 1 `get_user` call and 1 `resync_user` call
2. Second time: See only 1 `get_user` call
3. Check logs for: `"Skipping resync for user X - already resynced this session"`

### Android
Test that when opening a profile:
1. First time: See 1 `get_user` call in logs
2. Check for: `"Skipping refresh - initial fetch just completed"`
3. After follow/unfollow: See 1 `get_user` call, then `"Updated ViewModel state from cache"`

## Files Modified

### iOS
- `Sources/Features/Profile/ProfileView.swift`
  - Added static session tracking for resync operations
  - Simplified lifecycle management
  - Removed redundant state variables

### Android
- `app/src/main/java/us/fireshare/tweet/viewmodel/UserViewModel.kt`
  - Added initial fetch tracking
  - Added `updateFromCache()` method
  - Updated retry count to 2
  - Enhanced documentation

- `app/src/main/java/us/fireshare/tweet/profile/ProfileTopBarButtons.kt`
  - Replaced `refreshUserData()` with `updateFromCache()`

- `app/src/main/java/us/fireshare/tweet/profile/ToggleFollowingButton.kt`
  - Replaced `refreshUserData()` with `updateFromCache()`

## Impact

### Performance
- **Network traffic**: Reduced by ~50% for profile views
- **Load time**: Faster profile rendering, especially on slower connections
- **Server load**: Reduced unnecessary backend calls

### User Experience
- Faster profile loading
- More responsive follow/unfollow actions
- Better battery efficiency (fewer network calls)

### Maintainability
- Clearer separation of concerns
- Better documentation of retry behavior
- Easier to understand lifecycle flow

## Future Considerations

1. **Cache expiration**: Consider implementing TTL for user data cache
2. **Background refresh**: Implement smart background refresh for frequently viewed profiles
3. **Metrics**: Add analytics to track actual backend call reduction
4. **Resync strategy**: Consider making resync_user optional or configurable

## Related Documentation
- `FETCHUSER_RETRY_IMPLEMENTATION.md` - Retry mechanism details
- `NETWORK_RESILIENCE.md` - Network error handling

