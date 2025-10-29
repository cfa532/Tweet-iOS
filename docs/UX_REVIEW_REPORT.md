# UX Review Report: Main Feed & User Profile
**Date:** October 28, 2025
**Reviewed Components:** Main Feed (HomeView, FollowingsTweetView), Profile View, TweetListView, TweetItemView

---

## 🔴 Critical UX Issues

### 1. **Artificial Loading Delays** (TweetListView)
**Location:** `TweetListView.swift:442-450`
**Impact:** Makes app feel slower than necessary
**Issue:** 
- Minimum 0.5s loading duration is hardcoded
- Even if data loads instantly, users wait unnecessarily
- This is anti-pattern for modern apps

```swift
private let minimumLoadingDuration: TimeInterval = 0.5

// Wait for minimum duration if needed
if remainingTime > 0 {
    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
}
```

**Recommendation:** Remove artificial delays. Use natural loading states that reflect actual operations.

---

### 2. **Excessive Background Tasks on Profile Load** (ProfileView)
**Location:** `ProfileView.swift:289-327`
**Impact:** Slow profile loading, potential battery drain
**Issue:**
- Fetches user data immediately (blocking)
- Refreshes pinned tweets (blocking)
- Then resyncs user data in background (long-running)
- All happening on profile view appearance

```swift
.task {
    if !didLoad {
        isLoading = true
        
        // Fetch fresh user data from server (BLOCKING)
        do {
            let refreshedUser = try await hproseInstance.fetchUser(user.mid, baseUrl: "")
            // ...
        }
        
        // Refresh pinned tweets (BLOCKING)
        await refreshPinnedTweets()
        
        isLoading = false
        didLoad = true
        
        // Resync user data on server in background (LONG OPERATION)
        Task.detached {
            do {
                let resyncedUser = try await hproseInstance.resyncUser(userId: userId)
                // ...
            }
        }
    }
}
```

**Recommendation:** 
- Show cached data immediately
- Fetch updates in background
- Use incremental loading (show basic profile → load details → load tweets)

---

### 3. **Complex Scroll Behavior with Timers** (ProfileView)
**Location:** `ProfileView.swift:519-590`
**Impact:** Inconsistent scroll behavior, potential UI lag
**Issue:**
- Uses Timer.scheduledTimer for scroll end detection
- Tracks consecutive small movements
- Complex logic to detect "inertia scrolling"
- Timer not properly managed (could leak)

```swift
@State private var scrollEndTimer: Timer?
@State private var consecutiveSmallMovements: Int = 0
@State private var isInertiaScrolling: Bool = false

private func handleScroll(offset: CGFloat, delta: CGFloat) {
    // Cancel any existing timer
    scrollEndTimer?.invalidate()
    
    // Complex tracking logic...
    if abs(scrollDelta) > scrollThreshold {
        consecutiveSmallMovements = 0
        isInertiaScrolling = false
    } else {
        consecutiveSmallMovements += 1
        if consecutiveSmallMovements > 3 {
            isInertiaScrolling = true
        }
    }
    
    // Reset after 0.3 seconds
    scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
        // ...
    }
}
```

**Recommendation:** Use SwiftUI's native scroll detection or simplified threshold-based approach.

---

### 4. **Aggressive Prefetching Strategy** (TweetListView)
**Location:** `TweetListView.swift:411-426`
**Impact:** Unnecessary network usage, memory pressure, potential crashes on slow connections
**Issue:**
- Loads 2 pages ahead automatically
- No user control or preference
- Could waste bandwidth on metered connections
- Increases memory pressure

```swift
private func loadNextTwoPages(startingFrom startPage: UInt) {
    // Load first page immediately
    loadSinglePage(page: startPage) { success in
        if success && self.hasMoreTweets {
            // Load second page after 1.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.hasMoreTweets && !self.isLoadingMore {
                    self.loadSinglePage(page: startPage + 1) { _ in
                        // Second page load complete
                    }
                }
            }
        }
    }
}
```

**Recommendation:** 
- Load only 1 page ahead
- Respect user's data usage preferences
- Consider connection quality

---

### 5. **Placeholder "Recommended" Tab** (RecommendedTweetView)
**Location:** `RecommendedTweetView.swift:10-13`
**Impact:** Poor UX - empty feature takes up navigation space
**Issue:** Tab exists but shows only "Coming soon" message

```swift
var body: some View {
    Text(LocalizedStringKey("Recommended tweets coming soon"))
        .foregroundColor(.themeSecondaryText)
}
```

**Recommendation:** Either implement the feature or remove the tab entirely until ready.

---

## 🟡 Major UX Issues

### 6. **Cache-First Loading Strategy Confusion**
**Location:** `TweetListView.swift:290-313`, `FollowingsTweetView.swift:14-33`
**Impact:** Users may see stale data first, then watch content "jump" when fresh data loads
**Issue:**
- Loads from cache instantly (no spinner)
- Then loads from server in background
- Content can shift/change after initial render
- No visual indication that data is being refreshed

**Recommendation:** 
- Add subtle refresh indicator when background load is happening
- Smooth content updates to avoid jarring transitions
- Consider showing cache age: "Updated 5 minutes ago"

---

### 7. **No Empty State for Guest Users** (FollowingsTweetViewModel)
**Location:** `FollowingsTweetViewModel.swift:32-47`
**Impact:** Guest users see admin tweets without context
**Issue:** Guest users automatically see admin user's tweets, but this isn't explained

```swift
if hproseInstance.appUser.isGuest {
    do {
        print("[HproseInstance] Loading tweets for guest user from alphaId")
        if let adminUser = try await hproseInstance.fetchUser(Gadget.getAlphaIds().first ?? "") {
            let serverTweets = try await hproseInstance.fetchUserTweets(user: adminUser, pageNumber: 0, pageSize: 20)
            // ...
        }
    } catch {
        print("[HproseInstance] Error loading tweets for guest user: \(error)")
        // Don't throw here, allow the app to continue even if tweet loading fails
    }
    return []
}
```

**Recommendation:** Show welcome message explaining guest mode and suggesting login/registration.

---

### 8. **Inconsistent Scroll-to-Hide Header Behavior**
**Location:** `HomeView.swift:148-194`
**Impact:** Header appears/disappears unpredictably
**Issue:**
- Uses accumulated delta thresholds (50 to hide, 20 to show)
- Different thresholds for up vs down scrolling
- Can feel inconsistent or "sticky"

```swift
if delta > 5 {
    accumulatedDelta += delta
    scrollUpAccumulated = 0
    
    if accumulatedDelta > 50 && isNavigationVisible {
        // Hide header after 50 points
        withAnimation(.easeInOut(duration: 0.25)) {
            isNavigationVisible = false
        }
        accumulatedDelta = 0
    }
} else if delta < -5 {
    scrollUpAccumulated += abs(delta)
    accumulatedDelta = 0
    
    if scrollUpAccumulated > 20 && !isNavigationVisible {
        // Show header after only 20 points
        withAnimation(.easeInOut(duration: 0.25)) {
            isNavigationVisible = true
        }
        scrollUpAccumulated = 0
    }
}
```

**Recommendation:** Use consistent thresholds or native SwiftUI scroll behaviors.

---

### 9. **Complex Retweet Handling in TweetItemView**
**Location:** `TweetItemView.swift:157-189`
**Impact:** Slow rendering, potential crashes if original tweet fails to load
**Issue:**
- Loads original tweet asynchronously on appear
- Complex logic to determine which tweet to show
- If original fails to load, removes tweet from list
- Registers video relationships inline

```swift
.onAppear {
    if !hasLoadedOriginalTweet, 
       let originalTweetId = tweet.originalTweetId, 
       let originalAuthorId = tweet.originalAuthorId {
        hasLoadedOriginalTweet = true
        Task {
            if let t = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId
            ) {
                VideoLoadingManager.shared.registerRetweetRelationship(
                    retweetId: tweet.mid,
                    originalTweetId: t.mid
                )
                
                await MainActor.run {
                    originalTweet = t
                    detailTweet = t
                }
            } else {
                // Could not fetch original tweet, remove from list
                await MainActor.run {
                    onRemove?(tweet.mid)
                }
            }
        }
    }
}
```

**Recommendation:** Preload original tweets at list level, not per-item.

---

### 10. **Author Loading in Tweet Rendering**
**Location:** `TweetItemView.swift:128-155`
**Impact:** Tweets show placeholder avatars, then "pop" when loaded
**Issue:**
- Each tweet independently checks if author needs loading
- Shows placeholder while loading
- Multiple fetches for same author across different tweets
- No batching or deduplication

```swift
.task {
    // Load author if not already loaded
    if tweet.author == nil {
        await MainActor.run {
            tweet.author = User.getInstance(mid: tweet.authorId)
        }
        print("⚡ [RENDER] Tweet rendering with placeholder (no author), fetching in background")
        Task.detached(priority: .background) {
            _ = try? await hproseInstance.fetchUser(tweet.authorId)
        }
    } else if tweet.author?.username == nil {
        print("⚡ [RENDER] Tweet rendering with placeholder (no username), fetching in background")
        Task.detached(priority: .background) {
            _ = try? await hproseInstance.fetchUser(tweet.authorId)
        }
    }
    // ... more checks
}
```

**Recommendation:** 
- Batch author fetches at list level
- Preload authors for visible tweets
- Use proper placeholder with skeleton loading

---

## 🟢 Minor UX Issues

### 11. **Excessive Debug Logging**
**Locations:** Throughout all files
**Impact:** Performance degradation in production builds
**Examples:**
- `FollowingsTweetView.swift` has 10+ print statements
- `ProfileView.swift` has 30+ print statements
- `TweetListView.swift` has 20+ print statements

**Recommendation:** 
- Use proper logging framework with levels
- Disable debug logs in production
- Remove or gate verbose logging

---

### 12. **No Loading States for Profile Actions**
**Location:** `ProfileView.swift:90-95` (Follow button)
**Impact:** Users don't know if action succeeded
**Issue:** Follow/unfollow happens with no immediate feedback except state toggle

```swift
onFollowToggle: {
    isFollowing.toggle()  // Optimistic update
    Task {
        await handleToggleFollowing(for: user, isFollowing: $isFollowing)
    }
}
```

**Recommendation:** Show loading spinner on button during network request.

---

### 13. **Pull-to-Refresh Always Hits Network**
**Location:** `TweetListView.swift:347-397`
**Impact:** Unnecessary network usage when cache is fresh
**Issue:** Refresh always bypasses cache, even if cache is recent

```swift
func refreshTweets() async {
    // Always load fresh data from server for refresh
    let freshTweets = try await tweetFetcher(0, pageSize, false, shouldCacheServerTweets)
    // ...
}
```

**Recommendation:** Check cache age; skip network if cache is very recent (< 30s).

---

### 14. **No Offline Mode Indication**
**Location:** All network calls
**Impact:** Users don't know why content isn't loading
**Issue:** No visual indication when device is offline

**Recommendation:** Show offline banner when network is unavailable.

---

### 15. **ScrollViewReader Not Utilized for Smooth Scrolling**
**Location:** `ProfileView.swift:594-599`
**Impact:** "Scroll to top" functionality may not work reliably
**Issue:** Posts notification but ScrollViewReader is in ProfileTweetsSection

```swift
private func scrollToTop() {
    print("DEBUG: [ProfileView] Scroll to top requested")
    NotificationCenter.default.post(name: .scrollToTop, object: nil)
}
```

**Recommendation:** Pass ScrollViewReader proxy directly instead of using NotificationCenter.

---

## 📊 Performance Concerns

### 16. **Memory Pressure from Video Loading**
**Location:** Implicit in video-heavy feeds
**Impact:** App crashes on older devices with limited RAM
**Issue:** No visible memory management, videos load eagerly

**Recommendation:** 
- Monitor memory usage
- Unload off-screen videos
- Limit concurrent video loading

---

### 17. **Main Thread Blocking**
**Location:** Multiple MainActor.run calls throughout
**Impact:** UI stutters during heavy operations
**Examples:**
- `TweetListView.swift:296-313` (updating tweets array)
- `ProfileView.swift:351-364` (updating following lists)

**Recommendation:** 
- Move heavy computations off main thread
- Use proper async/await patterns
- Consider using Combine for reactive updates

---

## 🎯 Recommendations Summary

### High Priority
1. **Remove artificial loading delays** - Makes app feel faster
2. **Optimize profile loading** - Show cached data first
3. **Simplify scroll behavior** - More predictable UX
4. **Reduce prefetching** - Save bandwidth and battery
5. **Fix or remove Recommended tab** - Don't show incomplete features

### Medium Priority
6. **Improve cache refresh UX** - Show when background loading happens
7. **Add guest mode explanation** - Better onboarding
8. **Batch author loading** - Reduce network calls
9. **Add loading states for actions** - Better feedback
10. **Preload retweet data** - Smoother rendering

### Low Priority
11. **Remove debug logging** - Better production performance
12. **Add offline mode** - Better error handling
13. **Optimize scroll-to-top** - Better implementation
14. **Add memory monitoring** - Prevent crashes

---

## 🔧 Quick Wins (Easy to Fix)

1. Remove `minimumLoadingDuration` (1 line change)
2. Remove or hide Recommended tab (5 line change)
3. Reduce prefetch from 2 pages to 1 (1 line change)
4. Add #if DEBUG gates around print statements (30 min)
5. Add loading spinner to Follow button (10 min)

---

## 🏗️ Architecture Improvements Needed

1. **Centralized Loading Manager** - Coordinate all network requests
2. **Proper Cache Layer** - With TTL and freshness indicators
3. **Batch Request System** - Load multiple users/tweets in one request
4. **Memory Budget System** - Proactively manage memory usage
5. **Offline Queue** - Queue actions when offline, execute when online

---

**End of Report**

