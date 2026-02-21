# Tweet-iOS Architecture Overview

**Last Updated:** February 2026
**Version:** 3.0

## Architecture Pattern

Tweet-iOS uses a **UIKit/SwiftUI hybrid** architecture. The main feed uses UITableView with pure UIKit cells for maximum scroll performance, while detail/profile/compose screens use SwiftUI with NavigationStack.

## High-Level Architecture

```
Presentation Layer
  UIKit Feed (UITableView + pure UIKit cells)
  SwiftUI Screens (detail, profile, compose, chat, media browser)
  NavigationStack with NavigationPath
      |
  ViewModels (@Published State)
  (HomeViewModel, CommentsViewModel, etc.)
      |
Business Logic Layer
  Managers (TweetCacheManager, ImageCacheManager, VideoManagers)
  VideoPlaybackCoordinator (per-feed instances)
  Repositories (ChatRepository, etc.)
      |
Data Layer
  Network (HproseInstance - Hprose RPC)
  Local Storage (Core Data + caches)
  NodePool (self-healing IP cache)
```

## Feed Architecture (UIKit)

The feed was migrated from SwiftUI to pure UIKit in Phases 1-5 (Feb 2026) for scroll performance:

### UIKit Cell Hierarchy
```
TweetTableViewCell (UITableViewCell)
  └── TweetCellContentView (UIView)
        ├── AvatarUIView (42x42, round image)
        ├── TweetHeaderUIView (name, username, time)
        ├── TweetBodyUIView (text + media)
        │     └── MediaGridUIView (frame-based grid layout)
        │           └── MediaCellUIView (image/video/audio)
        │                 └── LightweightVideoPlayerView (AVPlayerLayer)
        ├── TweetActionBarView (like, retweet, bookmark, comment, share)
        └── EmbeddedTweetUIView (quoted tweets)
```

### Key UIKit Patterns
- **Combine observation**: UIKit views use `.sink()` on `@Published` properties, stored in `cancellables`, cleared in `prepareForReuse()`
- **Frame-based media layout**: `MediaGridUIView.calculateCellFrames()` computes frame-based grid matching golden ratio proportional sizing
- **Video player**: `LightweightVideoPlayerView` wraps AVPlayerLayer directly (no UIHostingController)
- **Closure-based navigation**: UIKit cells use closure callbacks flowing through `TweetTableView` bridge to SwiftUI NavigationStack

### Per-Feed Video Coordination
Each feed has its own `VideoPlaybackCoordinator` instance to prevent state clobbering:
- Main feed uses `VideoPlaybackCoordinator.shared`
- Profile/list feeds create their own coordinator via `@StateObject`
- `VideoPlaybackCoordinator.active` (weak) tracks the currently visible feed
- Coordinator chain: `TweetTableViewController` -> `TweetTableViewCell` -> `TweetCellContentView` -> `TweetBodyUIView` -> `MediaGridUIView` -> `MediaCellUIView`

### Remaining SwiftUI in Feed
- `TweetMenu` (popover)
- `DocumentAttachmentsView`
- `SimpleAudioPlayer`

## SwiftUI Screens

Detail, profile, compose, chat, and media browser screens remain SwiftUI:

- `TweetDetailView`: Tweet with comments thread
- `ProfileView` / `ProfileTweetsSection`: User profile with tweet list
- `ComposeTweetView`: Tweet composition with media attachments
- `ChatScreen`: Direct messaging
- `MediaBrowserView`: Fullscreen media viewer
- `SimpleVideoPlayer`: Used for detail/browser/embedded video modes

## Data Models

### Singleton Pattern
`Tweet` and `User` are `ObservableObject` singletons accessed via `getInstance(mid:)`:
```swift
class Tweet: Identifiable, Codable, ObservableObject {
    private static var instances: [MimeiId: Tweet] = [:]
    static func getInstance(mid: MimeiId, ...) -> Tweet {
        // Returns existing instance (updated) or creates new one
    }
}
```

### Caching Strategy
```
Memory (Tweet/User singletons) - fast, volatile
    | Miss
Disk (Core Data via TweetCacheManager) - persistent
    | Miss
Network (HproseInstance RPC) - authoritative
    | Success
Update Disk -> Update Memory
```

Cache keys use `appUser.mid` prefix, persisted across logouts.

## Key Managers

| Manager | Purpose |
|---------|---------|
| `TweetCacheManager` | In-memory + Core Data tweet caching |
| `ImageCacheManager` | Memory -> disk -> network image pipeline with priority queue |
| `SharedAssetCache` | AVPlayer/AVAsset caching (25 players) |
| `VideoPlaybackCoordinator` | Per-feed autoplay, visibility detection, sequential playback |
| `VideoLoadingManager` | Concurrent video load limits (4) |
| `GlobalImageLoadManager` | Image download priority and concurrency (8 images, 4 avatars) |
| `DetailVideoManager` | Singleton video player for detail views |
| `MemoryWarningManager` | Memory pressure monitoring (1GB threshold) |
| `NotificationManager` | Local push notifications for chat |
| `AudioSessionManager` | Audio session lifecycle |
| `ScrollPositionManager` | In-memory scroll position (no disk persistence) |

## Media Download Priority

| Priority | Use Case |
|----------|----------|
| `critical` | Single visible media |
| `high` | Grid visible media |
| `normal` | Default |
| `low` | Prefetch |

- Priority boosting via `GlobalImageLoadManager.boostPriority()` when media becomes visible
- Cancellation via `cancelLoad()` when scrolled out of view
- `NSURLErrorCancelled` (-999) not counted as network failure

## Concurrency

- **Swift async/await**: Primary pattern for network calls and async operations
- **Combine**: UIKit view observation of `@Published` properties
- **MainActor**: UI updates
- **Task.detached**: Background work (video player creation, image loading)
- **NSLock**: Thread-safe singleton access

## Navigation

SwiftUI `NavigationStack` with `NavigationPath` at the root. UIKit cells trigger navigation via closure callbacks that flow through `TweetTableView` bridge to the SwiftUI navigation system.

## Technology Stack

- **Language:** Swift 5.9+
- **UI:** UIKit (feed) + SwiftUI (screens) hybrid
- **Minimum iOS:** 16.0+
- **Backend:** Hprose RPC
- **Media:** AVFoundation + AVPlayerLayer
- **Storage:** Core Data
- **Networking:** URLSession
- **Build:** `Tweet.xcworkspace`, Scheme: `Tweet`
- **Dependencies (CocoaPods):** SDWebImage, ffmpeg-kit-ios, hprose

## Backend / Server Code

The app talks to a Leither/Hprose backend. Server code is in a **separate repository**:

- **Local path:** `/Users/cfa532/Documents/GitHub/TweetBackendApp`
- **GitHub:** same repo name under account `cfa532` (TweetBackendApp)

When changing APIs, auth, or agent-token behavior, check and update the server implementation there. Key server entry points are `.js` files invoked via `lapi.RunMApp(filename, params, [])` (e.g. `add_tweet.js`, `login.js`, `verify_agent_token.js`).

## Related Documentation

- [Video System](./VIDEO_SYSTEM.md) - Complete video architecture
- [Video Playback Algorithm](./VideoPlaybackAlgorithm.md) - Autoplay and visibility detection
- [Memory Management](./MEMORY_MANAGEMENT.md) - Memory monitoring and cleanup
- [Network Resilience](./NETWORK_RESILIENCE.md) - NodePool, retry logic, BlackList
- [HLS Video](./HLS_VIDEO_IMPLEMENTATION.md) - HLS streaming and local caching
