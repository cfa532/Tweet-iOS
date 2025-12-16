# Android Retweet Loading Implementation Analysis

## Overview
The Android version handles retweet loading very stably when scrolling up. This document analyzes the key differences between Android and iOS implementations.

## Key Android Implementation Details

### 1. State Management with Stable Keys (`TweetItem.kt`)

**Android Approach:**
```kotlin
// Use remember with a stable key based on originalTweetId to maintain state across recompositions
val originalTweetId = tweet.originalTweetId
var originalTweet by remember(originalTweetId) { mutableStateOf<Tweet?>(null) }
var isLoadingOriginal by remember(originalTweetId) { mutableStateOf(true) }

LaunchedEffect(originalTweetId, tweet.originalAuthorId) {
    if (originalTweetId != null && tweet.originalAuthorId != null) {
        // Fetch original tweet
    }
}
```

**Key Benefits:**
- `remember(originalTweetId)` ensures state persists across recompositions
- Only refetches when `originalTweetId` actually changes
- Prevents unnecessary network calls during scrolling

### 2. Fixed-Size Loading Indicator

**Android Approach:**
```kotlin
when {
    isLoadingOriginal -> {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            contentAlignment = Alignment.Center
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 2.dp
            )
        }
    }
    // ...
}
```

**Key Benefits:**
- Fixed-size container prevents layout shifts
- Loading state doesn't change item height
- Smooth transition when content loads

### 3. Stable Item Keys in List

**Android Approach (`TweetListView.kt`):**
```kotlin
itemsIndexed(
    items = tweets,
    key = { _, tweet -> tweet.mid },  // Stable key
    contentType = { _, _ -> "tweet" }  // Help Compose reuse compositions
) { index, tweet ->
    // ...
}
```

**Key Benefits:**
- Stable keys prevent unnecessary recompositions
- Compose can efficiently reuse compositions
- Reduces layout recalculations during scrolling

### 4. Visibility Tracking (Partially Implemented)

**Android Approach:**
```kotlin
var isVisible by remember { mutableStateOf(false) }
var lastVisibilityUpdate by remember { mutableLongStateOf(0L) }
val debounceMs = 100L // 100ms debounce

.onGloballyPositioned { layoutCoordinates ->
    val now = System.currentTimeMillis()
    if (now - lastVisibilityUpdate > debounceMs) {
        isVisible = isElementVisible(layoutCoordinates, 50)
        lastVisibilityUpdate = now
    }
}
```

**Note:** Android tracks visibility but doesn't use it to gate loading in `RetweetContent`. However, the stable `remember` keys prevent unnecessary refetches.

## iOS Implementation Issues

### 1. onAppear-Based Loading (Unstable)

**Current iOS Approach:**
```swift
.onAppear {
    if !hasLoadedOriginalTweet, 
       let originalTweetId = tweet.originalTweetId, 
       let originalAuthorId = tweet.originalAuthorId {
        hasLoadedOriginalTweet = true
        Task {
            // Fetch original tweet
        }
    }
}
```

**Problems:**
- `onAppear` can trigger multiple times during scrolling
- No stable key to prevent refetches
- State can be lost during recompositions

### 2. Layout Shifts from Placeholder

**Current iOS Approach:**
```swift
// Placeholder with fixed height
.frame(minHeight: 60) // Fixed height placeholder
```

**Problems:**
- Placeholder height may not match actual content
- When original tweet loads, layout can shift
- No smooth transition like Android

### 3. No State Persistence Across Recompositions

**Current iOS Approach:**
```swift
@State private var originalTweet: Tweet?
@State private var hasLoadedOriginalTweet = false
```

**Problems:**
- `@State` doesn't persist across view identity changes
- Can cause refetches when scrolling up
- No stable key like Android's `remember`

## Recommendations for iOS

### 1. Use Stable State Keys

**Recommended Approach:**
```swift
// Use a stable key based on originalTweetId
@State private var originalTweet: Tweet?
@State private var hasLoadedOriginalTweet = false

// In body or onAppear:
.onAppear {
    let originalTweetId = tweet.originalTweetId
    // Only fetch if we haven't loaded for THIS specific originalTweetId
    if !hasLoadedOriginalTweet && originalTweetId != nil {
        hasLoadedOriginalTweet = true
        // Fetch...
    }
}
.onChange(of: tweet.originalTweetId) { oldValue, newValue in
    // Reset state when originalTweetId changes
    if oldValue != newValue {
        hasLoadedOriginalTweet = false
        originalTweet = nil
    }
}
```

### 2. Match Placeholder Height to Content

**Recommended Approach:**
```swift
// Measure actual embedded tweet height and match placeholder
.frame(minHeight: 60) // Match smallest possible embedded tweet
.fixedSize(horizontal: false, vertical: true)
```

### 3. Use Stable List Item Keys

**Already Implemented:**
```swift
ForEach(tweets, id: \.mid) { tweet in
    // Stable key already in use
}
```

### 4. Consider Visibility-Based Loading

**Optional Enhancement:**
```swift
// Only load when item is actually visible
@State private var isVisible = false

.onAppear {
    isVisible = true
    if isVisible && !hasLoadedOriginalTweet {
        // Load original tweet
    }
}
.onDisappear {
    isVisible = false
}
```

## Key Takeaways

1. **Android's `remember` with stable keys** prevents unnecessary refetches during scrolling
2. **Fixed-size loading indicators** prevent layout shifts
3. **Stable item keys** in lists improve performance
4. **iOS should adopt similar patterns** using `onChange` to track `originalTweetId` changes and reset state accordingly

## Stability Features in Android

1. ✅ Stable state with `remember(originalTweetId)`
2. ✅ Fixed-size loading indicator
3. ✅ Stable list item keys
4. ✅ Debounced visibility tracking
5. ✅ LaunchedEffect only runs when keys change

## Missing in iOS

1. ❌ No stable state persistence across recompositions
2. ❌ onAppear can trigger multiple times
3. ❌ Placeholder height may not match content
4. ❌ No onChange handler for originalTweetId changes
