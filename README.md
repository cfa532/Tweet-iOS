# Tweet-iOS

A Twitter-like iOS application built with SwiftUI, featuring real-time social media functionality, video playback, and advanced caching systems.

## Features

- **Social Media Feed**: Real-time timeline with following and recommendation views
- **Tweet Interactions**: Like, retweet, bookmark, and comment functionality
- **User Profiles**: Complete user profiles with followers/following lists
- **Bookmarks & Favorites**: Personal tweet collections
- **Video Playback**: Advanced HLS video streaming with caching
- **Real-time Chat**: Direct messaging between users
- **Search & Discovery**: Find users and content
- **Offline Support**: Cached content for offline viewing
- **Web3 Node Management**: Tweet limit system for users without cloud drive nodes, encouraging self-hosting

## Architecture

### Core Components

- **SwiftUI Views**: Modern declarative UI framework
- **Hprose RPC**: Backend communication layer
- **Core Data**: Local data persistence and caching
- **HLS Streaming**: Adaptive bitrate video delivery

### Key Design Patterns

- **MVVM Architecture**: Separation of concerns with ViewModels
- **Repository Pattern**: Centralized data access through managers
- **Observer Pattern**: Real-time updates via NotificationCenter
- **Factory Pattern**: Object creation and caching

## Performance Optimizations

### Tweet List Scrolling Performance

The app implements several optimizations to ensure smooth scrolling performance, especially when dealing with retweets and quoted tweets that can cause extra re-composition.

#### 1. Stable View Identity
```swift
// TweetListView - Stable row identities
.id("tweet_\(tweet.mid)_\(index)")

// TweetItemView - Stable view identity
.id("\(tweet.mid)_\(originalTweet?.mid ?? "none")")

// EmbeddedTweetView - Stable identity for embedded tweets
.id("embedded_\(tweet.mid)")
```

**Benefits:**
- Prevents unnecessary view recreation during scrolling
- Reduces layout calculations
- Maintains scroll position stability

#### 2. Equatable Conformance
```swift
struct TweetItemView: View, Equatable {
    static func == (lhs: TweetItemView, rhs: TweetItemView) -> Bool {
        return lhs.tweet.mid == rhs.tweet.mid &&
               lhs.isPinned == rhs.isPinned &&
               lhs.isInProfile == rhs.isInProfile &&
               lhs.hideActions == rhs.hideActions &&
               lhs.backgroundColor == rhs.backgroundColor &&
               lhs.originalTweet?.mid == rhs.originalTweet?.mid
    }
}
```

**Benefits:**
- SwiftUI skips re-composition when views haven't changed
- Custom equality logic compares only relevant properties
- Reduces CPU usage during scrolling

#### 3. Deferred Async Operations
```swift
.onAppear {
    // Defer original tweet loading to reduce async operations during scrolling
    if !hasLoadedOriginalTweet, 
       let originalTweetId = tweet.originalTweetId, 
       let originalAuthorId = tweet.originalAuthorId {
        hasLoadedOriginalTweet = true
        Task {
            if let t = try? await hproseInstance.getTweet(
                tweetId: originalTweetId,
                authorId: originalAuthorId
            ) {
                await MainActor.run {
                    originalTweet = t
                    detailTweet = t
                }
            }
        }
    }
}
```

**Benefits:**
- Original tweet loading happens after view appears, not during initial render
- Non-blocking UI updates using `Task` and `MainActor`
- Reduces async work during scrolling

#### 4. Simplified View Hierarchy
```swift
// EmbeddedTweetView instead of nested TweetItemView
struct EmbeddedTweetView: View, Equatable {
    // Lightweight view for embedded tweets
    // No nested TweetItemView complexity
}
```

**Benefits:**
- Eliminates double re-composition overhead
- Reduces view hierarchy complexity
- Faster rendering for quoted tweets

#### 5. Smart Loading Strategy
```swift
@State private var hasLoadedOriginalTweet = false

// Only fetch original tweet if we haven't loaded it yet
if !hasLoadedOriginalTweet {
    // Fetch and cache logic
}
```

**Benefits:**
- Prevents duplicate async operations
- Leverages existing `TweetCacheManager` caching
- Efficient memory usage

#### 6. Caching Integration
The app leverages existing caching infrastructure:
- **TweetCacheManager**: Caches all tweets and their original tweets
- **hproseInstance.getTweet()**: Checks cache first before network requests
- **FollowingsTweetView**: Caches server tweets with `shouldCacheServerTweets: true`

### Performance Results

These optimizations provide:
- ✅ **Smoother Scrolling**: Eliminates jumpy behavior during scrolling
- ✅ **Reduced CPU Usage**: Less re-composition and async work
- ✅ **Better Memory Efficiency**: Smart caching and view reuse
- ✅ **Stable Layout**: Consistent view identities prevent layout jumps
- ✅ **Faster Rendering**: Simplified view hierarchies for complex tweets

### Best Practices

1. **Use Stable IDs**: Always provide stable `.id()` modifiers for list items
2. **Implement Equatable**: Make views equatable when possible for performance
3. **Defer Async Work**: Move heavy operations to `.onAppear` when possible
4. **Simplify View Hierarchy**: Avoid deeply nested views in lists
5. **Leverage Existing Caching**: Use existing cache systems instead of creating new ones

## Documentation

📚 **[Complete Documentation Index](docs/INDEX.md)**

### Quick Links
- **Architecture**: [Architecture Overview](docs/ARCHITECTURE.md) | [Features](docs/FEATURES.md)
- **Video System**: [Video System](docs/VIDEO_SYSTEM.md) | [Video Playback Algorithm](docs/VideoPlaybackAlgorithm.md)
- **Features**: [Comment System](docs/CommentSystemREADME.md) | [Chat & Search](docs/CHAT_AND_SEARCH_FEATURES.md)
- **Upload System**: [Upload System](docs/UPLOAD_SYSTEM.md) | [Memory Management](docs/MEMORY_MANAGEMENT.md)
- **Development**: [Debug Build](docs/DEBUG_BUILD_INSTRUCTIONS.md) | [Localization](docs/PERMISSION_LOCALIZATION_GUIDE.md)
- **Recent Fixes**: [Background Black Screen](docs/fixes/BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md) | [Mute State](docs/fixes/VIDEO_MUTE_STATE_FIX.md) | [Oct 17 Summary](docs/fixes/SESSION_SUMMARY_OCT_17_2025.md)

All technical documentation is organized in the [docs](docs/) folder. Start with the [INDEX.md](docs/INDEX.md) for a complete overview.

## Development

### Requirements
- iOS 16.0+
- Xcode 15.0+
- Swift 5.9+

### Setup
1. Clone the repository
2. Install dependencies: `pod install`
3. Open `Tweet.xcworkspace`
4. Build and run

### Key Files
- `Sources/Tweet/TweetItemView.swift`: Main tweet rendering with performance optimizations
- `Sources/Tweet/TweetListView.swift`: List view with scrolling optimizations
- `Sources/Core/TweetCacheManager.swift`: Caching system for tweets
- `Sources/Core/HproseInstance.swift`: Backend communication layer

## License

This project is proprietary software. All rights reserved.
