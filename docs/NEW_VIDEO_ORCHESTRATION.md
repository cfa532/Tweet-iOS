# New Video Orchestration System

**Created:** January 5, 2026  
**Status:** ✅ Implemented, Pending Testing

---

## Overview

The new video orchestration system introduces intelligent video playback management with a 2-second survey phase, primary video selection, and sequential playback. This creates a more engaging user experience by showing previews of all visible videos before focusing on the most prominent one.

---

## Key Features

### 1. **2-Second Survey Phase**
- When scrolling stops, all visible videos start playing simultaneously
- Each video plays for exactly 2 seconds
- Gives users a preview of all available content

### 2. **Primary Video Selection**
- After the 2-second survey, the system identifies the "primary video"
- Selection algorithm considers:
  - Distance from viewport center
  - Percentage of video cell visible
  - Combines both factors for optimal selection
- Primary video continues playing to completion

### 3. **Sequential Playback**
- When primary video finishes, automatically starts the next visible video
- Continues until no more visible videos remain
- Seamless transitions between videos

### 4. **Scroll Persistence**
- Videos keep playing during scroll (no interruption)
- Provides smooth, continuous experience
- Better engagement compared to pause-on-scroll

### 5. **Post-Scroll Re-evaluation**
- Videos start playing immediately when they become visible
- After scroll stops, waits 2 seconds before re-identifying primary video
- Allows user to settle on content before restarting survey
- Smooth transitions when scrolling between videos

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
startSurveyPhase() IMMEDIATELY (no delay)
    ↓
Scroll stop timer also starts (2s delay for re-evaluation)
```

### Survey Phase (0-2 seconds)

```
startSurveyPhase()
    ↓
Post .shouldPlayVideo notification for ALL visible videos
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
handleVideoFinished() notification
    ↓
playNextVisibleVideo()
    ↓
Find next video in visible videos list
    ↓
If next exists: Set as new primary and play
    ↓
If no next: stopAllVideos()
```

### During Scroll

```
User starts scrolling
    ↓
updateVisibleTweets() called repeatedly
    ↓
Videos keep playing (no pause)
    ↓
Scroll stop timer resets on each call (2s delay)
    ↓
When scrolling stops for 2s: onScrollStopped()
    ↓
Re-evaluate visible videos and restart survey phase
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
    "isSurvey": Bool?,      // true = 2s preview
    "isPrimary": Bool?       // true = play to completion
]
```

### .shouldPauseVideo

**Sender:** `VideoPlaybackCoordinator`  
**Receivers:** `SimpleVideoPlayer` (MediaCell mode only)

**UserInfo:**
```swift
[
    "videoMid": String
]
```

### .shouldStopAllVideos

**Sender:** `VideoPlaybackCoordinator`  
**Receivers:** `SimpleVideoPlayer` (all modes)

**UserInfo:** None

### .videoDidFinishPlaying

**Sender:** `SimpleVideoPlayer`  
**Receivers:** `VideoPlaybackCoordinator`, others

**UserInfo:**
```swift
[
    "videoMid": String
]
```

---

## Configuration

### Timing Constants

```swift
// In VideoPlaybackCoordinator
private let SCROLL_STOP_DELAY: TimeInterval = 2.0   // Wait 2s after scroll stops
private let SURVEY_DURATION: TimeInterval = 2.0      // Show each video for 2s
```

**To adjust:**
- Change constants in `VideoPlaybackCoordinator.swift`
- Scroll stop delay: Line ~82 in `updateVisibleTweets()`
- Survey duration: Line ~122 in `startSurveyPhase()`

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
- [ ] Videos start playing 2s after scroll stops
- [ ] All visible videos play during survey phase
- [ ] Primary video is correctly identified (centered + visible)
- [ ] Non-primary videos pause after survey phase
- [ ] Primary video plays to completion

### Sequential Playback
- [ ] Next video starts when primary finishes
- [ ] Sequential playback continues through all visible videos
- [ ] Playback stops when no more visible videos

### Scroll Behavior
- [ ] Videos keep playing during scroll
- [ ] Scroll stop timer resets correctly
- [ ] 2s delay works after scroll stops
- [ ] Survey phase restarts after new scroll stop

### Edge Cases
- [ ] Single video tweets work correctly
- [ ] Multi-video tweets (2+) work correctly
- [ ] Rapid scrolling doesn't break state
- [ ] Backgrounding app preserves state
- [ ] Returning from background resumes correctly
- [ ] Fast scroll past videos doesn't cause crashes
- [ ] Videos that fail to load don't block others

### Performance
- [ ] No memory leaks during extended scrolling
- [ ] Smooth 60fps scrolling with videos playing
- [ ] CPU/battery usage reasonable
- [ ] Video transitions are smooth

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

### Videos not playing after scroll stops

**Check:**
1. Is scroll stop timer firing? (Log in `updateVisibleTweets()`)
2. Are visible tweets being detected? (Log `visibleTweetIds`)
3. Is survey phase starting? (Log in `startSurveyPhase()`)

### Primary video not identified correctly

**Check:**
1. Is table view reference set? (Log in `TweetTableViewController.viewDidLoad()`)
2. Are cells being found? (Log in `findCell()`)
3. Is viewport calculation correct? (Log visible rect and cell frames)

### Videos pausing unexpectedly

**Check:**
1. Survey timer duration (should be 2.0s)
2. Notification delivery (log in `handleCoordinatorPauseCommand()`)
3. Phase transitions (log phase changes)

### Sequential playback not working

**Check:**
1. Video finish notifications being sent? (Log in `handleVideoFinished()`)
2. Next video being found? (Log in `playNextVisibleVideo()`)
3. Primary video ID being updated? (Log `primaryVideoId` changes)

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

