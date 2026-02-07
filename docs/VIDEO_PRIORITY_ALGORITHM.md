# Video Priority Algorithm

**Last Updated**: January 7, 2026  
**Status**: ✅ Implemented

## Overview

This document describes the video playback priority algorithm used in the Tweet-iOS app when multiple videos are visible on screen simultaneously in the feed.

## Priority System

When multiple videos are visible in the feed, the system determines which video should be the "primary" video (the one that plays to completion) using the following priority rules:

### Priority Levels

1. **HIGHEST PRIORITY: Full Visibility**
   - Only videos that are at least 95% visible in the viewport are considered for primary selection
   - This ensures the user has a complete, unobstructed view of the primary video

2. **SECONDARY PRIORITY: Topmost Position**
   - Among fully visible videos, the video that appears highest on the screen (lowest Y coordinate) becomes primary
   - This matches natural reading patterns and user expectations

3. **TIEBREAKER: Feed Order (Timestamp)**
   - If two videos are at nearly the same Y position (within 5 points), the video that appears earlier in the feed (lower index) takes priority
   - This ensures consistent behavior and prevents flickering between videos at similar positions

4. **FALLBACK: Partial Visibility**
   - If no fully visible videos exist, the system falls back to partially visible videos
   - Prefers videos with higher visibility ratio (more of the video is visible)
   - Among videos with similar visibility, prefers topmost position

## Implementation

The algorithm is implemented in `VideoPlaybackCoordinator.swift` in the `identifyPrimaryVideo()` method.

### Code Location

```swift
// Sources/Core/VideoPlaybackCoordinator.swift
private func identifyPrimaryVideo() -> VideoPlaybackInfo?
```

### Algorithm Flow

```
1. Get all visible videos from the feed
2. For each video:
   - Calculate its position in viewport (Y coordinate)
   - Calculate visibility ratio (% of video visible)
   
3. Categorize videos:
   - Fully visible: visibility >= 95%
   - Partially visible: visibility > 30%
   - Hidden: visibility <= 30%

4. If fully visible videos exist:
   - Sort by Y position (ascending)
   - Use feed index as tiebreaker for similar Y positions
   - Select topmost video
   
5. Else if partially visible videos exist:
   - Sort by visibility ratio (descending)
   - Use Y position as tiebreaker for similar visibility
   - Select most visible video
   
6. Else:
   - Fallback to first video in feed order
```

## Video Playback Phases

The video playback coordinator operates in three phases:

1. **Survey Phase (2 seconds)**
   - All visible videos play simultaneously for 2 seconds
   - Gives user a preview of available content
   - Helps identify which videos have audio/content

2. **Primary Selection**
   - After survey phase, identify primary video using priority algorithm
   - Pause all non-primary videos
   - Keep primary video playing to completion

3. **Sequential Playback**
   - When primary video finishes, move to next visible video in feed order
   - Continue until no more visible videos

## Different Systems

The app uses different video management systems for different contexts:

### Feed-Level Coordination
- **Component**: `VideoPlaybackCoordinator` (singleton)
- **Purpose**: Coordinates video playback across multiple tweets in feed
- **Uses**: Priority algorithm described in this document
- **Scope**: Home feed, profile view, search results

### Within-Tweet Sequential Playback
- **Component**: `VideoManager` (per-MediaGrid instance)
- **Purpose**: Sequential playback of multiple videos within a single tweet
- **Algorithm**: Simple sequential order (1st video → 2nd video → etc.)
- **Scope**: Individual tweets with multiple video attachments

### Fullscreen Video
- **Component**: `FullScreenVideoManager`
- **Purpose**: Manages video playback in fullscreen mode
- **Algorithm**: User-controlled navigation
- **Scope**: Fullscreen media browser

## Benefits

This priority system provides several benefits:

1. **Predictable Behavior**: Users can predict which video will play based on screen position
2. **Natural UX**: Follows natural reading patterns (top to bottom)
3. **Stability**: Prevents flickering or switching between videos during small scrolls
4. **Accessibility**: Ensures primary video is fully visible and accessible
5. **Performance**: Only one primary video plays to completion, reducing battery/bandwidth usage

## Example Scenarios

### Scenario 1: Three Fully Visible Videos
```
Screen Layout:
┌─────────────┐
│ Video A (Y=100) ← PRIMARY (topmost, fully visible)
├─────────────┤
│ Video B (Y=400)
├─────────────┤
│ Video C (Y=700)
└─────────────┘

Result: Video A becomes primary
```

### Scenario 2: Two Partially Visible Videos
```
Screen Layout:
┌─────────────┐
│ Video A (50% visible, Y=0)
├─────────────┤
│ Video B (80% visible, Y=200) ← PRIMARY (more visible)
└─────────────┘

Result: Video B becomes primary (higher visibility ratio)
```

### Scenario 3: Videos at Same Position
```
Screen Layout:
┌─────────────┐
│ Video A (Y=100, index=5)
│ Video B (Y=102, index=8) ← Within 5pt threshold
└─────────────┘

Result: Video A becomes primary (earlier in feed)
```

## Testing Recommendations

When testing video priority:

1. Test with multiple videos on screen at different positions
2. Test scrolling slowly to verify primary doesn't flicker
3. Test with partially visible videos at screen edges
4. Test with videos at similar Y positions (tiebreaker logic)
5. Test with pinned tweets (should have higher priority due to position)

## Future Enhancements

Potential improvements to consider:

1. **User Preferences**: Allow users to disable auto-play or change priority rules
2. **Engagement Metrics**: Factor in view time, likes, or engagement when selecting primary
3. **Content Type**: Prioritize videos with audio or specific content types
4. **Accessibility**: Enhanced support for VoiceOver and screen readers

