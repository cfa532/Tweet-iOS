# Documentation Update - January 5, 2026

**Summary:** Updated video system documentation to reflect recent orchestration improvements, sequential playback fixes, and last frame capture enhancements.

---

## Files Updated

### 1. NEW_VIDEO_ORCHESTRATION.md

**Status:** ✅ Complete and up-to-date

**Key Updates:**
- **Immediate Playback**: Documented 0.1s debounce mechanism with `.common` run loop mode
- **Last Frame Capture**: Added comprehensive section on last frame capture system
  - AVPlayerItemVideoOutput implementation
  - VideoLastFrameCache management
  - Display logic for finished videos
  - Background recovery without flicker
- **Sequential Playback**: Enhanced notification flow documentation
  - `.videoDidFinishPlaying` notification details
  - Survey vs. primary mode behavior
  - Coordinator handling of video finish events
- **Troubleshooting**: Expanded troubleshooting section with common issues
  - Videos not starting when scrolled into view
  - Videos restarting multiple times
  - Black screen after video finishes
  - Background recovery flicker
- **Testing Checklist**: Marked all features as tested and working
- **Configuration**: Updated timing constants and implementation details

### 2. VIDEO_SYSTEM.md

**Status:** ✅ Complete and up-to-date

**Key Updates:**
- **Overview**: Added reference to new video orchestration system
- **SimpleVideoPlayer Section**: 
  - Enhanced last-frame placeholder documentation
  - Added capture triggers (onDisappear, willResignActive, videoFinished, backgroundRecovery)
  - Documented sequential playback integration
  - Added notification flow diagram
- **VideoPlaybackCoordinator Section**: New comprehensive section
  - Immediate playback with 0.1s debounce
  - Survey phase (2 seconds)
  - Primary video selection algorithm
  - Sequential playback behavior
  - Integration with TweetTableViewController and SimpleVideoPlayer
- **Files Section**: Added VideoPlaybackCoordinator reference

### 3. VideoPlaybackAlgorithm.md

**Status:** ✅ Complete and up-to-date

**Key Updates:**
- **Overview**: Added note about new VideoPlaybackCoordinator system
- **Clarification**: Distinguished between MediaGridView sequential playback (this doc) and feed-level orchestration (NEW_VIDEO_ORCHESTRATION.md)
- **Cross-Reference**: Added link to NEW_VIDEO_ORCHESTRATION.md

---

## Key Documentation Improvements

### 1. Last Frame Capture System

Comprehensive documentation of the last frame capture mechanism:
- **Purpose**: Prevent black screens when videos finish or recover from background
- **Implementation**: AVPlayerItemVideoOutput, VideoLastFrameCache, capture algorithm
- **Use Cases**: Video finish, background recovery, seeking
- **Cache Management**: TTL, capacity, eviction policy

### 2. Video Orchestration Flow

Clear documentation of the complete playback flow:
- **Initial Load**: User scrolls → visibility detection → 0.1s debounce → survey phase
- **Survey Phase**: All videos play for 2s preview
- **Primary Selection**: Algorithm identifies most prominent video
- **Sequential Playback**: Automatic progression through visible videos
- **Last Frame Display**: Smooth finish without black screens

### 3. Notification System

Detailed documentation of video notification flow:
- **`.shouldPlayVideo`**: Coordinator → Player (with isSurvey/isPrimary flags)
- **`.shouldStopAllVideos`**: Stop all playback immediately
- **`.videoDidFinishPlaying`**: Player → Coordinator (triggers next video)

### 4. Troubleshooting Guide

Comprehensive troubleshooting section covering:
- Videos not starting when scrolled into view
- Videos restarting multiple times during scroll
- Primary video selection issues
- Sequential playback not working
- Black screen after video finishes
- Background recovery flicker

### 5. Performance Characteristics

Documented key performance aspects:
- 0.1s debounce prevents excessive start/stop cycles
- `.common` run loop mode ensures timer fires during scroll
- `DispatchQueue.main.async` prevents MainActor isolation issues
- Phase reset strategy for smooth transitions

---

## Technical Highlights

### 1. Debounce Implementation

```swift
let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
    DispatchQueue.main.async {
        guard let self = self else { return }
        if self.phase == .idle && !self.visibleVideos.isEmpty {
            self.startSurveyPhase()
        }
    }
}
RunLoop.main.add(timer, forMode: .common)
```

**Key Points:**
- `.common` mode allows firing during scroll
- `DispatchQueue.main.async` ensures MainActor isolation
- Only starts survey if phase is `.idle`

### 2. Last Frame Capture

```swift
func captureLastFrameNearEndIfPossible(reason: String) async {
    // Seek backwards to find non-black frame
    let captureTime = max(0, duration.seconds - 3.0)
    player.seek(to: CMTime(seconds: captureTime, preferredTimescale: 600))
    
    // Extract frame using AVPlayerItemVideoOutput
    let pixelBuffer = output.copyPixelBuffer(...)
    let image = UIImage(from: pixelBuffer)
    
    // Cache for reuse
    VideoLastFrameCache.shared.cacheFrame(image, for: videoMid)
}
```

**Benefits:**
- No black screens after video finishes
- Smooth background recovery
- Reusable cached frames

### 3. Sequential Playback

```swift
@objc private func handleVideoFinished(_ notification: Notification) {
    guard let videoMid = notification.userInfo?["videoMid"] as? String else { return }
    
    // Only handle if this is the primary video
    if phase == .primaryPlaying,
       let primaryId = primaryVideoId,
       primaryId.contains(videoMid) {
        playNextVisibleVideo()
    }
}
```

**Features:**
- Only primary video triggers next video
- Survey phase videos don't trigger progression
- Seamless transitions between videos

---

## Testing Status

All features documented have been tested and are working in production:

- ✅ Immediate playback with 0.1s debounce
- ✅ Survey phase with 2-second preview
- ✅ Primary video selection
- ✅ Sequential playback
- ✅ Last frame display on video finish
- ✅ Flicker-free background recovery
- ✅ Smooth scrolling with videos playing
- ✅ No multiple restarts during scroll

---

## Related Documentation

- **[NEW_VIDEO_ORCHESTRATION.md](NEW_VIDEO_ORCHESTRATION.md)** - Complete orchestration system guide
- **[VIDEO_SYSTEM.md](VIDEO_SYSTEM.md)** - Overall video architecture
- **[VideoPlaybackAlgorithm.md](VideoPlaybackAlgorithm.md)** - MediaGrid sequential playback
- **[COMPLETE_VIDEO_RESUME_SOLUTION.md](COMPLETE_VIDEO_RESUME_SOLUTION.md)** - Background recovery

---

## Future Improvements

Potential enhancements documented for future consideration:

1. **Adaptive Survey Duration**: Adjust 2s based on video length
2. **User Preferences**: Allow users to disable survey phase
3. **Machine Learning**: Learn which videos user prefers over time
4. **Picture-in-Picture**: Keep primary video playing in PiP during scroll
5. **Smart Selection**: Consider engagement metrics, watch time, author

---

## Maintenance Notes

### When to Update These Docs

Update documentation when:
- Timing constants change (debounce, survey duration)
- Algorithm changes (primary selection, phase transitions)
- New notifications added
- Cache behavior changes
- Performance optimizations made

### Documentation Structure

- **NEW_VIDEO_ORCHESTRATION.md**: Feed-level orchestration (VideoPlaybackCoordinator)
- **VIDEO_SYSTEM.md**: Overall architecture (SimpleVideoPlayer, caching, recovery)
- **VideoPlaybackAlgorithm.md**: MediaGrid sequential playback (VideoManager)

Keep these documents synchronized but focused on their specific domains.

---

## Conclusion

The video system documentation is now comprehensive, up-to-date, and accurately reflects the production implementation. All recent improvements (orchestration, sequential playback, last frame capture, background recovery) are fully documented with:

- Clear explanations of algorithms and flows
- Code examples and snippets
- Troubleshooting guides
- Testing checklists
- Performance characteristics
- Cross-references between related documents

**Documentation Status:** ✅ Complete and synchronized with codebase

