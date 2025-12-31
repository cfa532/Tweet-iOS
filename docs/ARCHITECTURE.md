# Tweet-iOS Architecture Overview

**Last Updated:** December 29, 2025  
**Version:** 2.0

## Architecture Pattern

Tweet-iOS follows a **MVVM (Model-View-ViewModel)** architecture with SwiftUI, enhanced with modern Swift concurrency (async/await) and reactive programming patterns using Combine.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Presentation Layer                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │            SwiftUI Views                                │ │
│  │  (TweetItemView, ProfileView, MediaBrowserView, etc.)  │ │
│  └────────────────┬───────────────────────────────────────┘ │
│                   │                                           │
│  ┌────────────────▼───────────────────────────────────────┐ │
│  │            ViewModels (@Published State)                │ │
│  │  (HomeViewModel, CommentsViewModel, etc.)               │ │
│  └────────────────┬───────────────────────────────────────┘ │
└───────────────────┼───────────────────────────────────────────┘
                    │
┌───────────────────▼───────────────────────────────────────────┐
│                      Business Logic Layer                      │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   Managers                               │  │
│  │  (TweetCacheManager, ImageCacheManager, VideoManagers)  │  │
│  └────────────────┬───────────────────────────────────────┘  │
│                   │                                            │
│  ┌────────────────▼───────────────────────────────────────┐  │
│  │                 Repositories                             │  │
│  │           (ChatRepository, etc.)                         │  │
│  └────────────────┬───────────────────────────────────────┘  │
└───────────────────┼────────────────────────────────────────────┘
                    │
┌───────────────────▼────────────────────────────────────────────┐
│                       Data Layer                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              Network (HproseInstance)                   │   │
│  │           Backend Communication (RPC)                   │   │
│  └────────────────┬───────────────────────────────────────┘   │
│                   │                                             │
│  ┌────────────────▼───────────────────────────────────────┐   │
│  │         Local Storage (Core Data + Caches)              │   │
│  │  (CoreDataManager, SharedAssetCache, CachingPlayerItem) │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Layer Breakdown

### 1. Presentation Layer

**SwiftUI Views**
- Declarative UI using SwiftUI
- Reactive to @Published properties from ViewModels
- Compositional view hierarchy
- Reusable components

**Key Views:**
- `TweetItemView`: Individual tweet display
- `TweetListView`: Scrollable tweet feed
- `TweetDetailView`: Tweet with comments
- `ProfileView`: User profile
- `MediaBrowserView`: Fullscreen media viewer
- `ComposeTweetView`: Tweet composition
- `ChatScreen`: Chat interface

**View Principles:**
- **Equatable Conformance:** Custom equality for performance
- **Stable IDs:** Prevent unnecessary view recreation
- **Deferred Loading:** Async operations after view appears
- **Simplified Hierarchy:** Avoid deep nesting for performance

### 2. Business Logic Layer

**ViewModels**
- `@Published` properties for reactive updates
- Business logic and state management
- Coordinate between Views and Data Layer
- Handle user interactions

**Examples:**
```swift
class HomeViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading = false
    
    func loadTweets() async {
        // Fetch from cache/network
        // Update @Published properties
    }
}
```

**Managers**
- Singleton pattern for shared state
- Coordinate multiple concerns
- Cache management
- Resource lifecycle

**Key Managers:**
- `TweetCacheManager`: In-memory tweet caching
- `ImageCacheManager`: Image caching with compression
- `SharedAssetCache`: Video asset and player caching
- `VideoStateCache`: Player state for seamless transitions
- `DetailVideoManager`: Singleton video player for detail views
- `AudioSessionManager`: Audio session lifecycle
- `NotificationManager`: Push notifications
- `MemoryWarningManager`: Memory pressure handling

**Repositories**
- Data access abstraction
- Coordinate local and remote data
- Handle data synchronization

**Example:**
```swift
class ChatRepository {
    func fetchMessages() async throws -> [ChatMessage] {
        // Try local cache first
        // Fall back to network
        // Update cache
    }
}
```

### 3. Data Layer

**Network Layer**
- `HproseInstance`: RPC-style backend communication
- Async/await for network calls
- Error handling and retry logic
- Authentication and session management
- **Smart IP Resolution**: First attempt uses cached IP, retries force fresh resolution
  - Handles server migrations automatically
  - Minimizes provider IP lookups
  - See `NETWORK_RESILIENCE.md` for details

**Key Operations:**
```swift
// Tweet operations
func getTweet(tweetId: String, authorId: String) async throws -> Tweet
func createTweet(content: String, attachments: [String]) async throws -> Tweet
func deleteTweet(tweetId: String) async throws
func likeTweet(tweetId: String, authorId: String) async throws

// User operations
func followUser(userId: String) async throws
func unfollowUser(userId: String) async throws
func getProfile(userId: String) async throws -> User

// Comment operations
func addComment(tweetId: String, content: String) async throws -> Tweet
func getComments(tweetId: String) async throws -> [Tweet]
```

**Local Storage**
- **Core Data**: Persistent storage for tweets, users, messages
- **UserDefaults**: App preferences, cache metadata
- **File System**: Cached media files (images, videos, audio)

**Caching Strategy:**
```
Memory Cache (Fast, Volatile)
    ↓ Miss
Disk Cache (Medium, Persistent)
    ↓ Miss
Network (Slow, Authoritative)
    ↓ Success
Update Disk → Update Memory
```

## Data Flow

### Tweet Loading Flow

```
User Opens App
    ↓
HomeViewModel.loadTweets()
    ↓
TweetCacheManager.getCachedTweets()
    ↓ If Empty
HproseInstance.getTimeline()
    ↓ Network Response
TweetCacheManager.cacheTweets()
    ↓
HomeViewModel updates @Published tweets
    ↓
SwiftUI View Re-renders
```

### Video Playback Flow

```
User Scrolls to Video
    ↓
VideoLoadingManager approves load
    ↓
SimpleVideoPlayer.setupPlayer()
    ↓
SharedAssetCache.getOrCreatePlayer()
    ↓ Check Cache
If Cached: Return cached player
    ↓ If Not Cached
CachingPlayerItem creates player
    ↓
Download & cache segments
    ↓
VideoStateCache stores player state
    ↓
Video plays
```

### Comment Posting Flow

```
User Types Comment → Taps Send
    ↓
HproseInstance.addComment()
    ↓ Network Success
Create Comment Tweet Object
    ↓
Post .newCommentAdded notification
    ↓
CommentListView receives notification
    ↓ Filter by originalTweetId
If Match: Insert comment at top
    ↓
SwiftUI View Re-renders with new comment
```

## Key Design Patterns

### 1. Singleton Pattern

**Used For:**
- `SharedAssetCache.shared`
- `TweetCacheManager.shared`
- `DetailVideoManager.shared`
- `MuteState.shared`
- `AudioSessionManager.shared`

**Benefits:**
- Shared state across app
- Single source of truth
- Memory efficiency

### 2. Factory Pattern

**Used For:**
- `SharedAssetCache.getOrCreatePlayer()`: Creates or returns cached players
- `ImageCacheManager.getOrCreateImage()`: Creates or returns cached images

**Benefits:**
- Encapsulates creation logic
- Caching integration
- Consistent object creation

### 3. Observer Pattern

**Used For:**
- `NotificationCenter` for app-wide events
- `@Published` properties for reactive UI
- `Combine` for data streams

**Key Notifications:**
```swift
// Tweet events
.newTweetCreated
.tweetDeleted
.tweetUpdated

// Comment events
.newCommentAdded
.commentDeleted

// Video events
.stopAllVideos

// Chat events
.newChatMessageReceived
.chatMessageSent
```

### 4. Repository Pattern

**Used For:**
- `ChatRepository`: Chat data access
- (Implicit in HproseInstance for tweets/users)

**Benefits:**
- Abstraction over data sources
- Testability
- Separation of concerns

### 5. Delegate Pattern

**Used For:**
- `CachingPlayerItemDelegate`: Video caching events
- `AVAssetResourceLoaderDelegate`: HLS content loading

**Benefits:**
- Callback-based notifications
- Decoupling
- Flexibility

## Dependency Injection

**SwiftUI Environment:**
```swift
@EnvironmentObject var hproseInstance: HproseInstance
@EnvironmentObject var muteState: MuteState
```

**Initialization Injection:**
```swift
struct TweetItemView: View {
    let tweet: Tweet
    let videoManager: VideoManager? // Optional injection
    // ...
}
```

## State Management

### View State
- `@State`: View-local state
- `@Binding`: Two-way binding to parent state
- `@StateObject`: View-owned observable object
- `@ObservedObject`: Parent-owned observable object
- `@EnvironmentObject`: App-wide shared object

### Global State
- Singleton managers for app-wide state
- `NotificationCenter` for loose coupling
- `Combine` for reactive streams

## Concurrency Model

### Swift Concurrency (Primary)

```swift
// Async/await for network calls
func loadTweets() async throws -> [Tweet] {
    return try await hproseInstance.getTimeline()
}

// Task for background work
Task.detached(priority: .userInitiated) {
    let player = try await createPlayer()
    await MainActor.run {
        self.player = player
    }
}

// MainActor for UI updates
@MainActor
class HomeViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
}
```

### DispatchQueue (Legacy, Being Phased Out)

```swift
// Still used in some older code
DispatchQueue.main.async {
    self.isLoading = false
}
```

## Error Handling

### Network Errors

```swift
do {
    let tweets = try await hproseInstance.getTimeline()
    // Success
} catch {
    // Log error
    print("ERROR: Failed to load tweets: \(error)")
    // Show user-friendly message
    // Fall back to cache
}
```

### Caching Errors

- Graceful degradation to network
- Invalidate corrupt cache entries
- Retry logic with exponential backoff

### Memory Errors

- Proactive memory monitoring
- Automatic cache cleanup at thresholds
- System memory warning handling

## Testing Strategy

### Unit Tests

**Test Targets:**
- Data models (Codable, Equatable)
- Business logic in managers
- Utility functions

**Example:**
```swift
func testTweetCacheManager() {
    let cache = TweetCacheManager.shared
    let tweet = Tweet(...)
    cache.cacheTweet(tweet)
    XCTAssertEqual(cache.getCachedTweet(for: tweet.mid), tweet)
}
```

### UI Tests

**Test Targets:**
- User flows (login, post tweet, comment)
- Navigation
- Accessibility

### Integration Tests

**Test Targets:**
- Network + Cache integration
- Video playback system
- Comment notification system

## Performance Optimizations

### UI Performance

1. **Equatable Views:** Prevent unnecessary re-renders
2. **Stable IDs:** Consistent view identity
3. **Deferred Loading:** Load after view appears
4. **Image Compression:** Reduce memory footprint
5. **LazyVStack:** Only render visible rows

### Memory Management

1. **LRU Caches:** Least Recently Used eviction
2. **Proactive Monitoring:** Memory checks every 10s
3. **Automatic Cleanup:** At 800MB threshold
4. **Weak References:** Avoid retain cycles

### Network Optimization

1. **Caching:** Reduce redundant requests
2. **Pagination:** Load data in chunks
3. **Image CDN:** Optimized image delivery
4. **Video Streaming:** HLS adaptive bitrate

## Security Considerations

### Authentication

- Token-based authentication
- Secure token storage (Keychain)
- Automatic token refresh

### Data Protection

- HTTPS for all network calls
- Encryption at rest (Core Data)
- Secure file storage

### Content Moderation

- User blocking
- Content reporting
- Keyword filtering
- Server-side moderation

## Scalability Considerations

### Caching Strategy

- Aggressive caching for frequently accessed data
- Cache invalidation on updates
- Partitioned caches (images, videos, tweets)

### Memory Budget

- Asset cache: 30 items
- Player cache: 25 items
- Tweet cache: Unlimited (in-memory dictionary)
- Image cache: LRU with memory pressure response

### Network Efficiency

- Pagination for large lists
- Incremental loading
- Background preloading
- Request deduplication

## Technology Stack

### Core Technologies

- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI
- **Minimum iOS:** 16.0+
- **Backend Communication:** Hprose RPC
- **Media Playback:** AVFoundation
- **Local Storage:** Core Data
- **Networking:** URLSession
- **Concurrency:** Swift Async/Await
- **Reactive:** Combine

### Third-Party Dependencies (CocoaPods)

- **SDWebImage:** Image loading and caching
- **SDWebImageSwiftUI:** SwiftUI integration
- **ffmpeg-kit-ios:** Video conversion
- **hprose:** RPC framework

## Build Configurations

### Debug

- Verbose logging enabled
- Development servers
- Faster build times
- Debug symbols included

### Release

- Optimizations enabled
- Production servers
- Stripped debug symbols
- Smaller binary size

## Related Documentation

- [Video System Architecture](./VIDEO_SYSTEM_ARCHITECTURE.md)
- [Video Caching System](./VIDEO_CACHING_SYSTEM.md)
- [Comment System](./CommentSystemREADME.md)
- [Features Overview](./FEATURES.md)
- [Network Resilience](./NETWORK_RESILIENCE.md)

---

*This architecture document reflects the current production implementation as of October 2025.*

