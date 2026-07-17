# Background Media Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release view-local AVFoundation resources during the delayed background cleanup while retaining visible posters and a 10-second grace period.

**Architecture:** Reuse the existing main-actor `.prepareVisibleVideosForBackground` notification as a synchronous pre-cleanup boundary. Feed UIKit cells and SwiftUI video players detach local heavy resources before `MemoryCapManager` clears shared caches.

**Tech Stack:** Swift 6, UIKit, SwiftUI, AVFoundation, NotificationCenter

## Global Constraints

- Keep the background grace period at exactly 10 seconds.
- Keep only visible/detail/fullscreen poster images after cleanup.
- Reuse existing posters during aggressive cleanup; do not allocate new decoded images in the release path.
- Preserve disk caches, playback metadata, and upload/editor source media.
- Do not run tests.

---

### Task 1: Synchronous feed media preparation

**Files:**
- Modify: `Sources/Core/NotificationNames.swift`
- Modify: `Sources/Tweet/UIKit/TweetTableViewController.swift`

**Interfaces:**
- Consumes: `.prepareVisibleVideosForBackground` posted from the main-actor `AppDelegate` cleanup path.
- Produces: synchronous `prepareVisibleVideosForBackground(reason:aggressive:)` completion before global cache release.

- [x] **Step 1: Document the notification's main-actor synchronous contract**

Update the notification comment to state that aggressive observers must release view-owned media synchronously before the post returns.

- [x] **Step 2: Remove the deferred task hop**

Replace the observer's `Task { @MainActor ... }` with `MainActor.assumeIsolated` under the notification's main-thread-by-contract guarantee.

- [x] **Step 3: Inspect the finished observer**

Confirm it ignores non-aggressive notifications and calls cell preparation before returning.

### Task 2: Release SwiftUI view-local video resources

**Files:**
- Modify: `Sources/Features/MediaViews/SimpleVideoPlayer.swift`

**Interfaces:**
- Consumes: `.prepareVisibleVideosForBackground` with `userInfo["aggressive"] == true`.
- Produces: `handlePrepareForBackground(_:)`, which leaves poster/resume metadata intact and releases local tasks, observers, `AVPlayerItemVideoOutput`, item, and player references.

- [x] **Step 1: Observe the delayed cleanup notification**

Add an `.onReceive` entry beside the existing application lifecycle notifications.

- [x] **Step 2: Add the focused release handler**

The handler must:

```swift
guard notification.userInfo?["aggressive"] as? Bool == true else { return }
setupPlayerTask?.cancel()
retryTask?.cancel()
waitingForPlayerTask?.cancel()
recoveryCoverTask?.cancel()
recoveryTimeoutTask?.cancel()
timeRemainingDisplayTask?.cancel()
removePlayerObservers()
if let item = videoOutputAttachedItem, let output = videoOutput {
    item.remove(output)
}
videoOutput = nil
videoOutputAttachedItem = nil
player?.currentItem?.asset.cancelLoading()
player?.pause()
player?.replaceCurrentItem(with: nil)
player = nil
```

It must also reset transient loading/playback flags so existing foreground recovery recreates the player, without clearing `VideoLastFrameCache`.

- [x] **Step 3: Review all local ownership**

Confirm no player setup/retry task, player observer, time observer, video output, item, or player remains reachable through `SimpleVideoPlayer` after the handler.

- [x] **Step 4: Preserve foreground recovery for independent players**

Extend `handleReloadVisibleVideosOnly()` so a visible non-feed `SimpleVideoPlayer` whose local player was released recreates it only after AppDelegate marks video infrastructure ready.

### Task 3: Static and compile verification

**Files:**
- Review: all modified files

**Interfaces:**
- Consumes: completed Tasks 1-2.
- Produces: evidence that the code is scoped, actor-safe, and compilable.

- [x] **Step 1: Inspect the diff**

Run: `git diff --check && git diff -- Sources/Core/NotificationNames.swift Sources/Tweet/UIKit/TweetTableViewController.swift Sources/Features/MediaViews/SimpleVideoPlayer.swift`

Expected: no whitespace errors; only the synchronous notification handling and view-local cleanup are changed.

- [x] **Step 2: Verify lifecycle constants and poster behavior**

Run: `rg -n "shortBackgroundVideoGracePeriod|keepOnly\(|prepareVisibleVideosForBackground|handlePrepareForBackground" Sources/App/AppDelegate.swift Sources/Core/SharedAssetCache.swift Sources/Core/NotificationNames.swift Sources/Tweet/UIKit/TweetTableViewController.swift Sources/Features/MediaViews/SimpleVideoPlayer.swift`

Expected: the grace period is `10`; visible poster filtering remains; both feed and SwiftUI players handle the delayed cleanup.

- [x] **Step 3: Compile without tests**

Run: `xcodebuild -project Tweet.xcodeproj -scheme Tweet -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`. Do not run any test action.
