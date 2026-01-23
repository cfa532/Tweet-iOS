# Phase 2 Architecture Diagram

## Before Phase 2: Mixed Notification Pattern

```
┌─────────────────────────────────────┐
│   VideoPlaybackCoordinator          │
│   (Decides which video to play)     │
└──────────────┬──────────────────────┘
               │
               ├─────────────────────────────────────┐
               │                                     │
               │ (Some calls)                (Some calls)
               ▼                                     ▼
    ┌──────────────────────┐          ┌────────────────────────────┐
    │ NotificationCenter   │          │ SharedVideoPlayerManager   │
    │ (Direct dispatch)    │          │ (Centralized)              │
    └──────────┬───────────┘          └──────────┬─────────────────┘
               │                                 │
               └─────────────┬───────────────────┘
                             │
                             ▼
              ┌─────────────────────────────┐
              │     SimpleVideoPlayer       │
              │  (Listens for notifications)│
              └─────────────────────────────┘

Problems:
❌ Unclear which path handles what
❌ State scattered between coordinator and manager
❌ Hard to debug playback issues
❌ No single source of truth
```

## After Phase 2: Centralized Control Pattern

```
┌─────────────────────────────────────┐
│   VideoPlaybackCoordinator          │
│   (Decides which video to play)     │
└──────────────┬──────────────────────┘
               │
               │ ALL primary video
               │ commands go through
               │ the manager
               ▼
    ┌────────────────────────────────┐
    │  SharedVideoPlayerManager      │
    │  ✅ Single source of truth     │
    │  ✅ Centralized state          │
    │  ✅ Posts notifications         │
    └──────────┬───────────────────────┘
               │
               │ Posts coordinated
               │ notifications
               ▼
    ┌──────────────────────────────┐
    │    NotificationCenter        │
    └──────────┬───────────────────┘
               │
               ▼
    ┌─────────────────────────────┐
    │    SimpleVideoPlayer        │
    │ (Listens for notifications) │
    └─────────────────────────────┘

Benefits:
✅ Clear, single control path
✅ Manager owns all state
✅ Easy to debug (single point)
✅ Manager is source of truth
```

## Call Flow Examples

### Primary Video Playback

#### Before Phase 2
```swift
// Coordinator decides to play video
NotificationCenter.default.post(
    name: .shouldPlayVideo,
    userInfo: [...]
)
// Direct notification - no state tracking
```

#### After Phase 2
```swift
// Coordinator decides to play video
SharedVideoPlayerManager.shared.playVideo(
    videoId: primary.identifier,
    videoMid: primary.videoMid,
    cellTweetId: primary.cellTweetId
)
// Manager updates state + posts notification
// Manager now knows: currentVideoMid, currentlyPlayingVideoId
```

### State Query

#### Before Phase 2
```swift
// No way to ask "what's currently playing?"
// Have to rely on coordinator's internal state
if let primaryId = coordinator.primaryVideoId { ... }
```

#### After Phase 2
```swift
// Direct state query from manager
if let currentMid = SharedVideoPlayerManager.shared.currentVideoMid {
    // Manager is the source of truth
}

// Or check if specific video is playing
if SharedVideoPlayerManager.shared.isPlaying() { ... }
```

## Data Flow: Video Switch During Scroll

### Phase 2 Flow

```
1. USER SCROLLS
   ↓
2. VideoPlaybackCoordinator.updateVisibleTweets()
   ├─ Detects visibility change
   └─ Calls checkAndSwitchVideoIfNeededAsync()
   
3. checkAndSwitchVideoIfNeededAsync()
   ├─ Current video is 30% visible (threshold crossed)
   ├─ Identifies new primary video
   │
   └─ STOP OLD VIDEO:
       ├─ Checks: Is old video managed by SharedVideoPlayerManager?
       │   if SharedVideoPlayerManager.shared.currentVideoMid == oldVideo.videoMid
       └─ YES → SharedVideoPlayerManager.shared.stopCurrentVideo()
           ├─ Manager updates state: currentVideoMid = nil
           └─ Manager posts: .shouldStopVideo notification
   
4. PAUSE OTHER VIDEOS:
   └─ For each visible video except new primary:
       └─ Direct notification: .shouldPauseVideo
           (Not managed by SharedVideoPlayerManager, just background videos)
   
5. START NEW VIDEO:
   └─ SharedVideoPlayerManager.shared.playVideo(...)
       ├─ Manager updates state:
       │   ├─ currentVideoMid = newVideo.videoMid
       │   └─ currentlyPlayingVideoId = newVideo.identifier
       └─ Manager posts: .shouldPlayVideo notification
   
6. SimpleVideoPlayer receives notification
   └─ Starts playback
```

## Architectural Roles

### VideoPlaybackCoordinator
**Role:** Decision Maker
- Monitors scroll position
- Determines which video should play
- Calculates visibility ratios
- Enforces playback rules (50% threshold, etc.)

**Does NOT:**
- ❌ Post play/stop notifications directly (Phase 2)
- ❌ Track which video is currently playing
- ❌ Manage video player state

### SharedVideoPlayerManager
**Role:** State Owner & Coordinator
- Tracks currently playing video
- Owns playback state
- Posts coordinated notifications
- Provides state query API

**Does NOT:**
- ❌ Decide which video to play
- ❌ Calculate visibility
- ❌ Monitor scroll events

### SimpleVideoPlayer
**Role:** Player View
- Renders video
- Responds to notifications
- Manages AVPlayer lifecycle
- Handles playback UI

**Does NOT:**
- ❌ Decide when to play
- ❌ Track global state
- ❌ Coordinate with other players

## Benefits Matrix

| Aspect | Before Phase 2 | After Phase 2 |
|--------|----------------|---------------|
| **State Management** | Split between coordinator & manager | Centralized in manager ✅ |
| **Debugging** | Check multiple locations | Single point of truth ✅ |
| **State Queries** | Internal coordinator state only | Public manager API ✅ |
| **Notification Flow** | Mixed (direct + manager) | Clean (all through manager) ✅ |
| **Code Clarity** | Some ambiguity | Clear separation ✅ |
| **Extensibility** | Limited (scattered control) | Easy (central control point) ✅ |
| **Testing** | Complex (multiple paths) | Simple (single path) ✅ |

## Code Metrics

### Notification Posts by Type

| Notification Type | Before Phase 2 | After Phase 2 | Change |
|-------------------|----------------|---------------|--------|
| `.shouldPlayVideo` (Primary) | 5 direct posts | 0 direct (via manager) | -100% |
| `.shouldStopVideo` (Primary) | 5 direct posts | 0 direct (via manager) | -100% |
| `.shouldPauseVideo` (Background) | 8 direct posts | 3 direct posts | -62.5% |
| **Total Direct Posts** | **18** | **3** | **-83%** |

### Lines of Code Impact

- **Modified methods:** 10
- **New PHASE 2 comments:** 15 locations
- **Deleted notification posts:** 15
- **Added manager calls:** 10
- **Net reduction in direct notifications:** 83%

## Future Evolution: Phase 3 Possibilities

### Potential Enhancements

```
┌────────────────────────────────────┐
│   SharedVideoPlayerManager         │
│   (Phase 3 enhancements)           │
├────────────────────────────────────┤
│                                    │
│  + State persistence               │
│    ├─ Save playback position       │
│    └─ Restore on app restart       │
│                                    │
│  + Analytics integration           │
│    ├─ Track play count             │
│    ├─ Watch time                   │
│    └─ Completion rate              │
│                                    │
│  + System integration              │
│    ├─ Lock screen controls         │
│    ├─ Control Center controls      │
│    └─ Now Playing info             │
│                                    │
│  + Cross-screen coordination       │
│    ├─ Video handoff                │
│    └─ PiP support                  │
│                                    │
└────────────────────────────────────┘
```

### Example: State Persistence (Future)

```swift
// Phase 3: SharedVideoPlayerManager could handle persistence
extension SharedVideoPlayerManager {
    func savePlaybackState() {
        guard let videoId = currentlyPlayingVideoId,
              let currentTime = getCurrentTime() else { return }
        
        UserDefaults.standard.set(videoId, forKey: "lastPlayingVideoId")
        UserDefaults.standard.set(currentTime.seconds, forKey: "lastPlaybackTime")
    }
    
    func restorePlaybackState() {
        guard let videoId = UserDefaults.standard.string(forKey: "lastPlayingVideoId"),
              let timeSeconds = UserDefaults.standard.double(forKey: "lastPlaybackTime") else { return }
        
        // Restore playback...
    }
}
```

## Summary

Phase 2 transforms the architecture from a **mixed control pattern** to a **centralized coordination pattern**, with `SharedVideoPlayerManager` as the single source of truth for video playback state. This makes the code:

- ✅ **Clearer** - One path for all primary video operations
- ✅ **More maintainable** - Centralized state management
- ✅ **Easier to debug** - Single coordination point
- ✅ **More extensible** - Clear place for future enhancements
- ✅ **Better performing** - Fewer redundant notification dispatches

---

**Date:** January 23, 2026  
**Status:** ✅ Complete
