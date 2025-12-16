# Video Playback Algorithm

**Last Updated**: December 7, 2025  
**Status**: ✅ Production (Conservative Recovery + Fullscreen Resume)

## Overview

This document describes the algorithm for video playback in the Tweet-iOS app, specifically for sequential video playback within media grids and individual video player management. The algorithm handles video lifecycle, background/foreground transitions, fullscreen interactions, and automatic resume functionality.

## Core Components

### 1. VideoManager
- **Purpose**: Manages sequential video playback state across multiple videos
- **Type**: `ObservableObject` for SwiftUI state management
- **Key Properties**:
  - `videoMids: [String]` - Array of video media IDs in sequence
  - `currentVideoIndex: Int` - Index of currently playing video
  - `isSequentialPlaybackEnabled: Bool` - Whether sequential playback is active

### 2. MediaGridView
- **Purpose**: Orchestrates video playback for a collection of media attachments
- **Responsibilities**:
  - Setup and teardown of sequential playback
  - Reset video states when grid becomes visible
  - Force refresh MediaCell components when needed

### 3. MediaCell
- **Purpose**: Individual media item container that interfaces with SimpleVideoPlayer
- **Key Features**:
  - Responds to VideoManager state changes
  - Handles visibility detection
  - Manages force refresh triggers from MediaGridView

### 4. SimpleVideoPlayer
- **Purpose**: Core video player component with autoplay logic
- **Key Features**:
  - KVO-based player status monitoring
  - Automatic playback when player becomes ready
  - Shared video player instances via SharedAssetCache

## Algorithm Flow

### 1. MediaGrid Initialization

```
MediaGridView.onAppear:
1. Set isVisible = true
2. Extract video MIDs from attachments
3. Stop any existing sequential playback
4. If multiple videos:
   - Setup sequential playback with videoMids
   - Reset all video players to beginning
   - Set isSequentialPlaybackEnabled = true
5. If single video:
   - Setup video MID but disable sequential playback
   - Reset single video player
   - Force refresh MediaCell (forceRefreshTrigger += 1)
```

### 2. Video Player State Determination

```
VideoManager.shouldPlayVideo(for mid):
1. Check if sequential playback is enabled
2. If enabled:
   - Return true if mid matches current video in sequence
   - Return false otherwise
3. If disabled (single video):
   - Return true if mid exists in videoMids
4. Return false if video not in managed set
```

### 3. MediaCell State Management

```
MediaCell.onAppear:
1. Set isVisible = true immediately
2. If attachment is video:
   - Set shouldLoadVideo = true
   - Update play state based on VideoManager.shouldPlayVideo()

MediaCell.onChange(forceRefreshTrigger):
1. Get new play state from VideoManager
2. Update local play state if different
3. Trigger SimpleVideoPlayer refresh
```

### 4. Video Player Autoplay Logic

```
SimpleVideoPlayer Initialization:
1. Create player using SharedAssetCache (shared instances)
2. Setup KVO observer for player item status
3. If player already ready:
   - Check VideoManager approval (for MediaCell)
   - Start playback immediately if autoPlay = true AND approved
4. If player not ready:
   - Wait for KVO status change to .readyToPlay

SimpleVideoPlayer KVO Callback:
1. When status becomes .readyToPlay:
   - Set isLoading = false
   - Update duration
   - For MediaCell: Check VideoManager.shouldPlayVideo(for: mid)
   - If autoPlay = true AND approved (if MediaCell) AND not already playing:
     - Start playback (player.play())
     - Set playbackState = .playing

Buffer Data Observer:
1. When sufficient data buffered (hasEnoughData):
   - For MediaCell: Check VideoManager approval
   - If approved: Show first frame and auto-play
   - If not approved: Show first frame but wait for approval
```

**VideoManager Approval Checks:**
- All auto-play entry points check `videoManager?.shouldPlayVideo(for: mid)` for MediaCell mode
- Prevents multiple videos from playing simultaneously
- Ensures only the current video in sequential playback plays
- Defaults to `false` if VideoManager is not ready (prevents unintended playback)

### 5. Sequential Playback Progression

```
SimpleVideoPlayer.onVideoFinished:
1. Mark video as finished
2. Reset video state (position, flags)
3. Call VideoManager.onVideoFinished()

VideoManager.onVideoFinished:
1. Calculate next video index
2. If more videos exist:
   - Increment currentVideoIndex
   - This triggers MediaCell state updates via @Published
3. If all videos finished:
   - Clear state (videoMids = [], currentVideoIndex = -1)
   - Disable sequential playback
```

### 6. State Synchronization

```
MediaCell observes VideoManager.currentVideoIndex:
1. When currentVideoIndex changes:
   - Calculate new play state for this cell's video
   - Update local play state if different
   - SimpleVideoPlayer receives new autoPlay parameter
   - Autoplay logic executes if conditions met
```

## Key Design Principles

### 1. Shared Video Player Instances
- SharedAssetCache provides shared AVPlayer instances
- Same video uses same player across MediaCell and MediaBrowserView
- Enables seamless transition between contexts

### 2. Declarative State Management
- VideoManager publishes state changes
- MediaCell observes and reacts to state
- SimpleVideoPlayer responds to autoPlay parameter changes

### 3. Race Condition Prevention
- KVO monitoring ensures playback starts when player is ready
- Force refresh triggers handle timing issues during initialization
- Immediate visibility setting in onAppear prevents state mismatches
- VideoManager approval checks prevent race conditions where multiple videos try to play
- Duplicate completion handler guards prevent multiple finish events

### 4. Clean Separation of Concerns
- VideoManager: Sequential playback logic
- MediaGridView: Grid-level orchestration
- MediaCell: Individual cell state management
- SimpleVideoPlayer: Core playback functionality

### 5. No Cross-Player Interference
- Removed pauseAllOtherVideos logic
- Each player manages its own state independently
- Sequential behavior achieved through state coordination, not direct control

## Edge Cases Handled

### 1. Grid Reappearance
- MediaGridView.onAppear always resets to first video
- All video players reset to beginning position
- Force refresh ensures MediaCells update their play state

### 2. App Background/Foreground
- **State Caching**: Player state (position, playing status) cached before backgrounding
- **Conservative Recovery**: Only recreates players that are actually broken (missing, failed status, stalled)
- **Resume Logic**: Videos that were playing before backgrounding automatically resume when returning to foreground
- **VideoManager Integration**: For MediaCell videos, checks VideoManager approval before resuming
- **Player Validation**: Validates player is ready before resuming playback
- **KVO observers properly cleaned up on disappear**
- **Video layer restoration on app becoming active**
- **Black screen prevention through layer refresh**

**Recovery Flow:**
```
App goes to background:
1. cachePlayerStateForBackground() saves player state (time, wasPlaying)
2. Player paused but kept attached

App returns to foreground:
1. recoverFromBackground() called
2. Check if player is broken (isPlayerBroken())
3. If broken: Recreate player, restore position, resume if wasPlaying
4. If healthy: Reattach player, restore position, resume if wasPlaying
5. For MediaCell: Check VideoManager approval before resuming
6. Wait for ready state if player not ready yet
```

### 2a. Fullscreen Resume
- **State Preservation**: Videos paused when entering fullscreen preserve their playing state
- **Resume After Exit**: Videos that were playing before fullscreen automatically resume when exiting
- **VideoManager State**: MediaGridView re-establishes VideoManager state when returning from fullscreen
- **No State Clearing**: MediaGridView no longer clears VideoManager state when fullscreen opens

**Fullscreen Flow:**
```
Enter fullscreen:
1. MediaBrowserView posts .stopAllVideos notification
2. SimpleVideoPlayer.handleStopAllVideos() pauses player
3. playbackState kept as .playing (not changed to .paused)
4. MediaGridView does NOT clear VideoManager state

Exit fullscreen:
1. MediaBrowserView posts .resumeMediaCellVideos notification
2. MediaGridView.onReceive(.resumeMediaCellVideos) re-establishes VideoManager state
3. SimpleVideoPlayer.handleResumeMediaCellVideos() checks:
   - playbackState == .playing (was playing before)
   - VideoManager approval (for MediaCell)
   - isVisible
4. If all conditions met: player.play() and resume
```

### 3. Single vs Multiple Videos
- Different logic paths for single video (no sequential) vs multiple videos
- Single videos still use VideoManager for consistent interface

### 4. Player Readiness Timing
- KVO observer handles asynchronous player preparation
- Autoplay works regardless of when player becomes ready
- No dependency on view lifecycle timing

## Performance Considerations

### 1. Video Player Reuse
- SharedAssetCache maintains player instances
- Avoids repeated player creation/destruction
- Faster playback start times
- Conservative recreation: Only recreates broken players, not all players after backgrounding

### 2. Efficient State Updates
- @Published properties for automatic UI updates
- Minimal state synchronization overhead
- Batched updates through force refresh triggers
- Early exits in onAppear to prevent duplicate setup

### 3. Memory Management
- Proper KVO observer cleanup
- Shared player instances reduce memory usage
- Background video state preservation
- VideoStateCache with expiration (10 minutes)

### 4. Recovery Efficiency
- Only broken players are recreated (not all players)
- Healthy players are simply reattached and resumed
- Reduces unnecessary work and potential issues
- Validates player state before resuming

## Debugging Information

The algorithm provides extensive debug logging at key points:
- VideoManager state changes
- MediaGridView setup/reset operations
- MediaCell state transitions
- SimpleVideoPlayer status changes
- KVO player readiness notifications

Log format: `DEBUG: [COMPONENT] Message with relevant state information`

## Recent Improvements (December 2025)

### 1. Conservative Player Recreation
- **Before**: Aggressively recreated all players after backgrounding
- **After**: Only recreates players that are actually broken (missing, failed status, stalled)
- **Benefit**: Leaves healthy players alone, reducing unnecessary work and potential issues

### 2. Fullscreen Resume Support
- **Before**: Videos paused when entering fullscreen didn't resume after exit
- **After**: Videos that were playing before fullscreen automatically resume when exiting
- **Implementation**: `playbackState` preserved, VideoManager state re-established, resume checks approval

### 3. Enhanced VideoManager Integration
- **Before**: Some auto-play paths didn't check VideoManager approval
- **After**: All auto-play entry points check VideoManager approval for MediaCell
- **Benefit**: Prevents multiple videos from playing simultaneously

### 4. Improved Background Recovery
- **Before**: Recovery logic was complex with multiple paths
- **After**: Simplified to single path: check if broken, recreate if needed, otherwise reattach and resume
- **Benefit**: More reliable recovery, better logging, handles edge cases

### 5. Duplicate Event Prevention
- **Before**: Video completion handlers could fire multiple times
- **After**: Guards prevent duplicate completion events
- **Benefit**: Prevents state corruption and flickering

## Future Considerations

### 1. Extensibility
- Algorithm supports different sequential playback strategies
- Easy to add pause/resume functionality
- Can be extended for playlist-like behavior

### 2. Performance Optimization
- Potential for video preloading
- Smart cache management
- Progressive loading strategies

### 3. User Experience
- Smooth transitions between videos
- Consistent playback behavior
- Predictable state management
- Automatic resume after backgrounding/fullscreen
