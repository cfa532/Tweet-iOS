# Background Media Release Design

## Goal

Keep a 10-second background grace period and the few visible poster images, while ensuring heavy image/video resources do not survive the delayed cleanup through view-local references.

## Root Cause

`AppDelegate` schedules `MemoryCapManager.performBackgroundMemoryRelease()` 10 seconds after `UIApplication.didEnterBackgroundNotification` and cancels it when the app returns sooner. The central cleanup clears `SharedAssetCache`, `VideoStateCache`, image caches, the local proxy, network sessions, and Core Data row caches.

Two ownership gaps remain:

1. `TweetTableViewController` receives the pre-cleanup notification synchronously on the main thread but defers visible-cell teardown into a new main-actor task. The central cleanup and background-task completion can therefore run before visible cells detach their players.
2. `SimpleVideoPlayer` can own an independent `AVPlayer`, `AVPlayerItemVideoOutput`, player item, observers, and setup/retry tasks outside the shared caches. It does not observe the delayed pre-cleanup notification, so embedded-detail players and decoded pixel-buffer output can remain retained.

## Design

Use the existing `.prepareVisibleVideosForBackground` notification as the synchronous boundary immediately before central media cleanup.

- The feed controller will prepare its visible cells synchronously because the notification is posted by the main-actor `AppDelegate` cleanup path. Existing visible video covers are retained, then player layers/items are detached before shared caches are cleared. The aggressive path does not capture, render, decode, or downscale a new bitmap immediately before suspension.
- Every live `SimpleVideoPlayer` will observe the same aggressive notification. It will cancel local setup/retry/recovery work, remove player observers and video outputs, detach its player item, and nil the local player reference.
- After infrastructure recovery, `.reloadVisibleVideosOnly` will recreate a released independent embedded-detail player only when its surface is still visible.
- `VideoLastFrameCache` behavior stays unchanged: `SharedAssetCache.releaseForBackground()` retains only visible/detail/fullscreen poster mids and clears the rest.
- Visible image cells keep their existing displayed cover images without allocating a new downscaled copy. Central decoded image caches and in-flight image requests are still cleared after 10 seconds.
- Disk media caches, playback metadata, and in-progress uploads/conversions remain intact.

## Lifecycle

1. The app enters background and starts its 10-second grace period.
2. Returning before 10 seconds cancels cleanup and preserves fast resume.
3. At 10 seconds (or earlier only if iOS expires the background task), `AppDelegate` posts the aggressive pre-cleanup notification.
4. View-owned players synchronously save resume metadata, retain their small posters, and release AVFoundation/output resources.
5. `MemoryCapManager` clears shared image/video/network/data caches and ends the background task.
6. Foreground recovery recreates only visible players and reloads released images from disk/network through existing paths.

## Reliability Constraints

- The 10-second delay is a grace period, not an iOS survival guarantee. Jetsam may terminate a high-memory process sooner.
- Cleanup must stay on the main actor when it reads or mutates view/player state.
- Poster retention must not retain an `AVPlayerItemVideoOutput`, player item, or player.
- No upload/editor-owned source media is cleared.

## Verification

- Static review will confirm the notification is handled synchronously and all view-local tasks, observers, outputs, item references, and player references are released.
- A compile-only simulator build will verify Swift actor isolation and API usage.
- Tests will not be run, per repository instructions.
