# Tweet-iOS Project Memory

## Architecture
- **Data models**: `Tweet` and `User` are `ObservableObject` singletons accessed via `getInstance(mid:)`
- **UIKit/SwiftUI hybrid**: Feed uses UITableView (`TweetTableViewController`) with pure UIKit cells; detail/profile screens remain SwiftUI
- **Navigation**: SwiftUI `NavigationStack` with `NavigationPath`; UIKit cells use closure callbacks flowing through `TweetTableView` bridge
- **Video coordination**: Per-feed `VideoPlaybackCoordinator` instances (main feed uses `.shared`, profile/list feeds create own); `VideoLoadingManager`, `LightweightVideoPlayerView` (UIKit AVPlayerLayer)
- **Image caching**: `ImageCacheManager` with memory → disk → network tiers
- **Theme colors**: Asset catalog colors `ThemeText`, `ThemeSecondaryText` — use `UIColor(named:)` in UIKit

## Phase 1 Completed (Feb 2026)
Replaced `UIHostingController<AnyView>` per cell with pure UIKit views:
- **New files**: `AvatarUIView`, `TweetHeaderUIView`, `TweetBodyUIView`, `TweetActionBarView`, `EmbeddedTweetUIView`, `TweetCellContentView`
- **Modified**: `TweetTableViewCell` (removed SwiftUIViewCache + UIHostingController), `TweetTableViewController` (removed rowViewBuilder), `TweetTableView` (removed generic RowView), `TweetListView` (removed generic), call sites
- **Phase 3 completed**: `TweetBodyUIView` now uses pure UIKit `MediaGridUIView` + `MediaCellUIView` — no UIHostingController for media grid
- **Remaining SwiftUI in feed**: `TweetMenu` (popover), `DocumentAttachmentsView`, `SimpleAudioPlayer`

## Phase 3 Completed (Feb 2026)
Replaced SwiftUI `MediaGridView` + `MediaCell` with pure UIKit:
- **New files**: `MediaGridUIView` (frame-based grid layout), `MediaCellUIView` (image/video/audio cell)
- **Modified**: `TweetBodyUIView` (removed `mediaHostingController`, uses `MediaGridUIView`), `TweetCellContentView` (removed deferred layout hack, added `setMediaVisible()`), `TweetTableViewCell` (made `tweetContentView` non-private), `TweetTableViewController` (added `didEndDisplaying`, visibility forwarding in `willDisplay`)
- **Grid layout**: `calculateCellFrames()` uses frame-based layout matching SwiftUI MediaGridView exactly (1/2/3/4/5+ attachment cases, golden ratio, proportional sizing)

## Phase 4 Completed (Feb 2026)
Replaced UIHostingController<SimpleVideoPlayer> with pure UIKit `LightweightVideoPlayerView` (AVPlayerLayer):
- **Removed**: `VideoStateBridge`, `VideoPlayerWrapper`, `videoHostingController`, `removeVideoHosting()`
- **Added to MediaCellUIView**: `videoPlayerView` (LightweightVideoPlayerView), direct AVPlayer management, `AVPlayerItemVideoOutput` for frame capture, coordinator command handlers
- **Player lifecycle**: `VideoStateCache` (sync) → `SharedAssetCache.getOrCreatePlayer()` (async) → `configurePlayer()` → `videoPlayerView.setPlayer()`
- **Control flow**: `MediaCellDelegate` methods are sole entry point for play/pause/stop; `.stopAllVideos` notification for global stop
- **Frame capture**: `AVPlayerItemVideoOutput` + `VideoFrameExtractor.makeDownscaledUIImage()` + `VideoLastFrameCache`, throttled 0.75s
- **SimpleVideoPlayer** still used for `.tweetDetail`, `.mediaBrowser`, `.embeddedDetail` modes

## Phase 5 Completed (Feb 2026)
Per-feed VideoPlaybackCoordinator — eliminated singleton state clobbering between feeds:
- **Root cause**: All feeds shared `VideoPlaybackCoordinator.shared`, overwriting each other's `allVideos`, `tableView`, `visibleTweetIds`, and `mediaCellDelegates`
- **Fix**: Main feed keeps `.shared`; profile/list feeds create own coordinator via `@StateObject`
- **Coordinator chain**: `TweetTableViewController` → `TweetTableViewCell.videoCoordinator` → `TweetCellContentView` → `TweetBodyUIView` → `MediaGridUIView` → `MediaCellUIView`
- **feedViewDidAppear**: `TweetListView.onAppear` posts `.feedViewDidAppear` on return; `TweetTableViewController` observer resets `lastVisibleTweetIds` and calls `updateVisibleTweetsForVideoPlayback()` — NO rebuild needed since per-feed coordinators keep `allVideos` intact
- **Modified**: `VideoPlaybackCoordinator` (init internal), `TweetTableViewController`, `TweetTableView`, `TweetListView`, `TweetTableViewCell`, `TweetCellContentView`, `TweetBodyUIView`, `MediaGridUIView`, `MediaCellUIView`, `EmbeddedTweetUIView`, `SingletonVideoManagers`, `ProfileTweetsSection`, `HomeViewModel`

## Fullscreen Video Lifecycle (Feb 2026)

- **Open flow**: `MediaCellUIView.handleVideoTap()` → `saveVideoPositionForFullscreen()` → `.stopAllVideos` (pause only, no network cancel) → present `MediaBrowserView`
- **Overlay coordination**: `MediaBrowserView.onAppear` → `OverlayVisibilityCoordinator.beginOverlay` → coordinator `stopAllVideos()` → delegate pause (no cancel)
- **Player management**: `FullScreenVideoManager.shared` — singleton AVPlayer; `clearSingletonPlayer()` nils out player entirely (AVPlayer creation is lightweight)
- **Position save guard**: `clearSingletonPlayer()` only saves position if `player.currentItem != nil` — prevents 0.0s overwrite when video never loaded (IPFS latency)
- **"Broken" detection**: `MediaBrowserView.SingletonVideoPlayerView.onAppear` checks `singletonPlayer != nil && currentItem == nil` — only fires for genuine background corruption, not after normal dismiss (player is nil'd)
- **Feed cell network**: `.stopAllVideos` and overlay stop only call `player.pause()` — feed cell network connections are NOT cancelled; `cancelLoadingForOutOfSightTweet()` only called from `setVisible(false)` (scroll out of view)

## Media Download Priority System (Feb 2026)
Optimized media download concurrency and priority to ensure visible media loads first:
- **Image concurrent limits**: 12 total, 4 reserved for critical/high priority (`reservedHighPrioritySlots`); normal/low use 8 slots
- **Video concurrent limits**: 6 total (`MAX_CONCURRENT_PLAYER_CREATIONS`), 2 reserved for high-priority (visible); preloads use 4 slots
- **Priority levels**: `critical` > `high` > `normal` > `low` (GlobalImageLoadManager)
- **Visible media priority**: Single media uses `critical`, grid media uses `high`
- **Priority boosting**: `GlobalImageLoadManager.boostPriority()` upgrades pending requests when media becomes visible
- **Slot reservation (images)**: `canStartLoad(priority:)` in GlobalImageLoadManager — last `reservedHighPrioritySlots` slots only for high/critical
- **Slot reservation (videos)**: `canStartCreation(isHighPriority:)` in SharedAssetCache — preloads pass `isHighPriority: false`, visible cells default `true`; high-priority queued at front, low-priority at back
- **Critical memory bypass**: `waitForMemoryWindow()` in ImageCacheManager accepts `priority:` — `.critical` skips memory pressure blocking entirely; duplicate request rejection also skipped for critical
- **HLS URL resolution**: `resolveHLSURL()` probes `master.m3u8` and `playlist.m3u8` in parallel (`async let`), worst case 8s instead of 16s
- **Feed buffer durations**: Progressive 10s, HLS 5s (reduced from 30s/15s); fullscreen/detail keeps 30s
- **Cancellation**: Images/videos cancelled via `cancelLoad()` when scrolled out of view (MediaCellUIView.setVisible(false))
- **Avatar handling**: Task-based cancellation with automatic queue processing in ImageCacheManager (4 concurrent)
- **Cancellation error handling**: NSURLErrorCancelled (-999) not counted as network failure, no retry scheduled, cache preserved

## Scroll Position (Feb 2026)
In-memory only scroll position for same-session navigation (no disk persistence):
- **ScrollPositionManager**: Pure in-memory singleton — positions lost on app restart (feed starts from top)
- **Save triggers**: `scrollViewDidEndDragging`, `scrollViewDidEndDecelerating`, `viewWillDisappear`
- **Restore triggers**: `viewWillAppear` (checks instance var first, then in-memory ScrollPositionManager)
- **Per-feed identifiers**: `"mainFeed"`, `"profile_{userId}"`, `"bookmarks_{userId}"`, `"favorites_{userId}"`
- **Why no disk persistence**: Restoring absolute pixel offset on cold start caused wrong cell heights (estimated heights don't match actual Auto Layout heights for cells above viewport, especially pure retweets whose original tweet may not be loaded yet)

## Key Patterns
- UIKit views use Combine `.sink()` for `@Published` property observation, store in `cancellables`, clear in `prepareForReuse()`
- Adding files to Xcode project requires editing `project.pbxproj`: PBXFileReference + PBXBuildFile + PBXGroup children + Sources build phase
- `composeAttachmentTypeText(for:)` is a global function in `TweetActionButtonsView.swift` (line 52)
- `TweetListView` is used by: `FollowingsTweetView`, `ProfileTweetsSection`, `TweetListDestinationView` (in HomeViewModel.swift)

## Build
- Workspace: `Tweet.xcworkspace`, Scheme: `Tweet`
- Simulators: iPhone 17 Pro (OS 26.2) works; iPhone 16 not available

## Login / Provider IP
- `getProviderIP` always uses entry node (via `findEntryIP()`), never `appUser.hproseClient`
- IPv6 is allowed — do NOT force `v4Only=true` during login
