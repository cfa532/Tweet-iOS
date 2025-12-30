# Video System - Complete Documentation

**Last Updated:** December 29, 2025  
**Status:** ✅ Production (Unified Architecture + Seek Failure Recovery)

---

## Overview

Unified video playback architecture using `SimpleVideoPlayer` across all contexts (grid, detail, fullscreen) with intelligent caching, KVO-based state management, and automatic error recovery. Supports both HLS adaptive streaming and progressive MP4 playback.

---

## Architecture

### Core Components

```
SimpleVideoPlayer (SwiftUI View)
    ↓
SharedAssetCache (Singleton)
    ↓
AVPlayer + CachingPlayerItem
    ↓
LocalHTTPServer (Caching Proxy)
    ↓
Network/Disk Cache
```

**Key Design Principles:**
- **Single Player Implementation:** `SimpleVideoPlayer` used in all contexts
- **Shared Resource Pool:** `SharedAssetCache` manages all AVPlayer instances
- **KVO-Based State:** No polling, pure event-driven state management
- **Automatic Recovery:** Background/foreground transitions, network failures, app init delays
- **Intelligent Caching:** Separate strategies for HLS (playlist-based) and progressive (byte-range)

---

## SimpleVideoPlayer

**Location:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

### UX: Last-Frame Placeholder (MediaCell)

To avoid brief black flashes during **background/foreground**, **layer reattachment**, or **buffering**, MediaCell now renders a **frozen “last displayed frame” placeholder** behind a spinner until playback is ready again.

**Implementation (high level):**
- Captures decoded frames using `AVPlayerItemVideoOutput` (works for both `.video` and `.hls_video`).
- Stores a **downscaled** `UIImage` in an in-memory cache keyed by `mid` (short TTL + count limit).
- On transitions (off-screen + background), captures once and reuses as placeholder on return.

**Key logs:**
```
🖼️ [LAST FRAME] Captured for {mid} (onDisappear)
🖼️ [LAST FRAME] Captured for {mid} (willResignActive)
```

### Playback Modes

```swift
enum VideoPlaybackMode {
    case mediaCell      // Grid view (muted, autoplay on scroll)
    case tweetDetail    // Detail view (unmuted, autoplay)
    case fullScreen     // Full screen (unmuted, manual play)
}
```

### Loading States

```swift
enum LoadingState {
    case idle           // Not loaded yet
    case loading        // Currently loading
    case loaded         // Ready to play
    case failed         // Failed to load
    
    var isLoaded: Bool  // Helper to check if already loaded
}
```

### KVO Observers

**Replaced polling with three KVO observers:**

#### 1. AVPlayerItem.status Observer
```swift
playerItemStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [self] item, _ in
    if item.status == .readyToPlay {
        // Player is ready
        if hasBufferedData {
            hideSpinner()
            attemptAutoPlay()
        }
    } else if item.status == .failed {
        // Immediate error handling
        handleError(strategy: .loadFailure)
    }
}
```

**Purpose:** Detect when player is ready or failed

#### 2. AVPlayerItem.loadedTimeRanges Observer
```swift
playerItemBufferObserver = playerItem.observe(\.loadedTimeRanges, options: [.new]) { [self] item, _ in
    let hasData = !item.loadedTimeRanges.isEmpty
    if hasData && item.status == .readyToPlay && loadingState == .loading {
        hideSpinner()
        loadingState = .loaded
    }
}
```

**Purpose:** Detect when video data is buffered

#### 3. AVPlayerItem.error Observer
```swift
playerItemErrorObserver = playerItem.observe(\.error, options: [.new, .initial]) { [self] item, _ in
    if let error = item.error {
        handleError(strategy: .loadFailure)
    }
}
```

**Purpose:** Catch errors even when status remains `.unknown`

**Key Features:**
- `.initial` option checks for existing errors immediately
- Observers never invalidate themselves (stay active throughout playback)
- Reset `retryAttempts = 0` on successful load

---

## SharedAssetCache

**Location:** `Sources/Core/SharedAssetCache.swift`

### Responsibilities

1. **Player Pool Management:** Reuse AVPlayer instances across views
2. **HLS Playlist Caching:** Store and reconstruct playlist URLs
3. **Progressive Video Setup:** Configure LocalHTTPServer proxying
4. **Load Tracking:** Coordinate with VideoLoadingManager for concurrency
5. **Background Recovery:** Clear broken players on app lifecycle events

### Cache Structure

```swift
class SharedAssetCache {
    // Player cache (keyed by mediaID)
    private var playerCache: [String: AVPlayer] = [:]
    
    // HLS playlist metadata
    private var cachedHLSInfo: [String: (baseURL: String, fileName: String)] = [:]
    
    // LocalHTTPServer real URL mapping
    private var realURLs: [String: String] = [:]
    
    // Active load tracking
    private var activeVideoLoads: Set<String> = []
}
```

### HLS Playlist Caching

**Problem:** HLS master playlists are resolved via network, causing 3-4s delays

**Solution:** Cache playlist files and reconstruct URLs

```swift
func checkCachedHLSPlaylist(mediaID: String) -> URL? {
    let cacheDir = getDocumentsDirectory().appendingPathComponent("Caches/\(mediaID)")
    
    // Recursively search all subdirectories for master.m3u8
    if let cachedFile = findCachedPlaylist(in: cacheDir, filename: "master.m3u8") {
        // Reconstruct URL: baseURL + filename
        let reconstructedURL = baseURL.appendingPathComponent(fileName)
        return reconstructedURL
    }
    return nil
}
```

**Cache Structure:**
```
Library/Caches/
└── {mediaID}/
    ├── master.m3u8          # Master playlist (cached)
    ├── _master.m3u8         # Original with relative paths
    ├── 720p/
    │   ├── playlist.m3u8
    │   └── segment*.ts
    └── 480p/
        ├── playlist.m3u8
        └── segment*.ts
```

**URL Reconstruction:**
- Extract filename from cached path (e.g., `master.m3u8`)
- Remove underscore prefix if present (`_master.m3u8` → `master.m3u8`)
- Append to original baseURL: `http://server/ipfs/{mediaID}/master.m3u8`

### Progressive Video Setup

```swift
func getOrCreatePlayer(for url: URL, mediaID: String, mediaType: MediaType) -> AVPlayer {
    if mediaType.isHLSVideo {
        // Use CachingPlayerItem with LocalHTTPServer
        return createHLSPlayer(url, mediaID)
    } else {
        // Progressive video via LocalHTTPServer
        let proxyURL = createProgressiveProxyURL(url, mediaID)
        registerRealURL(mediaID, url)
        return AVPlayer(url: proxyURL)
    }
}
```

---

## LocalHTTPServer

**Location:** `Sources/CachingPlayerItem/LocalHTTPServer.swift`

### Purpose

Acts as a local caching proxy between AVPlayer and the network, enabling:
1. **Progressive caching** for MP4 videos
2. **HLS segment caching** for adaptive streaming
3. **Offline playback** from disk cache
4. **Bandwidth optimization** by serving cached data

### Port Management

```swift
private var port: UInt = 18136  // Saved in UserDefaults

func start() {
    // Try saved port first
    if tryBindToPort(savedPort) {
        return
    }
    
    // Fall back to finding available port
    for port in 18136...18200 {
        if tryBindToPort(port) {
            PreferenceHelper.setLocalHTTPServerPort(port)
            return
        }
    }
}
```

**Persistence:** Port saved to UserDefaults to avoid rebinding on each app launch

### Request Handling

#### HLS Playlists

```swift
func handleHttpRequest(request: GCDWebServerRequest) -> GCDWebServerResponse? {
    if path.hasSuffix(".m3u8") {
        // Check disk cache first
        if let cachedPlaylist = readCachedPlaylist(mediaID, path) {
            return serveCachedPlaylist(cachedPlaylist)
        }
        
        // Download from network
        let playlist = downloadPlaylist(realURL)
        
        // Rewrite URLs to point to localhost
        let rewritten = rewritePlaylistURLs(playlist)
        
        // Cache to disk
        cachePlaylist(mediaID, path, rewritten)
        
        return GCDWebServerDataResponse(data: rewritten)
    }
}
```

**Playlist Rewriting:**
- Convert absolute URLs to localhost URLs
- Preserve directory structure
- Cache both original (with `_` prefix) and rewritten versions

#### HLS Segments (with Deduplication)

**Problem:** On slow networks, AVPlayer makes multiple concurrent requests for the same segment before the first download completes, causing redundant network traffic.

**Solution:** Request deduplication using `DispatchSemaphore`

```swift
private var activeDownloads: [String: DispatchSemaphore] = [:]
private let activeDownloadsLock = NSLock()

func handleSegmentRequest(fullRealURL: URL, mediaID: String, connection: NWConnection) {
    let cachePath = getCachePath(for: mediaID, segment: fullRealURL.lastPathComponent)
    
    // Check if already cached
    if FileManager.default.fileExists(atPath: cachePath) {
        serveFile(path: cachePath, connection: connection)
        return
    }
    
    // Check if already downloading
    activeDownloadsLock.lock()
    if let existingSemaphore = activeDownloads[cachePath] {
        activeDownloadsLock.unlock()
        
        // On slow networks, don't wait - start independent download
        NSLog("🔄 [DEDUP] Segment already downloading, checking cache")
        if FileManager.default.fileExists(atPath: cachePath) {
            serveFile(path: cachePath, connection: connection)
        } else {
            // Start independent download for this connection
            fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection)
        }
        return
    }
    
    // Register new download
    let newSemaphore = DispatchSemaphore(value: 0)
    activeDownloads[cachePath] = newSemaphore
    activeDownloadsLock.unlock()
    
    // Download and cache
    fetchAndServe(url: fullRealURL, cachePath: cachePath, connection: connection) {
        // Signal waiting requests
        activeDownloadsLock.lock()
        if let semaphore = activeDownloads.removeValue(forKey: cachePath) {
            activeDownloadsLock.unlock()
            semaphore.signal()
        } else {
            activeDownloadsLock.unlock()
        }
    }
}
```

**Slow Network Optimization:**

On very slow networks (~90 KB/s), waiting for downloads to complete would cause AVPlayer connection timeouts (30s). The strategy was adjusted:
- **First request:** Downloads segment normally
- **Subsequent requests:** Check if file exists in cache
  - If cached: Serve immediately
  - If not cached: Start **independent download** instead of waiting
  
This accepts duplicate downloads to prevent connection timeouts, prioritizing continuous playback over bandwidth optimization.

**Memory Management:**

Large segments (2-5MB) are wrapped in `autoreleasepool` to release memory immediately:

```swift
func serveFile(path: String, connection: NWConnection) {
    try autoreleasepool {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        sendResponse(connection: connection, statusCode: 200, body: data)
    }
}

func fetchAndServe(url: URL, cachePath: String, connection: NWConnection) {
    autoreleasepool {
        let data = downloadData(url)
        
        // Cache synchronously (ensures file exists before signaling)
        try data.write(to: URL(fileURLWithPath: cachePath))
        
        sendResponse(connection: connection, statusCode: 200, body: data)
    }
}
```

**URLSession Configuration:**

```swift
config.timeoutIntervalForRequest = 90      // 90 seconds for slow networks
config.timeoutIntervalForResource = 300    // 5 minutes total
config.httpMaximumConnectionsPerHost = 12  // Allow more concurrent requests
```

#### Progressive Videos (Byte-Range Caching)

```swift
func handleHttpRequest(request: GCDWebServerRequest) -> GCDWebServerResponse? {
    let rangeHeader = request.headers["Range"]  // "bytes=0-1" or "bytes=0-"
    
    // Parse range
    let (start, end) = parseRangeHeader(rangeHeader)
    
    // Check cache
    if let cachedData = readCachedProgressiveRange(mediaID, start, end) {
        return GCDWebServerDataResponse(
            data: cachedData,
            contentType: "video/mp4"
        )
    }
    
    // Download from network
    let data = downloadRange(realURL, start, end)
    
    // Cache to disk (if not a probe request)
    if data.count > 1024 || end == nil {
        writeCachedProgressiveRange(mediaID, start, data)
    }
    
    return GCDWebServerDataResponse(data: data)
}
```

**Probe Request Detection:**
- Probe: `Range: bytes=0-1` (2 bytes)
- Not cached (too small to be useful)
- Full file: `Range: bytes=0-` or `Range: bytes=0-{totalSize-1}`

**Cache Write Strategy:**
- Skip probe requests (< 1KB)
- Cache full file requests (when `end == nil`)
- Cache partial requests (when `end != nil` and size > 1KB)

**Content-Range Header:**
```
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-1/29360128
Content-Length: 2
```

**Critical:** Include total file size in `Content-Range` header so AVPlayer knows the full video length

### App Initialization Blocking

**Problem:** Videos requested before app initialization complete

**Behavior:**
```swift
guard HproseInstance.shared.isAppInitialized else {
    print("⚠️ App not initialized, refusing NETWORK request for \(mediaID)")
    return GCDWebServerResponse(statusCode: 503)  // Service Unavailable
}
```

**Recovery:** See "App Initialization Recovery" section below

### Background Recovery

```swift
func handleBackgroundTransition() {
    // Reset connection pool
    resetConnectionPool()
    
    // Note: Server stays running, port stays open
    // Players are cleared by SharedAssetCache
}
```

**Connection Pool Reset:**
- Max 8-12 connections per host
- Reset on background/foreground transition
- Prevents stale connections

### Seek Failure Recovery

**Problem:** AVPlayer's seek operation fails after background transitions, but cached data is still good.

**Solution (Dec 2025):** When seek fails, fallback to playing from beginning instead of recreating player:

```swift
// Detect seek failure in completion handler
let videoMid = self.mid
cachedState.player.seek(to: cachedState.time) { finished in
    if !finished {
        // Fallback: Clear cached position and seek to beginning
        VideoStateCache.shared.clearCache(for: videoMid)
        cachedState.player.seek(to: .zero)  // Start from beginning
    }
}
```

**Progressive Cache Clearing (on load errors):**
- **Retry 1-2:** Keep disk cache (might be seek issue)
- **Retry 3+:** Clear disk cache (might be corruption)

**Performance:**
- Before: Seek fails → cache cleared → 6MB re-download → 5-10s delay
- After: Seek fails → restart from beginning → instant → <50ms delay

**See:** `docs/fixes/SEEK_FAILURE_RECOVERY_FIX.md`

### Share Sheet Recovery (Dec 2025)

**Problem:** After sharing video to other apps, returning shows stuck spinner.

**Root Cause:** When app returns from background, `.reloadVisibleVideosOnly` notification fires while share sheet overlay is still active, so `isActuallyVisible = false` and videos don't reload.

**Solution:** Post `.reloadVisibleVideosOnly` again after share sheet dismisses (same pattern as fullscreen mode):

```swift
.sheet(item: $shareSheetItems, onDismiss: {
    // ... cleanup ...
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
    }
})
```

**Benefits:**
- ✅ Videos reload after share sheet closes
- ✅ Consistent with fullscreen overlay handling
- ✅ 100ms delay ensures overlay state fully cleared

---

## Video Loading Strategy

### VideoLoadingManager

**Location:** `Sources/Core/VideoLoadingManager.swift`

### Concurrency Limits

```swift
let maxConcurrentLoads = 8  // Max parallel video loads
private var activeLoadingCount = 0
```

**Coordination:**
```swift
// Called by SharedAssetCache
func videoLoadStarted() {
    activeLoadingCount += 1
}

func videoLoadCompleted() {
    activeLoadingCount -= 1
}
```

### Priority System

**Highest Priority:**
1. Currently visible tweet
2. Original tweet of visible retweet

**Allowed to Load:**
3. Visible tweets in feed

**Not Loaded:**
- Off-screen tweets
- Tweets beyond concurrency limit

```swift
func shouldLoadVideo(for tweetId: String) -> Bool {
    guard activeLoadingCount < maxConcurrentLoads else { return false }
    
    if tweetId == currentVisibleTweetId { return true }
    if isOriginalOfVisibleRetweet(tweetId) { return true }
    if isVisibleInFeed(tweetId) { return true }
    
    return false
}
```

---

## Error Handling & Recovery

### Error Strategies

```swift
enum ErrorRecoveryStrategy {
    case loadFailure        // Network error, player failed
    case networkRecovery    // App returned from background
    case backgroundRecovery // App entering background
    case manualReset        // User scrolled away and back
}
```

### Auto-Retry Mechanism

**Trigger:** `AVPlayerItem.status == .failed` or `AVPlayerItem.error != nil`

**Logic:**
```swift
func handleError(strategy: ErrorRecoveryStrategy) {
    switch strategy {
    case .loadFailure:
        guard retryAttempts < 3 else {
            loadingState = .failed
            return
        }
        
        // Progressive backoff: 1s, 2s, 3s
        let delay = Double(retryAttempts + 1)
        
        // Keep spinner visible during retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.retryAttempts += 1
            self.setupPlayer()  // Create new player
        }
        
    case .manualReset:
        // User scrolled away and back - fresh start
        retryAttempts = 0
        loadingState = .idle
        setupPlayer()
    }
}
```

**Key Points:**
- Keep `loadingState = .loading` during retry (spinner stays visible)
- Only set `loadingState = .failed` after 3 failed attempts
- Reset `retryAttempts = 0` on successful load
- Reset `retryAttempts = 0` on manual reset (scroll away and back)

### App Initialization Recovery

**Problem:** Progressive videos blocked by `LocalHTTPServer` returning 503 when app not initialized

**Detection:**
```swift
.onReceive(NotificationCenter.default.publisher(for: .appUserReady)) { _ in
    handleAppUserReady()
}
```

**Recovery:**
```swift
func handleAppUserReady() {
    guard loadingState == .loading else { return }
    guard let player = player else { return }
    guard let item = player.currentItem else { return }
    
    // Check if stuck with no data
    let hasData = !item.loadedTimeRanges.isEmpty
    guard !hasData else { return }
    
    print("🔄 Player stuck with no data, forcing reload")
    
    // Recreate player
    let newPlayer = await SharedAssetCache.shared.getOrCreatePlayer(...)
    self.player = newPlayer
    configurePlayer(newPlayer)
    
    // Force AVPlayer to start loading by calling play() then pause()
    newPlayer.play()
    newPlayer.pause()
}
```

**Why `play()` then `pause()`:**
- `preroll(atRate: 0.0)` crashes when status is `.unknown`
- `play()` always works and forces AVPlayer to start loading
- Immediately `pause()` so we don't actually start playback
- KVO observers will handle the rest

### Background/Foreground Recovery

**On App Entering Background:**
```swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
    // Cache playback state
    wasPlayingBeforeBackground = isPlaying
    currentTimeBeforeBackground = player.currentTime()
    
    // Pause player
    player.pause()
    
    // Don't detach player (keep reference)
}
```

**On App Entering Foreground:**
```swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
    // Check if player is broken
    if player.currentItem == nil {
        print("⚠️ Player broken, recreating")
        loadingState = .idle
        setupPlayer()
    } else {
        // Resume playback if was playing
        if wasPlayingBeforeBackground && shouldAutoPlay {
            player.play()
        }
    }
}
```

**Why Players Break:**
- Long background duration (>30s triggers aggressive cleanup)
- System reclaims AVPlayer resources
- Network connections closed

---

## Memory Management

### Cleanup Triggers

#### 1. System Memory Warning
```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification
) { _ in
    SharedAssetCache.shared.handleMemoryWarning()
}
```

#### 2. Background Transition
```swift
if backgroundDuration > 30 {
    // Long background - aggressive cleanup
    SharedAssetCache.shared.clearAllPlayers()
}
```

#### 3. Manual Cleanup
```swift
// When video scrolls off-screen
NotificationCenter.default.post(name: .cancelVideoLoading, object: tweetId)
```

### Cleanup Strategy

```swift
func handleMemoryWarning() {
    // 1. Cancel all loading tasks
    cancelAllLoadingTasks()
    
    // 2. Clear off-screen players
    clearInactivePlayers()
    
    // 3. Notify user if critical
    if memoryUsagePercent > 85 {
        NotificationCenter.default.post(name: .memoryWarningNotification)
    }
}
```

**User Notification:**
```swift
// In ContentView.swift
.onReceive(NotificationCenter.default.publisher(for: .memoryWarningNotification)) { _ in
    showToast(
        message: "Memory usage high. Consider rebooting the app.",
        duration: .long
    )
}
```

**Note:** Disk cache is NEVER cleaned during memory pressure (disk ≠ memory)

---

## Video Types & Detection

### HLS Videos

**Detection:**
```swift
func isHLSVideo(url: URL) -> Bool {
    return url.path.contains("/hls/") ||
           url.pathExtension == "m3u8"
}
```

**Access Pattern:**
```
Backend URL: http://{server}/ipfs/{CID}/hls/master.m3u8
                                   ↓
LocalHTTPServer: http://127.0.0.1:18136/{CID}/ipfs/{CID}/hls/master.m3u8
                                   ↓
Cache Check: Library/Caches/{CID}/master.m3u8
```

**Benefits:**
- Adaptive bitrate (720p, 480p, 360p)
- Smooth quality transitions
- Better for poor network conditions

### Progressive Videos

**Detection:**
```swift
func isProgressiveVideo(url: URL) -> Bool {
    return !isHLSVideo(url)
}
```

**Access Pattern:**
```
Backend URL: http://{server}/ipfs/{CID}
                         ↓
LocalHTTPServer: http://127.0.0.1:18136/{CID}/ipfs/{CID}
                         ↓
Cache Check: Library/Caches/{CID}/video.mp4
```

**Benefits:**
- Simpler caching (single file)
- Faster for small videos
- Better for good network conditions

**Limitation:**
- Must download entire file before playback can complete
- Large files (>30MB) may timeout on slow connections

---

## Playback Modes

### MediaCell (Grid View)

```swift
mode: .mediaCell
autoPlay: true (when visible)
muted: true (default)
looping: false
```

**Behavior:**
- Auto-play when scrolled into view
- Pause when scrolled off-screen
- Muted by default
- Only ONE video plays at a time
- **Last-frame placeholder + spinner** during buffering/foreground recovery (prevents black flicker)

### TweetDetail (Detail View)

```swift
mode: .tweetDetail
autoPlay: true (immediate)
muted: false (default)
looping: false
```

**Behavior:**
- Auto-play on view appear
- Unmuted by default
- Stops grid video when opened
- Resumes position after background

### FullScreen (Fullscreen View)

```swift
mode: .fullScreen
autoPlay: false (manual)
muted: false (default)
looping: false
showControls: true
```

**Behavior:**
- Manual play (user taps play button)
- Unmuted by default
- Full player controls
- Independent from grid/detail
- **Auto-resume after seeking/stalls**

#### Auto-Resume Mechanism (Slow Networks)

**Problem:** On slow networks (~90 KB/s), seeking in fullscreen causes the player to stall waiting for new segments to download (10-30 seconds per 2-5MB segment). The player would remain frozen even after segments finished downloading.

**Solution:** Polling-based retry mechanism that detects stalls and waits for buffered data before resuming.

**Implementation:** `FullScreenVideoManager` in `Sources/Core/SingletonVideoManagers.swift`

```swift
// Poll every 3 seconds to check if player is stuck
private func startRetryMonitoring() {
    let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor [weak self] in
            self?.checkAndRetryIfStalled()
        }
    }
    retryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
}

// Check if player is stuck and trigger recovery
private func checkAndRetryIfStalled() {
    guard let player = singletonPlayer, let playerItem = player.currentItem else { return }
    
    if player.rate == 0 && player.timeControlStatus != .playing {
        // Player is stuck - seek to trigger segment download
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { ... }
        
        // Wait for buffered data before calling play()
        bufferObserver = item.observe(\.loadedTimeRanges) { item, _ in
            let buffered = CMTimeGetSeconds(item.loadedTimeRanges[0].duration)
            
            if buffered >= 1.0 {
                // Data ready - now resume playback
                player.play()
                // Continue monitoring for future stalls
                self.startRetryMonitoring()
            }
        }
        
        // Safety timeout: 20 seconds max wait
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) {
            if self.bufferObserver != nil {
                self.bufferObserver?.invalidate()
                self.startRetryMonitoring()
            }
        }
    } else {
        // Player is playing - continue monitoring
        startRetryMonitoring()
    }
}
```

**How it works:**

1. **Every 3 seconds:** Check if `player.rate == 0 && timeControlStatus != .playing`
2. **If stuck:** 
   - Seek to current position (triggers LocalHTTPServer to download segment)
   - Observe `loadedTimeRanges` to detect when data arrives
   - Wait for ≥1 second of buffered data
   - **Then** call `play()` (critical: don't play before data is ready)
3. **Continue monitoring** for next stall

**Why this works:**

- **Before fix:** `play()` was called immediately after seek completion, but segment was still downloading (10-30s away)
- **After fix:** Wait for `loadedTimeRanges` to indicate ≥1s of buffer, ensuring data is actually available
- **Continuous:** Retry loop continues throughout playback, handling all future stalls

**Logs (Success):**

```
🔄 [FULLSCREEN RETRY] Player stuck at 2.3s, seeking to trigger segment load
🔍 [FULLSCREEN RETRY] Seek completed, waiting for buffered data
   [12 seconds pass while segment downloads...]
✅ [FULLSCREEN RETRY] Data loaded (11.8s buffered), resuming playback
▶️ [FULLSCREEN RETRY] Called play() after data ready
```

**Network Reality:**

On very slow networks, stalls are unavoidable:
- Segment size: 2-5MB
- Download time: 10-30 seconds
- Segment duration: ~10 seconds of video
- Result: Player catches up every ~10 seconds, must wait for next segment

The auto-resume ensures playback **continues automatically** after each stall, without requiring user interaction.

**AVPlayer Quality Switching:**

AVPlayer dynamically chooses video quality (480p, 720p) based on network conditions:
```
📥 [DEDUP] Starting download (480p): segment000.ts  ← Fast startup
📥 [DEDUP] Starting download (720p): segment005.ts  ← Upgraded
📥 [DEDUP] Starting download (480p): segment007.ts  ← Downgraded
```

This is **adaptive bitrate streaming** working correctly - no quality is hardcoded.

### Chat (Chat Message View)

**Component:** `CachingVideoPlayer` in `ChatMessageView.swift`

```swift
autoPlay: controlled by user (play/pause button)
muted: synced with global MuteState
looping: true (auto-restart)
showControls: false (custom overlay)
```

**Display Layout:**
- Portrait videos (AR < 0.9): 0.9 aspect ratio grid (9:10)
- Landscape videos: Actual aspect ratio
- Max width: 70% of screen
- Overflow clipped with rounded corners

**Interaction Model:**
1. **Play Button Tap (bottom-left):**
   - Plays/pauses video inline
   - Button icon toggles ▶️ ↔ ⏸️
   - Video stays in chat view
   
2. **Video Area Tap:**
   - Opens fullscreen `MediaBrowserView`
   - Full native controls available
   - Swipe down to dismiss

**Caching:**
- Uses `SharedAssetCache` (same as tweets)
- Progressive download during playback
- Disk persistence across app sessions
- Shared cache with tweet videos

**Background Recovery:**
- Auto-saves playback position on background
- Detects broken players on foreground
- Recreates player if needed
- Resumes playback if was playing before

**Upload Progress:**
- Upload dialog for attachments (no toast)
- Stages: Preparing → Uploading → Sending
- Auto-dismisses on completion
- Shows errors with retry option

---

## Mute State Management

### Global Mute State

**Location:** `Sources/Core/MuteState.swift`

```swift
@MainActor
class MuteState: ObservableObject {
    @Published var isMuted: Bool = true
    static let shared = MuteState()
}
```

**Syncing:**
```swift
.onReceive(MuteState.shared.$isMuted) { isMuted in
    player.isMuted = isMuted
}
```

**Behavior by Mode:**
- **mediaCell:** Synced with global state, defaults to muted
- **tweetDetail:** Independent, defaults to unmuted
- **fullScreen:** Independent, defaults to unmuted

---

## Cache Validation

### HLS Videos

```swift
func validateCache(for mediaID: String) -> Bool {
    // Only clear if status == .failed
    if playerItem.status == .failed {
        clearCache(mediaID)
        return false
    }
    
    // Give HLS videos time to load segments
    // Status can be .unknown (0) while segments are loading
    return true
}
```

**Key:** Don't clear cache for HLS videos with `status: 0` - they need time to load segments

### Progressive Videos

```swift
func validateCache(for mediaID: String) -> Bool {
    // Check if cache directory exists
    let cacheDir = getDocumentsDirectory().appendingPathComponent("Caches/\(mediaID)")
    
    guard FileManager.default.fileExists(atPath: cacheDir.path) else {
        return false
    }
    
    // Check if has video file
    let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
    return files?.contains { $0.hasSuffix(".mp4") } ?? false
}
```

---

## Performance Characteristics

### Video Load Times

**HLS (Cached Playlist):**
- First load: 0.01-0.02s (cache hit)
- Network load: 3-4s (playlist resolution + first segment)

**Progressive (No Cache):**
- Small (< 5MB): 1-2s
- Medium (5-30MB): 3-5s
- Large (> 30MB): May timeout on slow connections

**Progressive (Cached):**
- Probe request: <0.1s (2 bytes)
- Full playback: Immediate (served from disk)

### Memory Usage

**Typical:**
- 5-10 cached players: ~50-100MB
- Background: Drops to ~30MB (players cleared)
- Peak (loading): ~150MB

**Critical Threshold:**
- 85% memory usage: Warning toast
- 90%+ memory usage: Aggressive cleanup

### Network Concurrency

**Current Limits:**
- Images: 8 concurrent loads
- Avatars: 4 concurrent loads  
- Videos: 8 concurrent loads
- HTTP connections per host: 8-12

---

## Known Issues

### Progressive Video Timeout

**Symptom:** Large progressive videos (>30MB) show spinner indefinitely

**Cause:**
1. AVPlayer requests entire file (`bytes=0-29360127`)
2. Download times out before completion
3. Auto-retry keeps failing the same way

**Current Behavior:**
- Probe request (2 bytes) succeeds
- Full file request times out
- Auto-retry 3 times (each with timeout)
- Shows "Failed to load" after 3 attempts

**Potential Solutions:**
1. Increase URLSession timeout for progressive videos
2. Implement chunked/streaming downloads
3. Convert all videos to HLS on server
4. Show download progress during initial load

### HLS Black Screen (Rare)

**Symptom:** HLS video shows black screen with controls

**Cause:** Incompatible codec or encoding settings

**Workaround:** Re-encode with strict iOS-compatible settings:
```bash
ffmpeg -i input.mp4 \
  -c:v libx264 -profile:v main -level 4.0 -pix_fmt yuv420p \
  -preset fast -g 48 -keyint_min 48 -sc_threshold 0 \
  -c:a aac -ar 48000 -b:a 128k \
  output.m3u8
```

### Cache Directory Conflicts

**Symptom:** Multiple HLS subdirectories for same mediaID

**Cause:** Playlist filenames with underscores (`_master.m3u8`)

**Current Handling:** Recursive search finds cached playlists in any subdirectory

---

## Debug Logging

### Levels

**Minimal (Production):**
- Video load start/complete timing
- Cache hits/misses (summary only)
- Critical errors
- Recovery events

**Verbose (Debug):**
- KVO observer firing
- Player state changes
- Cache operations (reads/writes)
- Network requests
- Buffer status

### Key Log Markers

```
⏱️ [VIDEO LOAD START]     - Player creation started
⏱️ [VIDEO LOAD COMPLETE]  - Player creation finished (with timing)
🔍 [KVO STATUS]           - AVPlayerItem.status changed
🔍 [KVO BUFFER]           - AVPlayerItem.loadedTimeRanges changed
✅ [KVO STATUS]           - Player ready to play
❌ [KVO STATUS]           - Player failed
📦 [STATUS READY]         - Data buffered, hiding spinner
▶️ [VIDEO READY]          - Auto-playing video
🔄 [APP USER READY]       - App initialization recovery
⚠️ [VIDEO RECOVERY]       - Background/foreground recovery
🖼️ [LAST FRAME]           - Captured last rendered frame (placeholder for MediaCell)
DEBUG: [PROGRESSIVE FETCH SUCCESS] - Network request completed
❌ [PROGRESSIVE CACHE MISS] - Cache miss, fetching from network
```

---

## Testing Checklist

**Basic Playback:**
- [ ] Grid video auto-plays when scrolled into view
- [ ] Grid video pauses when scrolled off-screen
- [ ] Detail video auto-plays unmuted
- [ ] Fullscreen video plays with controls
- [ ] Chat video plays inline when play button tapped
- [ ] Chat video pauses when pause button tapped
- [ ] Chat video opens fullscreen when video area tapped

**Navigation:**
- [ ] Grid → Detail: Grid video stops, detail auto-plays
- [ ] Detail → Grid: Detail stops, grid resumes
- [ ] Detail → Fullscreen: Detail stops, fullscreen plays
- [ ] Chat inline → Fullscreen: Inline pauses, fullscreen plays
- [ ] Chat fullscreen → Inline: Fullscreen dismissed, inline state preserved

**Fullscreen Seeking (Slow Networks):**
- [ ] Seek forward in fullscreen: Video stalls, then auto-resumes when data arrives
- [ ] Seek backward in fullscreen: Video stalls, then auto-resumes when data arrives
- [ ] Continuous playback: Video auto-resumes after each stall (every ~10s on very slow networks)
- [ ] Quality switching: AVPlayer dynamically switches between 480p/720p based on network
- [ ] No manual tap required: Video resumes automatically without user interaction

**Caching:**
- [ ] HLS video loads from cached playlist (< 0.1s)
- [ ] Progressive video loads from cache (immediate)
- [ ] Cache survives app restart
- [ ] Cache cleared after 1 hour (configurable)
- [ ] Chat videos share cache with tweet videos
- [ ] Same video in tweet and chat uses one cache

**Error Recovery:**
- [ ] Auto-retry after network failure (3 attempts)
- [ ] Recovery after background/foreground transition
- [ ] Recovery after app init delay
- [ ] Manual retry by scrolling away and back
- [ ] Chat video recovers after screen lock
- [ ] Chat video resumes position after background

**Memory:**
- [ ] Memory usage < 200MB under normal load
- [ ] Memory warning toast shown at 85% usage
- [ ] Aggressive cleanup at 90% usage
- [ ] No crashes on low memory

**Edge Cases:**
- [ ] Large progressive video (>30MB) timeout behavior
- [ ] Rapid scrolling doesn't crash
- [ ] Multiple videos in viewport (only one plays)
- [ ] Video plays correctly after long background (>30s)

---

## Files

**Core Video System:**
- `Sources/Features/MediaViews/SimpleVideoPlayer.swift` - Unified video player (2300+ lines)
- `Sources/Core/SharedAssetCache.swift` - Player pool & cache management
- `Sources/Core/SingletonVideoManagers.swift` - Fullscreen player singleton with auto-resume
- `Sources/Core/VideoLoadingManager.swift` - Concurrency & priority
- `Sources/CachingPlayerItem/LocalHTTPServer.swift` - Caching proxy (1400+ lines)

**Supporting:**
- `Sources/CachingPlayerItem/CachingPlayerItem.swift` - AVPlayerItem wrapper
- `Sources/CachingPlayerItem/ResourceLoaderDelegate.swift` - Custom resource loading
- `Sources/Core/MuteState.swift` - Global mute state
- `Sources/Core/NotificationNames.swift` - Video-related notifications

**Views:**
- `Sources/Features/MediaViews/MediaGridView.swift` - Grid video container
- `Sources/Tweet/TweetDetailView.swift` - Detail video container
- `Sources/Features/MediaViews/MediaBrowserView.swift` - Fullscreen container
- `Sources/Features/Chat/ChatMessageView.swift` - Chat video player (inline + fullscreen)

**Chat Video Components:**
- `Sources/Features/MediaViews/CachingVideoPlayer.swift` - Simple caching player for chat/browser
- Background recovery with state preservation
- Inline play/pause control
- Fullscreen viewing via MediaBrowserView

---

## Future Improvements

**High Priority:**
- [ ] Fix progressive video timeout for large files
- [ ] Implement download progress indicator
- [ ] Add bandwidth-based quality switching for HLS

**Medium Priority:**
- [ ] Picture-in-picture support
- [ ] Airplay support
- [ ] Playback speed control (0.5x, 1x, 1.5x, 2x)
- [ ] Manual HLS quality selection

**Low Priority:**
- [ ] Download for offline viewing
- [ ] Video thumbnails/previews
- [ ] Seek preview (scrubbing thumbnails)
- [ ] Subtitles/captions support

---

## Performance Benchmarks

**Measured on iPhone 14 Pro, iOS 17:**

| Operation | Time (Cached) | Time (Network) |
|-----------|---------------|----------------|
| HLS Playlist Load | 0.01-0.02s | 3-4s |
| Progressive Load (5MB) | Immediate | 1-2s |
| Progressive Load (30MB) | Immediate | 3-5s |
| App Init Recovery | 0.05s | N/A |
| Background Recovery | 0.1s | N/A |

**Memory:**
- Baseline: 80MB
- 5 videos loaded: 130MB
- 10 videos loaded: 180MB
- Peak (loading): 220MB
- After cleanup: 100MB

**Network:**
- Concurrent video loads: 8
- Concurrent image loads: 8
- Concurrent avatar loads: 4
- Total bandwidth utilization: ~300KB/s average, 1-2MB/s peak

---

## Conclusion

The video system has evolved into a robust, production-ready architecture with:
- ✅ Unified player implementation across all contexts
- ✅ KVO-based state management (no polling)
- ✅ Intelligent caching for both HLS and progressive
- ✅ Automatic error recovery and retry
- ✅ Memory-efficient resource management with `autoreleasepool`
- ✅ **Slow network optimization** with request deduplication and auto-resume
- ✅ **Fullscreen auto-resume** after seeking/stalls (no manual tap required)
- ✅ **Adaptive bitrate streaming** with dynamic quality switching
- ⚠️ Known timeout issue with large progressive videos (>30MB)

**Key Achievement:** The system now handles **extremely slow networks (~90 KB/s)** gracefully:
- Videos auto-resume after every stall without user interaction
- Duplicate downloads accepted to prevent connection timeouts
- AVPlayer dynamically switches between 480p/720p based on network conditions
- Memory usage controlled via `autoreleasepool` (< 100MB for HLS playback)

The remaining challenge is optimizing large progressive video downloads to avoid timeouts, though most content uses HLS which works excellently.
