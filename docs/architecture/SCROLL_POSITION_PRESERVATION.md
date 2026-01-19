# Scroll Position Preservation Implementation

## Overview

Scroll position preservation has been implemented for both the **main feed** and **user profile** views. This ensures that when users navigate between tabs or switch between profiles, they return to the same scroll position where they left off.

## Implementation Details

### Architecture

The implementation uses UIKit's `UITableView` with a persistent `ScrollPositionManager` that survives view controller deallocation:

```
SwiftUI (TweetListView)
    ↓
TweetTableView (UIViewControllerRepresentable)
    ↓
TweetTableViewController (UITableViewController)
    ↓
ScrollPositionManager (Singleton, persistent storage)
```

### Key Components

#### 1. **ScrollPositionManager** (`TweetTableViewController.swift`)
- Singleton class that persists scroll positions across view controller lifecycle
- Stores scroll offsets keyed by `feedIdentifier`
- Survives tab switches and view controller deallocation

```swift
@MainActor
class ScrollPositionManager {
    static let shared = ScrollPositionManager()
    private var scrollPositions: [String: CGFloat] = [:]
    
    func saveScrollPosition(_ position: CGFloat, for identifier: String)
    func getScrollPosition(for identifier: String) -> CGFloat?
    func clearScrollPosition(for identifier: String)
}
```

#### 2. **TweetTableViewController** (`TweetTableViewController.swift`)
- Each instance has a unique `feedIdentifier` property
- Default: `"mainFeed"` for the home feed
- Profile feeds: `"profile_{userId}"` for each user profile

**Scroll Position Lifecycle:**

1. **Save on disappear** (`viewWillDisappear`):
   - Saves current scroll offset if scrolled down (>10pt from top)
   - Saves to both instance variable (for same-session) and persistent storage (for tab switches)
   - Clears saved position if at/near top

2. **Restore on appear** (`viewWillAppear`):
   - First checks instance variable (same-session navigation)
   - Then checks persistent storage (tab switching)
   - Restores position with `setContentOffset(_:animated:false)` to avoid animation glitches

3. **Clear on scroll to top** (`scrollToTop()`):
   - Clears both instance and persistent storage
   - Ensures user sees fresh content when tapping profile avatar

#### 3. **TweetTableView** (`TweetTableView.swift`)
- SwiftUI wrapper that accepts `feedIdentifier` parameter
- Passes `feedIdentifier` to `TweetTableViewController` on creation and updates

#### 4. **TweetListView** (`TweetListView.swift`)
- Accepts `feedIdentifier` parameter with default value `"mainFeed"`
- Passes through to `TweetTableView`

#### 5. **ProfileTweetsSection** (`ProfileTweetsSection.swift`)
- Passes unique identifier: `"profile_{user.mid}"`
- Each user profile gets its own scroll position storage

## Feed Identifiers

| Feed Type | Identifier Format | Example |
|-----------|------------------|---------|
| Main feed | `"mainFeed"` | `"mainFeed"` |
| User profile | `"profile_{userId}"` | `"profile_1234567890"` |
| Bookmarks | `"bookmarks_{userId}"` | `"bookmarks_1234567890"` |
| Favorites | `"favorites_{userId}"` | `"favorites_1234567890"` |

## Behavior

### Home Feed
- Preserves scroll position when switching tabs
- Preserves position when navigating to profile and back
- Clears position when app is killed and restarted (by design - fresh start)

### User Profile
- Each user profile maintains independent scroll position
- Preserves position when switching between profiles
- Preserves position when navigating away and back
- Clears position when tapping profile avatar (scroll to top gesture)

### Edge Cases Handled

1. **Scroll to top gesture**: Clears saved position to prevent restoration
2. **Pull-to-refresh**: Position is not affected
3. **New tweets loaded**: Position preserved during pagination
4. **Tab switching**: Position restored from persistent storage
5. **View controller deallocation**: Position restored from persistent storage
6. **Navigation bar present**: Accounts for `adjustedContentInset` to position correctly below nav bar

## Performance Considerations

- Position save/restore operations are lightweight (single CGFloat storage)
- No observable lag when switching tabs or profiles
- Position restoration happens instantly without animation to avoid jarring effects
- Storage is in-memory (does not persist across app restarts)

## Testing Checklist

- [ ] Main feed: Switch to another tab and back - position preserved
- [ ] Main feed: Navigate to profile and back - position preserved
- [ ] Profile: View user A, scroll down, navigate away, come back - position preserved
- [ ] Profile: View user A, scroll down, view user B, return to user A - position preserved
- [ ] Profile: Tap avatar while viewing profile - scrolls to top and clears position
- [ ] Profile: Pull to refresh - position maintained
- [ ] Profile: Load more tweets - position maintained
- [ ] App kill and restart - all positions cleared (fresh start)

## Future Enhancements

Potential improvements for future consideration:

1. **Persist across app restarts**: Use UserDefaults or other persistent storage
2. **Time-based expiration**: Clear positions after certain time period
3. **Memory management**: Limit number of stored positions to prevent unbounded growth
4. **Smooth restoration**: Optionally animate to saved position instead of instant jump

## Notes

- This implementation is UIKit-based due to SwiftUI's `LazyVStack` causing excessive recomposition and hangs
- The `scrollPosition` modifier in SwiftUI would have been ideal, but is not compatible with UIKit-backed views
- ScrollPositionManager uses `@MainActor` to ensure thread-safety when accessing from SwiftUI views
