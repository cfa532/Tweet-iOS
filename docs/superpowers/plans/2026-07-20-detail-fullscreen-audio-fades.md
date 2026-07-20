# Detail and Fullscreen Video Audio Fades Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. This repository does not permit subagent dispatch for this task.

**Goal:** Fade detail and fullscreen video audio in over 0.5 seconds and out over 0.35 seconds without changing playback controls or leaking zero volume into a borrowed feed player.

**Architecture:** Add one file-private, main-actor volume-ramp helper in `SingletonVideoManagers.swift`, owned independently by the fullscreen and detail managers. Each manager consumes a pending entry fade at its centralized playback-start method and delays final exit cleanup until its fade-out completion. View lifecycle gates are released from the deactivation completion so underlying feed playback remains suppressed during the fade.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation/AVKit, structured concurrency.

## Global Constraints

- Entry ramps last exactly 0.5 seconds; exit ramps last exactly 0.35 seconds.
- Detail and fullscreen players stay unmuted while active; a borrowed detail player receives the current global mute preference before returning to the feed.
- User pause/resume does not replay the entry fade.
- Restore volume to 1 before pausing, clearing, or handing off a player.
- Do not change native playback controls, seeking, buffering recovery, or feed mute preference.
- Do not run tests unless the user explicitly requests them; use static review and a simulator build.

---

### Task 1: Cancellable Player Volume Ramp

**Files:**
- Modify: `Sources/Core/SingletonVideoManagers.swift`

**Interfaces:**
- Produce: file-private `PlayerVolumeRamp` with `fade(player:from:to:duration:completion:)` and `cancel(restoring:)` methods.
- Consume: `AVPlayer.volume`, `AVPlayer.isMuted`, and a main-actor `Task` using short sleep intervals.

- [ ] Add a file-private `@MainActor` helper that cancels superseded work, linearly interpolates from the current or supplied starting volume, retains the target player for the ramp, and only calls completion for the current uncancelled generation.
- [ ] Ensure zero-duration ramps complete synchronously.
- [ ] Ensure cancellation can restore the affected player to volume 1 without changing `isMuted` to true.
- [ ] Run `git diff --check` and inspect the helper for task-retention or stale-completion paths.

### Task 2: Fullscreen Entry and Exit

**Files:**
- Modify: `Sources/Core/SingletonVideoManagers.swift`
- Modify: `Sources/Features/MediaViews/MediaBrowserView.swift`

**Interfaces:**
- Replace: `setStartupAudioMuteWindow(duration:)` with `prepareStartupAudioFade(duration:)`.
- Extend: `deactivate(transferPlaybackToUnderlyingSurface:audioFadeDuration:completion:)`.
- Consume: the centralized `startFullscreenPlayback(player:item:log:)` method.

- [ ] Replace the hard-mute startup deadline/task with a pending fade duration and a fullscreen-owned `PlayerVolumeRamp`.
- [ ] In `startFullscreenPlayback`, set the player unmuted, start playback, and consume the pending entry fade exactly once from volume 0 to 1.
- [ ] Split fullscreen deactivation into immediate observer/recovery cancellation and final player cleanup. Fade a playing player to zero before the final pause/handoff; restore volume to 1 immediately before cleanup.
- [ ] Cancel stale exit work during a new fullscreen activation.
- [ ] In `MediaBrowserView`, request a 0.5-second entry fade and keep the overlay ownership gate until the asynchronous deactivation completion.

### Task 3: Detail Entry and Exit

**Files:**
- Modify: `Sources/Core/SingletonVideoManagers.swift`
- Modify: `Sources/Tweet/TweetDetailView.swift`
- Modify: `Sources/Tweet/CommentDetailView.swift`

**Interfaces:**
- Replace: `setStartupAudioMuteWindow(duration:)` with `prepareStartupAudioFade(duration:)`.
- Extend: `deactivate(audioFadeDuration:completion:)`.
- Consume: the centralized `startDetailPlayback(player:item:log:)` method.

- [ ] Replace the detail hard-mute startup deadline/task with a pending fade duration and a detail-owned `PlayerVolumeRamp`.
- [ ] Remove the borrowed-player bypass that forces volume 1 before initial playback; consume the pending entry fade in `startDetailPlayback` after `play()`.
- [ ] On final detail deactivation, keep the player owned until fade-out completes, then restore volume 1, apply the current global mute preference, and call `clearCurrentVideo(preserveSharedFeedPlayback: true)`.
- [ ] Cancel a stale detail fade when activation, player clearing, or replacement supersedes it.
- [ ] Request the 0.5-second entry fade in both tweet and comment detail views. Release `NavigationStateManager` detail ownership only from final deactivation completion.

### Task 4: Static Review and Build

**Files:**
- Review all files modified above.

- [ ] Search for the removed startup-mute API and fields; expect no references.
- [ ] Search all detail/fullscreen exit paths and confirm they converge on the fade-aware deactivation.
- [ ] Confirm every fade-out completion restores volume 1 before feed handoff or player release, and detail handoff applies the current global mute preference.
- [ ] Run `git diff --check`.
- [ ] Build the Debug iOS Simulator target with code signing disabled; expect exit status 0.
- [ ] Do not modify or stage `Tweet.xcworkspace/xcuserdata/cfa532.xcuserdatad/UserInterfaceState.xcuserstate`.
