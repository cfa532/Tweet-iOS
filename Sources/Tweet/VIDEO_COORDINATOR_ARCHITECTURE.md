# VideoPlaybackCoordinator Architecture Diagram

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    TWITTER FEED WITH VIDEOS                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌──────────────────────────────────────┐
        │    Tweet Type Detection              │
        │    (buildVideoList method)           │
        └──────────────────────────────────────┘
                              │
                ┌─────────────┴─────────────┐
                ▼                           ▼
    ┌───────────────────────┐   ┌───────────────────────┐
    │   COORDINATED         │   │   INDEPENDENT         │
    │   VIDEOS              │   │   VIDEOS              │
    │                       │   │                       │
    │ • Regular tweets      │   │ • Quoted embeds       │
    │ • Pure retweets       │   │ • Detail embeds       │
    │                       │   │                       │
    │ context: .regular     │   │ context: .quoted      │
    │ context: .retweet     │   │ context: .embedded    │
    │                       │   │                       │
    │ shouldCoordinate=true │   │ shouldCoordinate=false│
    └───────────┬───────────┘   └───────────┬───────────┘
                │                           │
                ▼                           ▼
    ┌───────────────────────┐   ┌───────────────────────┐
    │ VideoPlayback         │   │ MediaCell             │
    │ Coordinator           │   │ Visibility Logic      │
    │                       │   │                       │
    │ • Survey phase (2s)   │   │ • onAppear: play      │
    │ • Primary selection   │   │ • onDisappear: stop   │
    │ • Sequential play     │   │ • No coordination     │
    │                       │   │                       │
    │ Sends notifications:  │   │ Uses local state:     │
    │ .shouldPlayVideo      │   │ shouldAutoPlay        │
    │ .shouldPauseVideo     │   │                       │
    └───────────────────────┘   └───────────────────────┘
```

## Tweet Type Detection Flow

```
┌─────────────────────────────────────────────────────────────┐
│                         Tweet Analysis                       │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────┐
              │ Has originalTweetId?    │
              └─────────────────────────┘
                   │              │
              YES  │              │ NO
                   ▼              ▼
        ┌──────────────┐   ┌──────────────┐
        │ Has own      │   │ REGULAR      │
        │ attachments? │   │ TWEET        │
        └──────────────┘   │              │
           │        │      │ ✅ Coordinate│
      YES  │        │ NO   │    all videos│
           ▼        ▼      └──────────────┘
    ┌──────────┐  ┌──────────┐
    │ QUOTED   │  │ PURE     │
    │ TWEET    │  │ RETWEET  │
    │          │  │          │
    │ ✅ Main  │  │ ✅ Fetch │
    │    videos│  │    origin│
    │          │  │          │
    │ 🚫 Embed │  │ ✅ All   │
    │    videos│  │    videos│
    └──────────┘  └──────────┘
```

## Video Playback State Machine

```
┌──────────────────────────────────────────────────────────────┐
│                    COORDINATED VIDEOS ONLY                    │
└──────────────────────────────────────────────────────────────┘

    ┌────────────┐
    │   IDLE     │  ← Initial state, no videos playing
    └─────┬──────┘
          │
          │ Videos become visible
          │ (0.1s debounce)
          ▼
    ┌────────────┐
    │ SURVEYING  │  ← Play all visible videos for 2s
    └─────┬──────┘    • Send .shouldPlayVideo to each
          │           • Include isMuted state
          │           • Track in currentlyPlayingVideoIds
          │
          │ After 2s OR video finishes
          │ (endSurveyPhase)
          ▼
    ┌────────────┐
    │  PRIMARY   │  ← One video plays to completion
    │  PLAYING   │    • Pause all non-primary videos
    └─────┬──────┘    • Primary continues playing
          │           • Sequential playback enabled
          │
          │ Video finishes
          │ (handleVideoFinished)
          ▼
    ┌────────────┐
    │  PRIMARY   │  ← Advance to next visible video
    │  PLAYING   │    • playNextVisibleVideo()
    └─────┬──────┘    • Continue until no more videos
          │
          │ No more videos OR
          │ Videos scroll off-screen
          ▼
    ┌────────────┐
    │   IDLE     │
    └────────────┘
```

## Notification Flow

```
┌──────────────────────────────────────────────────────────────┐
│              VideoPlaybackCoordinator (Sender)                │
└──────────────────────────────────────────────────────────────┘
                            │
                            │ Posts notification
                            ▼
    ┌───────────────────────────────────────────────┐
    │        .shouldPlayVideo notification          │
    │                                               │
    │  userInfo: {                                  │
    │    "tweetId": String                          │
    │    "videoMid": String                         │
    │    "videoIndex": Int                          │
    │    "isSurvey": Bool (optional)                │
    │    "isPrimary": Bool (optional)               │
    │    "isMuted": Bool ✅ NEW                     │
    │  }                                            │
    └───────────────────────────────────────────────┘
                            │
                            │ Receives notification
                            ▼
    ┌───────────────────────────────────────────────┐
    │         SimpleVideoPlayer (Receiver)          │
    │                                               │
    │  1. Check if videoMid matches                 │
    │  2. Check if mode == "mediaCell"              │
    │  3. Apply isMuted from notification           │
    │  4. Start playback                            │
    └───────────────────────────────────────────────┘
```

## Mute State Propagation

```
┌──────────────────┐
│  MuteState       │  ← Global singleton
│  .shared         │     User toggles mute button
└────────┬─────────┘
         │
         │ Read at notification time
         ▼
┌──────────────────────────────────────────────────┐
│  VideoPlaybackCoordinator                        │
│                                                  │
│  playVideoForSurvey() {                          │
│    NotificationCenter.post(                      │
│      "isMuted": MuteState.shared.isMuted ✅     │
│    )                                             │
│  }                                               │
│                                                  │
│  endSurveyPhase() {                              │
│    NotificationCenter.post(                      │
│      "isMuted": MuteState.shared.isMuted ✅     │
│    )                                             │
│  }                                               │
└──────────────────────────────────────────────────┘
         │
         │ Notification sent with mute state
         ▼
┌──────────────────────────────────────────────────┐
│  SimpleVideoPlayer                               │
│                                                  │
│  .onReceive(.shouldPlayVideo) { notification in │
│    let isMuted = notification.userInfo["isMuted"]│
│    player.isMuted = isMuted ✅                   │
│    player.play()                                 │
│  }                                               │
└──────────────────────────────────────────────────┘
```

## Duplicate Command Prevention

```
BEFORE FIX (BROKEN):
───────────────────
videosSentPlayCommands = [video1, video2, video3]

User scrolls video2 off-screen:
  • stopVideo(video2)
  • currentlyPlayingVideoIds.remove(video2) ✅
  • videosSentPlayCommands still has video2 ❌

User scrolls video2 back on-screen:
  • Check: videosSentPlayCommands.contains(video2) = true
  • Skip sending play command ❌
  • Video never plays again ❌


AFTER FIX (WORKING):
────────────────────
videosSentPlayCommands = [video1, video2, video3]

User scrolls video2 off-screen:
  • pauseVideo(video2)
  • currentlyPlayingVideoIds.remove(video2) ✅
  • videosSentPlayCommands.remove(video2) ✅ NEW

User scrolls video2 back on-screen:
  • Check: videosSentPlayCommands.contains(video2) = false
  • Send play command ✅
  • Video plays correctly ✅
```

## Phase Transition Race Condition

```
BEFORE FIX (RACE CONDITION):
────────────────────────────
Thread A: endSurveyPhase() called
  1. Check: phase == .surveying ✅
  2. Pause non-primary videos...

Thread B: endSurveyPhase() called (from timer)
  1. Check: phase == .surveying ✅ (still true!)
  2. Pause non-primary videos... (duplicate!)

Thread A:
  3. phase = .primaryPlaying
  4. Send play command for primary

Thread B:
  3. phase = .primaryPlaying (overwrites)
  4. Send play command for primary (DUPLICATE!) ❌


AFTER FIX (ATOMIC):
───────────────────
Thread A: endSurveyPhase() called
  1. Check: phase == .surveying ✅
  2. phase = .primaryPlaying ✅ ATOMIC
  3. Pause non-primary videos...

Thread B: endSurveyPhase() called
  1. Check: phase == .surveying ❌ (now .primaryPlaying)
  2. return early ✅
  (No duplicate commands!)

Thread A:
  4. Send play command for primary ✅
```

## Infrastructure Readiness Flow

```
BEFORE FIX (POLLING):
────────────────────
.reloadVisibleVideosOnly notification received
  ▼
handleForegroundRecovery()
  ▼
Check: isVideoInfrastructureReady?
  │
  ├─ NO ──► Wait 500ms ──► Check again ──► Wait 500ms ──► ... ❌
  │                         (Infinite loop)
  │
  └─ YES ──► Process recovery


AFTER FIX (EVENT-DRIVEN):
─────────────────────────
.reloadVisibleVideosOnly notification received
  ▼
handleForegroundRecovery()
  ▼
Check: isVideoInfrastructureReady?
  │
  ├─ NO ──► Log message ──► Return ✅
  │         "Will auto-restart via notification"
  │
  └─ YES ──► Process recovery


(Separately, infrastructure restart completes)
  ▼
.VideoInfrastructureReadinessChanged (isReady: true)
  ▼
handleVideoInfrastructureChanged()
  ▼
Automatically start survey for visible videos ✅
```

## Complete Example: Quoted Tweet

```
┌────────────────────────────────────────────────────────────┐
│  User's Timeline                                           │
│                                                            │
│  ┌──────────────────────────────────────────────────┐     │
│  │ Regular Tweet                                    │     │
│  │ "Check out this video!"                          │     │
│  │ [Video 1] ◄── COORDINATED (.regular)             │     │
│  └──────────────────────────────────────────────────┘     │
│                                                            │
│  ┌──────────────────────────────────────────────────┐     │
│  │ Quoted Tweet                                     │     │
│  │ "Amazing content:"                               │     │
│  │ [Video 2] ◄── COORDINATED (.regular, main body)  │     │
│  │                                                  │     │
│  │  ┌────────────────────────────────────────┐     │     │
│  │  │ Quoted Tweet Embed                     │     │     │
│  │  │ "Original post"                        │     │     │
│  │  │ [Video 3] ◄── INDEPENDENT (.quoted)    │     │     │
│  │  │              NOT in allVideos[]        │     │     │
│  │  │              Uses visibility autoplay  │     │     │
│  │  └────────────────────────────────────────┘     │     │
│  └──────────────────────────────────────────────────┘     │
│                                                            │
│  ┌──────────────────────────────────────────────────┐     │
│  │ Pure Retweet                                     │     │
│  │ (No own content)                                 │     │
│  │ [Video 4] ◄── COORDINATED (.retweet)             │     │
│  │               From original tweet                │     │
│  └──────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────┘

buildVideoList() results:
─────────────────────────
allVideos = [
  VideoPlaybackInfo(tweetId: "t1", videoMid: "v1", context: .regular),
  VideoPlaybackInfo(tweetId: "t2", videoMid: "v2", context: .regular),
  // v3 NOT INCLUDED (filtered out, context would be .quoted)
  VideoPlaybackInfo(tweetId: "t4", videoMid: "v4", context: .retweet)
]

Playback behavior:
─────────────────
• Videos v1, v2, v4: Survey → Primary → Sequential (coordinated)
• Video v3: Plays when scrolled into view (independent)
• No conflicts between systems ✅
```

## Key Takeaways

1. **Two Systems, Zero Conflicts**
   - Coordinator only manages videos with `shouldCoordinate == true`
   - Embedded videos filtered out during `buildVideoList()`
   - Each system operates independently

2. **Mute State Consistency**
   - Global `MuteState.shared` is source of truth
   - Passed in every `.shouldPlayVideo` notification
   - Videos start with correct mute state immediately

3. **Proper State Cleanup**
   - `videosSentPlayCommands` cleared on pause
   - Videos can replay after scrolling off/on
   - No memory leaks from unbounded set growth

4. **Atomic Operations**
   - Phase transitions happen immediately
   - No race conditions between multiple calls
   - Predictable state machine behavior

5. **Event-Driven Architecture**
   - No polling for infrastructure readiness
   - Notification-based recovery
   - Efficient resource usage
