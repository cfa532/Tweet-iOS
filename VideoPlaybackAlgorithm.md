# Video Playback Algorithm

## Overview

This document describes the algorithm for video playback in the Tweet-iOS app, specifically for sequential video playback within media grids and individual video player management.

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
  - Shared video player instances via VideoCacheManager

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
1. Create player using VideoCacheManager (shared instances)
2. Setup KVO observer for player item status
3. If player already ready:
   - Start playback immediately if autoPlay = true
4. If player not ready:
   - Wait for KVO status change to .readyToPlay

SimpleVideoPlayer KVO Callback:
1. When status becomes .readyToPlay:
   - Set isLoading = false
   - Update duration
   - If autoPlay = true and not already playing:
     - Start playback (player.play())
     - Set isPlaying = true
```

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
- VideoCacheManager provides shared AVPlayer instances
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
- KVO observers properly cleaned up on disappear
- Video layer restoration on app becoming active
- Black screen prevention through layer refresh

### 3. Single vs Multiple Videos
- Different logic paths for single video (no sequential) vs multiple videos
- Single videos still use VideoManager for consistent interface

### 4. Player Readiness Timing
- KVO observer handles asynchronous player preparation
- Autoplay works regardless of when player becomes ready
- No dependency on view lifecycle timing

## Performance Considerations

### 1. Video Player Reuse
- VideoCacheManager maintains player instances
- Avoids repeated player creation/destruction
- Faster playback start times

### 2. Efficient State Updates
- @Published properties for automatic UI updates
- Minimal state synchronization overhead
- Batched updates through force refresh triggers

### 3. Memory Management
- Proper KVO observer cleanup
- Shared player instances reduce memory usage
- Background video state preservation

## Debugging Information

The algorithm provides extensive debug logging at key points:
- VideoManager state changes
- MediaGridView setup/reset operations
- MediaCell state transitions
- SimpleVideoPlayer status changes
- KVO player readiness notifications

Log format: `DEBUG: [COMPONENT] Message with relevant state information`

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
