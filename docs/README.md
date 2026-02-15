# Tweet-iOS

A Twitter-like iOS application with a UIKit/SwiftUI hybrid architecture, featuring real-time social media, HLS video streaming, and advanced caching.

## Features

- **Social Media Feed**: Real-time timeline with following and recommendation views
- **Tweet Interactions**: Like, retweet, bookmark, and comment functionality
- **User Profiles**: Complete user profiles with followers/following lists
- **Video Playback**: HLS video streaming with local caching, per-feed autoplay
- **Real-time Chat**: Direct messaging between users
- **Search & Discovery**: Find users and content
- **Offline Support**: Cached content for offline viewing
- **Web3 Node Management**: Tweet limit system encouraging self-hosting

## Architecture

The main feed uses **UITableView with pure UIKit cells** for maximum scroll performance. Detail, profile, compose, and chat screens use **SwiftUI with NavigationStack**.

### Feed Cell Hierarchy (UIKit)
```
TweetTableViewCell
  └── TweetCellContentView
        ├── AvatarUIView
        ├── TweetHeaderUIView
        ├── TweetBodyUIView -> MediaGridUIView -> MediaCellUIView
        ├── TweetActionBarView
        └── EmbeddedTweetUIView
```

### Core Components

- **Hprose RPC**: Backend communication via HproseInstance
- **Core Data**: Local data persistence and caching
- **AVPlayerLayer**: Lightweight video playback (no UIHostingController)
- **Combine**: Reactive property observation in UIKit views
- **NodePool**: Self-healing IP cache for decentralized networking

See [ARCHITECTURE.md](ARCHITECTURE.md) for full details.

## Documentation

**[Documentation Index](INDEX.md)**

### Quick Links

- [Architecture](ARCHITECTURE.md) | [Features](FEATURES.md)
- [Video System](VIDEO_SYSTEM.md) | [Video Playback Algorithm](VideoPlaybackAlgorithm.md)
- [Memory Management](MEMORY_MANAGEMENT.md) | [Network Resilience](NETWORK_RESILIENCE.md)
- [Chat & Search](CHAT_AND_SEARCH_FEATURES.md) | [Upload System](UPLOAD_SYSTEM.md)
- [Debug Build](DEBUG_BUILD_INSTRUCTIONS.md) | [Universal Links](UNIVERSAL_LINKS.md)

## Development

### Requirements

- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

### Setup

1. Clone the repository
2. Install dependencies: `pod install`
3. Open `Tweet.xcworkspace`
4. Build and run (Scheme: `Tweet`)

### Key Files

- `Sources/Tweet/UIKit/TweetTableViewController.swift`: Feed table view controller
- `Sources/Tweet/UIKit/TweetCellContentView.swift`: Pure UIKit tweet cell
- `Sources/Tweet/UIKit/MediaGridUIView.swift`: Frame-based media grid
- `Sources/Tweet/UIKit/MediaCellUIView.swift`: Image/video/audio cell
- `Sources/Core/TweetCacheManager.swift`: Caching system
- `Sources/Core/HproseInstance.swift`: Backend communication

## License

This project is proprietary software. All rights reserved.
