# Scroll Position Preservation - Flow Diagram

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SwiftUI Layer                            │
│                                                                  │
│  ┌──────────────┐              ┌──────────────────────┐        │
│  │  HomeView    │              │    ProfileView       │        │
│  │              │              │                      │        │
│  │ feedId:      │              │  feedId:             │        │
│  │ "mainFeed"   │              │  "profile_{userId}"  │        │
│  └──────┬───────┘              └──────────┬───────────┘        │
│         │                                  │                    │
│         │                                  │                    │
│  ┌──────▼──────────────────────────────────▼───────────┐       │
│  │           TweetListView                              │       │
│  │                                                      │       │
│  │  - Accepts feedIdentifier parameter                 │       │
│  │  - Default: "mainFeed"                              │       │
│  │  - Profile: "profile_{userId}"                      │       │
│  └──────────────────────┬───────────────────────────────┘       │
└─────────────────────────┼─────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────────────┐
│                   UIKit Wrapper Layer                          │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │         TweetTableView (UIViewControllerRepresentable) │   │
│  │                                                        │   │
│  │  - Bridges SwiftUI to UIKit                           │   │
│  │  - Passes feedIdentifier to view controller           │   │
│  └───────────────────────┬────────────────────────────────┘   │
└────────────────────────────┼───────────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────────┐
│                      UIKit Layer                               │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │          TweetTableViewController                      │   │
│  │                                                        │   │
│  │  var feedIdentifier: String                           │   │
│  │                                                        │   │
│  │  ┌──────────────────────────────────────────────┐    │   │
│  │  │       View Lifecycle Events                  │    │   │
│  │  │                                              │    │   │
│  │  │  viewWillDisappear:                         │    │   │
│  │  │    ├─ Get current scroll offset             │    │   │
│  │  │    ├─ If scrolled down (>10pt):             │    │   │
│  │  │    │   ├─ Save to instance var              │    │   │
│  │  │    │   └─ Save to ScrollPositionManager     │    │   │
│  │  │    └─ Else: Clear saved position            │    │   │
│  │  │                                              │    │   │
│  │  │  viewWillAppear:                            │    │   │
│  │  │    ├─ Check instance var for position       │    │   │
│  │  │    ├─ If not found, check manager           │    │   │
│  │  │    ├─ If position exists:                   │    │   │
│  │  │    │   └─ Restore with setContentOffset     │    │   │
│  │  │    └─ Update lastScrollOffset               │    │   │
│  │  │                                              │    │   │
│  │  │  scrollToTop (avatar tap):                  │    │   │
│  │  │    ├─ Clear instance var                    │    │   │
│  │  │    ├─ Clear manager position                │    │   │
│  │  │    └─ Animate to top                        │    │   │
│  │  └──────────────────────────────────────────────┘    │   │
│  └───────────────────────┬────────────────────────────────┘   │
└────────────────────────────┼───────────────────────────────────┘
                             │
┌────────────────────────────▼───────────────────────────────────┐
│                   Persistent Storage Layer                     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              ScrollPositionManager                     │   │
│  │                    (Singleton)                         │   │
│  │                                                        │   │
│  │  private var scrollPositions: [String: CGFloat]       │   │
│  │                                                        │   │
│  │  Storage Structure:                                   │   │
│  │  ┌─────────────────────────────────────────────┐     │   │
│  │  │ "mainFeed" → 450.5                          │     │   │
│  │  │ "profile_1234567890" → 1200.3               │     │   │
│  │  │ "profile_9876543210" → 320.8                │     │   │
│  │  │ "bookmarks_1234567890" → 0.0                │     │   │
│  │  └─────────────────────────────────────────────┘     │   │
│  │                                                        │   │
│  │  func saveScrollPosition(_ position: CGFloat,         │   │
│  │                          for identifier: String)      │   │
│  │  func getScrollPosition(for identifier: String)       │   │
│  │  func clearScrollPosition(for identifier: String)     │   │
│  └────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

## Sequence Diagram: User Switching Tabs

```
User                 HomeView         TweetTableVC     ScrollPositionManager
 │                      │                   │                    │
 │  Switch to Profile   │                   │                    │
 │─────────────────────>│                   │                    │
 │                      │  viewWillDisappear│                    │
 │                      │──────────────────>│                    │
 │                      │                   │ saveScrollPosition │
 │                      │                   │   ("mainFeed", 450.5)
 │                      │                   │───────────────────>│
 │                      │                   │                    │
 │                      │                   │    Position Saved  │
 │                      │                   │<───────────────────│
 │                      │                   │                    │
 │  (View Profile)      │                   │                    │
 │  ...                 │                   │                    │
 │  ...                 │                   │                    │
 │                      │                   │                    │
 │  Switch back to Home │                   │                    │
 │─────────────────────>│                   │                    │
 │                      │  viewWillAppear   │                    │
 │                      │──────────────────>│                    │
 │                      │                   │ getScrollPosition  │
 │                      │                   │   ("mainFeed")     │
 │                      │                   │───────────────────>│
 │                      │                   │                    │
 │                      │                   │    Return 450.5    │
 │                      │                   │<───────────────────│
 │                      │                   │                    │
 │                      │                   │ setContentOffset   │
 │                      │                   │   (450.5)          │
 │                      │                   │                    │
 │  See feed at saved   │                   │                    │
 │  scroll position     │                   │                    │
 │<─────────────────────│                   │                    │
```

## Sequence Diagram: Tapping Profile Avatar (Scroll to Top)

```
User              ProfileView      TweetTableVC     ScrollPositionManager
 │                     │                 │                    │
 │  Tap Avatar         │                 │                    │
 │────────────────────>│                 │                    │
 │                     │  scrollToTop()  │                    │
 │                     │────────────────>│                    │
 │                     │                 │ clearScrollPosition│
 │                     │                 │   ("profile_xxx")  │
 │                     │                 │───────────────────>│
 │                     │                 │                    │
 │                     │                 │   Position Cleared │
 │                     │                 │<───────────────────│
 │                     │                 │                    │
 │                     │                 │ setContentOffset   │
 │                     │                 │   (0, animated)    │
 │                     │                 │                    │
 │  See profile at top │                 │                    │
 │<────────────────────│                 │                    │
```

## State Transitions

```
┌──────────────────────────────────────────────────────────────┐
│                    Scroll Position States                     │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────┐
    │  No Position │
    │    Saved     │
    └──────┬───────┘
           │
           │ User scrolls down (>10pt)
           │
           ▼
    ┌─────────────┐
    │  Position   │◄────────────┐
    │   Saved     │             │
    └──────┬───────┘             │
           │                     │
           │ View disappears     │ View appears
           │                     │ (restore position)
           ▼                     │
    ┌─────────────┐             │
    │  Position   │─────────────┘
    │  Persisted  │
    └──────┬───────┘
           │
           │ User taps avatar
           │ or scrolls to top
           ▼
    ┌─────────────┐
    │  Position   │
    │   Cleared   │
    └─────────────┘
```

## Feed Identifier Naming Convention

```
┌────────────────────────────────────────────────────┐
│               Feed Identifier Format                │
└────────────────────────────────────────────────────┘

Main Feed:
  feedIdentifier = "mainFeed"

User Profile:
  feedIdentifier = "profile_{userId}"
  Example: "profile_1234567890"

Bookmarks:
  feedIdentifier = "bookmarks_{userId}"
  Example: "bookmarks_1234567890"

Favorites:
  feedIdentifier = "favorites_{userId}"
  Example: "favorites_1234567890"

Search Results:
  feedIdentifier = "search_{query}"
  Example: "search_swift"

Hashtag Feed:
  feedIdentifier = "hashtag_{tag}"
  Example: "hashtag_ios"
```

## Benefits of This Architecture

1. **Separation of Concerns**: Each layer has a clear responsibility
2. **Persistence**: ScrollPositionManager survives view controller deallocation
3. **Per-Feed Storage**: Each feed maintains independent scroll position
4. **SwiftUI Compatible**: Works seamlessly with SwiftUI navigation
5. **UIKit Performance**: Leverages UITableView for smooth scrolling
6. **Memory Efficient**: Only stores single CGFloat per feed
7. **Flexible**: Easy to add new feed types with unique identifiers
