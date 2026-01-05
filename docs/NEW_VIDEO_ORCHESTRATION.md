# New Video Orchestration System

**Created:** January 5, 2026  
**Last Updated:** January 5, 2026  
**Status:** ✅ Production

---

## Overview

The new video orchestration system introduces intelligent video playback management with a 2-second survey phase, primary video selection, and sequential playback. Videos start playing immediately when scrolled into view (with a 0.1s debounce), providing an engaging and responsive user experience.

---

## Key Features

### 1. **Immediate Playback with Smart Debounce**
- Videos start playing **0.1 seconds** after becoming visible
- Prevents unnecessary starts/stops during rapid scrolling
- No need to wait for scroll to stop completely
- Smooth, responsive user experience

### 2. **2-Second Survey Phase**
- All visible videos play simultaneously for 2 seconds
- Gives users a preview of all available content
- Survey begins 0.1s after videos become visible

### 3. **Primary Video Selection**
- After the 2-second survey, the system identifies the "primary video"
- Selection algorithm considers:
  - Distance from viewport center
  - Percentage of video cell visible
  - Combines both factors for optimal selection
- Primary video continues playing to completion

### 4. **Sequential Playback**
- When primary video finishes, automatically starts the next visible video
- Continues until no more visible videos remain
- Seamless transitions between videos
- **Last Frame Display**: Finished videos show their last frame instead of black screen

### 5. **Scroll Persistence**
- Videos keep playing during scroll (no interruption)
- Provides smooth, continuous experience
- Better engagement compared to pause-on-scroll

### 6. **Flicker-Free Background Recovery**
- Videos maintain their last frame when app goes to background
- On return to foreground, video recovers without visible reloading
- Uses cached last frame as placeholder during recovery
- Seamless user experience with no black screens or flickering

---

## Architecture

### Core Components

```
VideoPlaybackCoordinator (Singleton)
├── Phase Management
│   ├── .idle - No playback
│   ├── .surveying - 2s preview of all visible videos
│   └── .primaryPlaying - Primary video playing to completion
│
├── Video Identification
│   ├── buildVideoList() - Extract videos from tweets
│   ├── identifyPrimaryVideo() - Select most visible/centered
│   └── playNextVisibleVideo() - Sequential advancement
│
└── Scroll Management
    ├── updateVisibleTweets() - Track visibility during scroll
    ├── onScrollStopped() - Trigger survey after 2s delay
    └── Keep videos playing during scroll
```

### Integration Points

1. **TweetTableViewController**
   - Passes table view reference to coordinator for viewport calculations
   - Updates visible tweets during scroll
   - Coordinator uses tableView to identify cell positions

2. **TweetTableViewCell**
   - Exposes `tweetId` property for identification
   - Allows coordinator to match cells with videos

3. **SimpleVideoPlayer**
   - Listens for three notifications:
     - `.shouldPlayVideo` - Start playback (survey or primary)
     - `.shouldPauseVideo` - Pause after survey phase
     - `.shouldStopAllVideos` - Stop all playback
   - Handles `isSurvey` flag for 2s preview behavior
   - Handles `isPrimary` flag for continued playback

---

## Playback Flow

### Initial Load

```
User scrolls to tweets with videos
    ↓
TweetTableViewController.updateVisibleTweets()
    ↓
VideoPlaybackCoordinator receives visible tweet IDs
    ↓
Detects new videos became visible
    ↓
Phase reset to .idle
    ↓
Start 0.1s debounce timer (using .common run loop mode)
    ↓
0.1 seconds pass (timer fires even during scroll)
    ↓
startSurveyPhase()
```

### Survey Phase (0-2 seconds)

```
startSurveyPhase()
    ↓
Phase transition: .idle → .surveying
    ↓
Post .shouldPlayVideo notification for ALL visible videos
    with isSurvey=true (starts from beginning)
    ↓
All visible videos start playing simultaneously
    ↓
Survey timer starts (2.0 seconds)
    ↓
Users see preview of all available videos
    ↓
endSurveyPhase()
```

### Primary Selection (2+ seconds)

```
endSurveyPhase()
    ↓
identifyPrimaryVideo()
├── Calculate viewport center
├── Measure distance of each video cell from center
├── Calculate visibility ratio for each cell
└── Select video with best score (centered + visible)
    ↓
Post .shouldPauseVideo for non-primary videos
    ↓
Primary video continues playing to completion
```

### Sequential Playback

```
Primary video finishes
    ↓
SimpleVideoPlayer posts .videoDidFinishPlaying notification
    with videoMid and tweetId
    ↓
VideoPlaybackCoordinator.handleVideoFinished() receives notification
    ↓
Verify this is the primary video (not survey phase video)
    ↓
playNextVisibleVideo()
    ↓
Find next video in visible videos list
    ↓
If next exists: 
    - Set as new primary
    - Post .shouldPlayVideo with isPrimary=true
    - Video continues from current position
    ↓
If no next: stopAllVideos()
```

### During Scroll

```
User starts scrolling
    ↓
updateVisibleTweets() called repeatedly
    ↓
Videos keep playing (no interruption)
    ↓
Set of visible video IDs changes?
    ↓
Yes: Reset phase to .idle, start new 0.1s debounce
    (ensures smooth transitions when new videos scroll into view)
    ↓
No: Keep existing playback state
    (videos continue playing during scroll)
```

### Last Frame Capture & Display

```
Video finishes playing (disableAutoRestart=true)
    ↓
handleVideoFinished() in SimpleVideoPlayer
    ↓
Post .videoDidFinishPlaying notification
    ↓
captureLastFrameNearEndIfPossible(reason: "videoFinished")
    ↓
Seek backwards up to 3 seconds to find non-black frame
    ↓
Use AVPlayerItemVideoOutput to extract pixel buffer
    ↓
Convert to UIImage and cache in VideoLastFrameCache
    ↓
Display cached frame as overlay (prevents black screen)
```

### Background Recovery

```
App enters background
    ↓
SimpleVideoPlayer captures last frame (onDisappear)
    ↓
Frame stored in VideoLastFrameCache
    ↓
App returns to foreground
    ↓
Video layer needs to be reattached
    ↓
While reattaching, show cached last frame as placeholder
    ↓
Once player ready, remove placeholder and resume playback
    ↓
User sees continuous video, no black screen or flicker
```

---

## Key Algorithms

### Primary Video Selection Algorithm

```swift
func identifyPrimaryVideo() -> VideoInfo? {
    let visibleRect = CGRect(...)
    let centerY = visibleRect.midY
    
    var bestVideo: VideoInfo?
    var bestDistance: CGFloat = .infinity
    
    for video in visibleVideos {
        // Get cell position
        let cellCenterY = cellFrame.midY
        let distance = abs(cellCenterY - centerY)
        
        // Calculate visibility ratio
        let intersection = cellFrame.intersection(visibleRect)
        let visibilityRatio = intersection.height / cellFrame.height
        
        // Score: prefer centered AND visible videos
        let score = distance / max(visibilityRatio, 0.1)
        
        if score < bestDistance {
            bestDistance = score
            bestVideo = video
        }
    }
    
    return bestVideo
}
```

**Key Points:**
- Lower score is better
- Dividing distance by visibility ratio means:
  - Videos closer to center get lower scores (better)
  - Videos with higher visibility get lower scores (better)
  - Best video is both centered AND visible

---

## Notifications

### .shouldPlayVideo

**Sender:** `VideoPlaybackCoordinator`  
**Receivers:** `SimpleVideoPlayer` (MediaCell mode only)

**UserInfo:**
```swift
[
    "tweetId": String,
    "videoMid": String,
    "videoIndex": Int,
    "isSurvey": Bool?,      // true = start from beginning (2s preview)
    "isPrimary": Bool?       // true = continue from current position
]
```

**Behavior:**
- `isSurvey=true`: Video seeks to start (CMTime.zero) and plays for 2 seconds
- `isPrimary=true`: Video continues from current position until completion
- Both flags can be combined (survey first, then primary)

### .shouldStopAllVideos

**Sender:** `VideoPlaybackCoordinator`  
**Receivers:** `SimpleVideoPlayer` (all modes)

**UserInfo:** None

**Behavior:**
- Pauses all videos immediately
- Used when visibility changes dramatically

### .videoDidFinishPlaying

**Sender:** `SimpleVideoPlayer`  
**Receivers:** `VideoPlaybackCoordinator`, others

**UserInfo:**
```swift
[
    "videoMid": String,
    "tweetId": String       // Parent tweet ID (optional)
]
```

**Behavior:**
- Posted when video reaches end (AVPlayerItem.didPlayToEndTime)
- Only posted when `disableAutoRestart=true`
- Triggers sequential playback in VideoPlaybackCoordinator

---

## Configuration

### Timing Constants

```swift
// In VideoPlaybackCoordinator
private let PLAYBACK_DEBOUNCE: TimeInterval = 0.1    // Debounce before starting playback
private let SURVEY_DURATION: TimeInterval = 2.0      // Show each video for 2s
```

**To adjust:**
- Change constants in `VideoPlaybackCoordinator.swift`
- Playback debounce: Line ~170 in `updateVisibleTweets()` (Timer initialization)
- Survey duration: Line ~140 in `startSurveyPhase()` (Survey timer)

**Critical Implementation Detail:**
The debounce timer uses `RunLoop.main.add(timer, forMode: .common)` to ensure it fires during active scrolling. The `.common` mode allows the timer to execute even when the main thread is busy with scroll events.

---

## Last Frame Capture System

### Purpose

Prevents black screens when videos finish or when recovering from background by displaying the last rendered frame as a static placeholder.

### Implementation

**Location:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

**Components:**
1. **AVPlayerItemVideoOutput**: Accesses decoded video frames
2. **VideoLastFrameCache**: In-memory cache for captured frames
3. **Capture Logic**: Seeks backwards to find non-black frames

### Capture Algorithm

```swift
func captureLastFrameNearEndIfPossible(reason: String) async {
    // 1. Get current video duration
    let duration = player.currentItem?.duration
    
    // 2. Seek backwards up to 3 seconds to find a good frame
    let captureTime = max(0, duration.seconds - 3.0)
    player.seek(to: CMTime(seconds: captureTime, preferredTimescale: 600))
    
    // 3. Extract pixel buffer using AVPlayerItemVideoOutput
    let output = AVPlayerItemVideoOutput()
    player.currentItem?.add(output)
    let pixelBuffer = output.copyPixelBuffer(forItemTime: captureTime, itemTimeForDisplay: nil)
    
    // 4. Convert to UIImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
    let image = UIImage(cgImage: cgImage)
    
    // 5. Cache the frame
    VideoLastFrameCache.shared.cacheFrame(image, for: videoMid)
}
```

### Display Logic

```swift
// In SimpleVideoPlayer body
ZStack {
    VideoPlayer(player: player)
    
    // Show last frame when finished
    if playbackState == .finished, let cachedFrame = cachedLastFrame {
        Image(uiImage: cachedFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .transition(.opacity)
    }
}
```

### Cache Management

**VideoLastFrameCache:**
- In-memory cache (not persisted to disk)
- TTL: 10 minutes per frame
- Max capacity: 50 frames
- Automatic eviction when capacity exceeded

### Use Cases

1. **Video Finish**: When video reaches end, show last frame instead of black
2. **Background Recovery**: When app returns from background, show cached frame during reload
3. **Seeking**: When seeking to end, show frame before black screen appears

---

## Benefits

### User Experience
- **Engaging preview**: See all available videos quickly
- **Focused viewing**: Automatically selects best video
- **Smooth scrolling**: No jarring pauses during navigation
- **Continuous content**: Sequential playback keeps users engaged

### Performance
- **Shared resources**: Reuses AVPlayer instances via SharedAssetCache
- **Efficient selection**: Single viewport calculation for primary video
- **Smart throttling**: 2s delay prevents excessive re-calculations

### Discoverability
- **Multi-video threads**: Users see all videos in a tweet
- **Fair exposure**: Every visible video gets 2s preview
- **Natural progression**: Videos play in visual order

---

## Testing Checklist

### Basic Functionality
- [x] Videos start playing 0.1s after becoming visible
- [x] All visible videos play during survey phase
- [x] Primary video is correctly identified (centered + visible)
- [x] Primary video plays to completion
- [x] Debounce timer fires during active scrolling (uses .common mode)

### Sequential Playback
- [x] Next video starts when primary finishes
- [x] Sequential playback continues through all visible videos
- [x] Playback stops when no more visible videos
- [x] Finished videos show last frame (not black screen)
- [x] .videoDidFinishPlaying notification posted correctly

### Scroll Behavior
- [x] Videos keep playing during scroll
- [x] Videos start immediately when scrolled into view (0.1s debounce)
- [x] Phase resets to .idle when visible videos change
- [x] Smooth transitions when scrolling between videos
- [x] No multiple restarts during scroll

### Last Frame Display
- [x] Last frame captured properly when video finishes
- [x] Last frame shown as overlay when video ends
- [x] No black screen after video finishes
- [x] Last frame cache works correctly

### Background Recovery
- [x] Last frame cached when app goes to background
- [x] Video recovers without flicker on foreground return
- [x] No visible reloading or black screens
- [x] Seamless user experience during app lifecycle transitions

### Edge Cases
- [x] Single video tweets work correctly
- [x] Multi-video tweets (2+) work correctly
- [x] Rapid scrolling doesn't break state
- [x] Backgrounding app preserves state
- [x] Returning from background resumes correctly
- [x] Fast scroll past videos doesn't cause crashes
- [x] Videos that fail to load don't block others

### Performance
- [x] No memory leaks during extended scrolling
- [x] Smooth scrolling with videos playing
- [x] CPU/battery usage reasonable
- [x] Video transitions are smooth
- [x] Debounce prevents excessive start/stop cycles

---

## Future Enhancements

### Possible Improvements
1. **Smart Survey Duration**: Adjust 2s based on video length
2. **User Preferences**: Allow users to disable survey phase
3. **Machine Learning**: Learn which videos user prefers over time
4. **Picture-in-Picture**: Keep primary video playing in PiP during scroll
5. **Audio Preview**: Brief audio preview during survey phase

### Alternative Selection Algorithms
- **Watch time**: Prefer videos user has watched before
- **Engagement**: Prefer videos with more likes/comments
- **Recency**: Prefer newer videos
- **Author**: Prefer videos from followed users

---

## Migration Notes

### Changes from Old System

**Old Behavior:**
- Stopped all videos when scrolling started
- Played only first visible video after scroll stopped
- 0.1s delay after scroll stop
- No preview phase
- No sequential playback

**New Behavior:**
- Keeps videos playing during scroll
- Plays ALL visible videos in survey phase
- Identifies and focuses on primary video
- Sequential playback after primary finishes
- 2s delay after scroll stop

### Breaking Changes

None - the system uses the same notification-based architecture. Existing code continues to work.

### Backward Compatibility

- All existing video modes (tweetDetail, fullScreen, mediaBrowser) unchanged
- Only MediaCell mode uses new orchestration
- Old VideoManager for MediaGridView can coexist (different context)

---

## Troubleshooting

### Videos not starting when scrolled into view

**Check:**
1. Is debounce timer firing? Look for log: `🎬 [VideoOrchestrator] Debounce complete (0.1s)`
2. Is timer using `.common` run loop mode? (Should fire during scroll)
3. Is phase being reset to `.idle`? Look for log: `🎬 [VideoOrchestrator] Phase reset to .idle`
4. Are visible videos being detected? (Log `visibleTweetIds`)

**Common Issue:**
- Timer not firing during scroll → Check `RunLoop.main.add(timer, forMode: .common)` is used
- Timer blocked by MainActor → Check timer callback uses `DispatchQueue.main.async`

### Videos restarting multiple times during scroll

**Check:**
1. Is phase being reset too aggressively? (Should only reset when video IDs change)
2. Is debounce timer being invalidated properly?
3. Are video IDs being compared correctly? (Use Set comparison)

**Fix:**
- Only reset phase when visible video IDs actually change
- Don't reset phase if videos are just changing positions

### Primary video not identified correctly

**Check:**
1. Is table view reference set? (Log in `TweetTableViewController.viewDidLoad()`)
2. Are cells being found? (Log in `findCell()`)
3. Is viewport calculation correct? (Log visible rect and cell frames)

### Sequential playback not working

**Check:**
1. Is `.videoDidFinishPlaying` notification being sent? (Log in `SimpleVideoPlayer.handleVideoFinished()`)
2. Is coordinator receiving notification? (Log in `VideoPlaybackCoordinator.handleVideoFinished()`)
3. Is finished video the primary video? (Compare videoMid with primaryVideoId)
4. Is next video being found? (Log in `playNextVisibleVideo()`)

**Common Issue:**
- Notification not posted → Check `NotificationCenter.default.post(name: .videoDidFinishPlaying, ...)`
- Wrong video finishing → Only primary video should trigger next video

### Black screen after video finishes

**Check:**
1. Is last frame being captured? Look for log: `🖼️ [LAST FRAME] Captured for {mid}`
2. Is `disableAutoRestart` set to `true`? (Required for capture)
3. Is cached frame being displayed? Check `shouldShowPlaceholder` condition
4. Is `playbackState == .finished`? (Triggers frame display)

**Fix:**
- Ensure `captureLastFrameNearEndIfPossible` is called in `handleVideoFinished`
- Verify `isFinished` is included in `shouldShowPlaceholder` condition
- Check `VideoLastFrameCache` has the frame cached

### Video flickers on background recovery

**Check:**
1. Is last frame cached before backgrounding?
2. Is cached frame shown during recovery?
3. Is recovery happening on main thread?

**Fix:**
- Ensure last frame captured in `.onDisappear` or background notification
- Show cached frame immediately while player recovers
- Use `isHoldingRecoveryCover` flag to show placeholder during recovery

---

## Related Documentation

- [VIDEO_SYSTEM.md](VIDEO_SYSTEM.md) - Overall video architecture
- [VideoPlaybackAlgorithm.md](VideoPlaybackAlgorithm.md) - Old sequential playback (MediaGrid context)
- [SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md](fixes/SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md) - Old implementation

---

## Code Locations

- **Orchestrator:** `Sources/Core/VideoPlaybackCoordinator.swift`
- **Player Integration:** `Sources/Features/MediaViews/SimpleVideoPlayer.swift`
- **Table Integration:** `Sources/Tweet/UIKit/TweetTableViewController.swift`
- **Cell Support:** `Sources/Tweet/UIKit/TweetTableViewCell.swift`

