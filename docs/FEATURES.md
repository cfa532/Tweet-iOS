# Tweet-iOS Features

**Last Updated:** October 10, 2025

## Core Social Media Features

### Feed System

**FollowingsTweetView** (`Sources/Features/Home/FollowingsTweetView.swift`)
- Timeline showing tweets from followed users
- Pull-to-refresh support
- Pagination with infinite scroll
- Real-time tweet updates via notifications
- Optimized scrolling performance with stable view identities

**RecommendedTweetView** (`Sources/Features/Home/RecommendedTweetView.swift`)
- Algorithmic recommendation feed
- Discovery of new content and users
- Same performance optimizations as following feed

### Tweet Interactions

**TweetItemView** (`Sources/Tweet/TweetItemView.swift`)
- Display of individual tweets with rich media
- Support for retweets, quote tweets, and replies
- Optimized with `Equatable` conformance for efficient rendering
- Stable view identities prevent unnecessary re-composition

**TweetActionButtonsView** (`Sources/Tweet/TweetActionButtonsView.swift`)
- Comment button with counter
- Retweet/quote button
- Like button with animation
- Bookmark button
- Share button
- Delete button (for own tweets)

### Comment System

**CommentListView** (`Sources/Tweet/CommentListView.swift`)
- Nested comment threads
- Reply to comments
- Real-time comment updates
- Smart notification filtering based on parent tweet

**CommentDetailView** (`Sources/Tweet/CommentDetailView.swift`)
- View individual comment with its replies
- Full comment thread navigation
- Consistent with tweet detail UI

**Comment Architecture:**
- Comments are `Tweet` objects with `originalTweetId` set
- Retweets load original tweet's comments
- Quote tweets load their own comments
- Proper notification filtering ensures comments appear in correct contexts

See: [Comment System Documentation](./CommentSystemREADME.md)

### Content Moderation

**ContentFilterView** (`Sources/Features/Legal/ContentFilterView.swift`)
- Block users
- Keyword filtering
- Content type filters (profanity, violence, adult content)
- Backend integration with user preference syncing

**ReportTweetView** (`Sources/Features/Legal/ReportTweetView.swift`)
- Report inappropriate content
- Multiple reporting categories (spam, harassment, violence, etc.)
- Submission to system admin
- 24-hour SLA compliance reminder

**TermsOfServiceView** (`Sources/Features/Legal/TermsOfServiceView.swift`)
- Terms acceptance during registration
- Zero tolerance policy
- Clickable link to full terms
- Multi-language support

## Chat & Messaging

**ChatListScreen** (`Sources/Features/Chat/ChatListScreen.swift`)
- List of all conversations
- Last message preview
- Unread message indicators
- Real-time updates

**ChatScreen** (`Sources/Features/Chat/ChatScreen.swift`)
- Individual chat conversation view
- Message bubbles with sender/receiver styling
- Real-time message delivery
- Message input with send button

**ChatRepository** (`Sources/Features/Chat/ChatRepository.swift`)
- Chat data operations
- Message persistence
- Session management
- Backend API integration

## Search & Discovery

**SearchScreen** (`Sources/Features/Search/SearchScreen.swift`)
- User search by username
- Real-time search results
- User profile navigation
- Search history (planned)

## User Profiles

**ProfileView** (`Sources/Features/Profile/ProfileView.swift`)
- User profile display with avatar, bio, stats
- Follow/unfollow functionality
- User tweet timeline
- Edit profile (own profile only)

**ProfileHeaderView** (`Sources/Features/Profile/ProfileHeaderView.swift`)
- Avatar display with fullscreen preview
- User bio and website
- Follow button with status

**ProfileStatsView** (`Sources/Features/Profile/ProfileStatsView.swift`)
- Following/followers counts
- Tweet count
- Clickable stats for detail views

**UserListView** (`Sources/Features/Profile/UserListView.swift`)
- List of followers/following
- User search within list
- Follow/unfollow actions

## Media Handling

### Video Playback

**SimpleVideoPlayer** (`Sources/Features/MediaViews/SimpleVideoPlayer.swift`)
- Unified video player for all contexts
- Three modes: feed, fullscreen, detail
- HLS and progressive MP4 support
- Intelligent caching system
- Seamless fullscreen transitions
- Automatic mute state management

See: [Video System Architecture](./VIDEO_SYSTEM_ARCHITECTURE.md)

**MediaBrowserView** (`Sources/Features/MediaViews/MediaBrowserView.swift`)
- Fullscreen media viewing
- Swipe between multiple media items
- Pinch-to-zoom for images
- Video playback controls
- Download images to Photos
- Drag down to dismiss

**MediaGridView** (`Sources/Features/MediaViews/MediaGridView.swift`)
- Grid layout for multiple media items
- Thumbnail previews
- Tap to fullscreen
- Video indicator overlays

### Image Handling

**Avatar** (`Sources/Features/MediaViews/Avatar.swift`)
- User avatar display
- Cached loading
- Tap for fullscreen view
- Placeholder for loading/error states

**AvatarFullScreenView** (`Sources/Features/MediaViews/AvatarFullScreenView.swift`)
- Fullscreen avatar viewing
- Pinch-to-zoom
- Download to Photos

### Audio Playback

**SimpleAudioPlayer** (`Sources/Features/MediaViews/SimpleAudioPlayer.swift`)
- Audio file playback
- Progress bar with scrubbing
- Play/pause controls
- Mute toggle

## Compose & Editing

**ComposeTweetView** (`Sources/Features/Compose/ComposeTweetView.swift`)
- Create new tweets
- Add text content
- Attach images/videos
- Character count
- Post button with validation

**CommentComposeView** (`Sources/Features/Compose/CommentComposeView.swift`)
- Reply to tweets
- Reply to comments
- Context preview
- Same media attachment support

**ReplyEditorView** (`Sources/Features/Compose/ReplyEditorView.swift`)
- In-line reply editing
- Quick reply functionality
- Auto-focus on appearance

**PollCreationView** (`Sources/Features/Compose/PollCreationView.swift`)
- Create polls with multiple options
- Set poll duration
- Poll voting UI
- Results display

**ThumbnailView** (`Sources/Features/Compose/ThumbnailView.swift`)
- Media attachment previews during compose
- Remove attachment option
- Video/image/audio indicators

**CameraView** (`Sources/Tweet/CameraView.swift`)
- In-app camera capture
- Photo/video recording
- Gallery picker integration

## Performance Optimizations

### Scrolling Performance

**Tweet List Optimizations:**
- **Stable View IDs:** `.id("tweet_\(mid)_\(index)")` prevents recreation
- **Equatable Conformance:** Custom equality logic reduces re-composition
- **Deferred Async:** Original tweet loading happens after view appears
- **Simplified Hierarchy:** `EmbeddedTweetView` avoids nested complexity

**Results:**
- ✅ Smooth scrolling with no jumps
- ✅ Reduced CPU usage during scrolling
- ✅ Better memory efficiency
- ✅ Stable layout with no flicker

See: [README Performance Section](../README.md#performance-optimizations)

### Image Caching

**GlobalImageLoadManager** (`Sources/Core/GlobalImageLoadManager.swift`)
- Priority-based image loading
- High priority for visible images
- Low priority for off-screen preloading
- Automatic cancellation of unnecessary loads

**ImageCacheManager** (`Sources/Core/ImageCacheManager.swift`)
- Compressed image caching
- Memory-efficient storage
- Disk persistence
- LRU eviction

### Video Caching

**SharedAssetCache** (`Sources/Core/SharedAssetCache.swift`)
- Asset and player caching
- MediaID-based keys (IPFS hashes)
- Memory monitoring with proactive cleanup
- Disk cache with metadata persistence

See: [Video Caching System](./VIDEO_CACHING_SYSTEM.md)

## Offline Support

### Data Persistence

**CoreDataManager** (`Sources/Core/CoreDataManager.swift`)
- Local tweet storage
- User data caching
- Offline access to viewed content

**TweetCacheManager** (`Sources/Core/TweetCacheManager.swift`)
- In-memory tweet cache
- Fast access to recently viewed tweets
- Automatic expiration
- Cache by tweet ID, author ID

**ChatCacheManager** (`Sources/Core/ChatCacheManager.swift`)
- Chat message persistence
- Offline message viewing
- Sync when online

## Push Notifications

**NotificationManager** (`Sources/Core/NotificationManager.swift`)
- Push notification registration
- Handle incoming notifications
- Deep linking to relevant content
- Badge management

See: [Push Notifications Documentation](./PUSH_NOTIFICATIONS.md)

## Localization

**Supported Languages:**
- English (en)
- Japanese (ja)
- Chinese Simplified (zh-Hans)

**Localized Strings:**
- `Tweet/en.lproj/Localizable.strings`
- `Tweet/ja.lproj/Localizable.strings`
- `Tweet/zh-Hans.lproj/Localizable.strings`

**Localized Content:**
- All UI text
- Error messages
- Permission requests
- Terms of service

See: [Permission Localization Guide](./PERMISSION_LOCALIZATION_GUIDE.md)

## Network & API

**HproseInstance** (`Sources/Core/HproseInstance.swift`)
- Backend communication layer
- RPC-style API calls
- User authentication
- Tweet operations (create, delete, like, retweet, comment)
- User operations (follow, unfollow, profile)
- Chat operations
- Search operations
- Content moderation

**Network Resilience:**
- Automatic retry logic
- Timeout handling
- Error recovery
- Offline mode support

See: [Network Resilience Documentation](./NETWORK_RESILIENCE.md)

## App Lifecycle Management

**AudioSessionManager** (`Sources/Core/AudioSessionManager.swift`)
- Audio session activation/deactivation
- Audio interruption handling (calls, alarms)
- Category management (playback, ambient)
- Route change handling

**MemoryWarningManager** (`Sources/Core/MemoryWarningManager.swift`)
- System memory warning handling
- Proactive memory monitoring
- Cache cleanup coordination

**BlackList** (`Sources/Core/BlackList.swift`)
- Failed media resource tracking
- Automatic blacklisting after 14+ failures over 1+ week
- Prevents repeated attempts to load broken content
- Persists via UserDefaults (primary) + iCloud (backup)
- Survives cache clearing and app reinstallation
- Zero user intervention required

## UI Components & Utilities

### Custom Views

**MuteState** (`Sources/Utils/MuteState.swift`)
- Global mute toggle for videos
- Observable state shared across views
- Persists across app launches

### Extensions

**URLExtension** (`Sources/CachingPlayerItem/URLExtension.swift`)
- URL manipulation utilities
- Custom scheme handling for video caching

**URLResponseExtension** (`Sources/CachingPlayerItem/URLResponseExtension.swift`)
- HTTP response helpers
- Content-Type detection

### Data Models

**Tweet** (`Sources/DataModels/Tweet.swift`)
- Main tweet model with all properties
- Retweet/quote tweet support
- Comment identification
- Media attachments

**User** (`Sources/DataModels/User.swift`)
- User profile information
- Following/follower counts
- Base URL for media

**ChatMessage** (`Sources/DataModels/ChatMessage.swift`)
- Message content and metadata
- Sender/receiver information
- Timestamp

**MediaType** (`Sources/DataModels/MediaType.swift`)
- Enum for media types: image, video, hls_video, audio

**MimeiFileType** (`Sources/DataModels/MimeiFileType.swift`)
- File attachment metadata
- URL construction
- IPFS hash (mid)

## App Configuration

**AppConfig** (`Sources/App/AppConfig.swift`)
- Environment configuration
- API endpoints
- Feature flags
- Build configurations

**Constants** (`Sources/DataModels/Constants.swift`)
- App-wide constants
- Magic numbers
- Configuration values

## Testing

**Unit Tests:**
- `TweetTests/Core/` - Core logic tests
- `TweetTests/DataModels/` - Data model tests
- `TweetTests/Utils/` - Utility function tests

**UI Tests:**
- `TweetUITests/UserFlows/` - User interaction tests
- End-to-end flow testing
- Accessibility testing

## Planned Features

- [ ] Story/Reels feature
- [ ] Voice tweets
- [ ] Live video streaming
- [ ] Spaces (audio rooms)
- [ ] Advanced analytics
- [ ] Multi-account support
- [ ] Dark mode enhancements
- [ ] Widget support
- [ ] Watch app

## Development Status

- **Core Features:** ✅ Complete
- **Video System:** ✅ Complete
- **Chat System:** 🔄 Basic implementation complete, real-time updates pending
- **Search:** 🔄 Basic implementation complete, advanced filters pending
- **Content Moderation:** ✅ Complete
- **Localization:** ✅ Complete (3 languages)
- **Performance:** ✅ Optimized
- **Offline Support:** ✅ Complete

---

*For detailed implementation information, see the related documentation files.*

