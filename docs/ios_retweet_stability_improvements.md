# iOS Retweet Loading Stability Improvements

## Overview
Updated iOS implementation to match Android's stable retweet loading pattern, preventing unnecessary refetches and layout shifts when scrolling up.

## Changes Made

### 1. Stable State Management (`TweetItemView.swift`)

**Added:**
- `@State private var lastLoadedOriginalTweetId: String?` - Tracks the last loaded original tweet ID to prevent refetches (equivalent to Android's `remember(originalTweetId)`)

**Improved:**
- Added `onChange(of: tweet.originalTweetId)` handler to reset state when the original tweet ID changes
- Modified `onAppear` to check `lastLoadedOriginalTweetId` before loading, preventing duplicate fetches

**Before:**
```swift
.onAppear {
    if !hasLoadedOriginalTweet, 
       let originalTweetId = tweet.originalTweetId, 
       let originalAuthorId = tweet.originalAuthorId {
        hasLoadedOriginalTweet = true
        Task { /* fetch */ }
    }
}
```

**After:**
```swift
.onChange(of: tweet.originalTweetId) { oldValue, newValue in
    // Reset state when originalTweetId changes (like Android's remember with stable keys)
    if oldValue != newValue {
        hasLoadedOriginalTweet = false
        originalTweet = nil
        lastLoadedOriginalTweetId = nil
    }
}
.onAppear {
    // Stable state management: Only load if originalTweetId hasn't been loaded yet
    if let originalTweetId = tweet.originalTweetId,
       let originalAuthorId = tweet.originalAuthorId,
       originalTweetId != lastLoadedOriginalTweetId {
        hasLoadedOriginalTweet = true
        lastLoadedOriginalTweetId = originalTweetId
        Task { /* fetch */ }
    }
}
```

### 2. Fixed-Size Placeholder (`TweetItemView.swift`)

**Changed:**
- Changed placeholder from `.frame(minHeight: 60)` to `.frame(height: 60)` to match Android's fixed-size approach
- This prevents layout shifts when the original tweet loads

**Before:**
```swift
.frame(minHeight: 60) // Fixed height placeholder
```

**After:**
```swift
.frame(height: 60) // Fixed height (not minHeight) to match Android's fixed-size approach
```

### 3. Improved Equatable Implementation (`TweetItemView.swift`)

**Added:**
- Included `tweet.originalTweetId` in the equality check for more stable view identity

**Before:**
```swift
static func == (lhs: TweetItemView, rhs: TweetItemView) -> Bool {
    return lhs.tweet.mid == rhs.tweet.mid &&
           // ... other properties
           lhs.originalTweet?.mid == rhs.originalTweet?.mid
}
```

**After:**
```swift
static func == (lhs: TweetItemView, rhs: TweetItemView) -> Bool {
    return lhs.tweet.mid == rhs.tweet.mid &&
           // ... other properties
           lhs.originalTweet?.mid == rhs.originalTweet?.mid &&
           lhs.tweet.originalTweetId == rhs.tweet.originalTweetId // Include for stable comparison
}
```

### 4. TweetDetailView Updates (`TweetDetailView.swift`)

**Added:**
- Same stable state management pattern as `TweetItemView`
- `@State private var lastLoadedOriginalTweetId: String?` to track loaded IDs
- `onChange(of: tweet.originalTweetId)` handler to reset state

**Benefits:**
- Prevents refetches when navigating back to a detail view
- Ensures state consistency across view lifecycle

## Key Improvements

### Stability Features (Now Matching Android)

1. ✅ **Stable state with tracked IDs** - `lastLoadedOriginalTweetId` prevents refetches
2. ✅ **onChange handler** - Resets state when `originalTweetId` changes
3. ✅ **Fixed-size placeholder** - Prevents layout shifts during loading
4. ✅ **Improved Equatable** - More stable view identity

### Performance Benefits

1. **Reduced Network Calls** - Only fetches when `originalTweetId` actually changes
2. **No Layout Shifts** - Fixed-size placeholder matches content height
3. **Stable Scrolling** - State persists across recompositions, preventing refetches when scrolling up
4. **Better View Reuse** - Improved Equatable implementation allows SwiftUI to better reuse views

## Testing Recommendations

1. **Scroll Up Test**: Scroll down through retweets, then scroll back up - should not refetch original tweets
2. **Layout Stability**: Check that placeholders don't cause layout shifts when original tweets load
3. **State Persistence**: Verify that state persists when views are recomposed during scrolling
4. **Memory**: Ensure no memory leaks from tracking `lastLoadedOriginalTweetId`

## Comparison with Android

| Feature | Android | iOS (Before) | iOS (After) |
|---------|---------|-------------|-------------|
| Stable state keys | `remember(originalTweetId)` | ❌ None | ✅ `lastLoadedOriginalTweetId` |
| onChange handler | N/A (Kotlin) | ❌ None | ✅ `onChange(of: originalTweetId)` |
| Fixed-size loading | ✅ Fixed container | ⚠️ `minHeight` | ✅ `height` |
| Prevent refetches | ✅ Yes | ❌ No | ✅ Yes |
| Layout stability | ✅ Yes | ⚠️ Partial | ✅ Yes |

## Files Modified

1. `Sources/Tweet/TweetItemView.swift` - Main retweet loading logic
2. `Sources/Tweet/TweetDetailView.swift` - Detail view retweet loading

## Related Documentation

- `docs/android_retweet_implementation_analysis.md` - Analysis of Android implementation
- `docs/fixes/LAYOUT_STABILITY_IMPROVEMENTS.md` - Previous layout stability work
