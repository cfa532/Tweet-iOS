# Swift 6 Migration — Architecture Review

Findings from a deep review of the Swift 6 strict-concurrency migration. Two root-cause
classes account for almost every symptom (freezes, crash, slow images, video UX).

---

## 1. The recurring architecture problem: `@MainActor` isolation + blocking calls

`User` (`Sources/DataModels/User.swift:12`) and `Tweet` (`Sources/DataModels/Tweet.swift:3`)
are `@MainActor`. **Any function that reads a `User`/`Tweet` property is itself
`@MainActor`-isolated** — the compiler infers it.

The non-obvious consequence: **`Task.detached { … }` does NOT move `@MainActor`-isolated
work off the main thread.** `Task.detached` detaches priority/inheritance only; the runtime
still hops *back* to the main actor to execute a `@MainActor` function body. So a
synchronous blocking call inside such a function blocks the **main thread**, freezing the UI.

Every freeze this session was this one pattern, with a different blocking primitive:

| Symptom | Blocking call | Site | Fix |
|---|---|---|---|
| Startup freeze | hprose `client.invoke` | `HproseInstance.getListByType/getFollowings/getFans` | route via `invokeRunMApp` (background `DispatchQueue.global` + continuation) |
| Login freeze | hprose `client.invoke` | `HproseInstance.login` | same |
| Every other RPC screen | hprose `client.invoke` | full sweep of `HproseInstance` direct invokes | same |
| `BlackList` `EXC_BREAKPOINT` | `UserDefaults.set` from a background `@Sendable` closure | `BlackList.saveToStorageLocked` | move encode+set onto `DispatchQueue.main.async` (empirically only main-thread writes are stable in this target) |

**Rule of thumb for this codebase:** blocking I/O (hprose invoke, disk reads, image decode,
CoreData `performAndWait`, and — quirks aside — `UserDefaults.set`) must be explicitly
pushed off the main actor. `@MainActor`-isolation makes the naive call site block main.

---

## 2. The reported bug: non-primary videos show no spinner / don't load

Analysis of the visibility → spinner → acquisition chain:

- `MediaGridUIView.mediaVisibilityIdentifiers` (`Sources/Tweet/UIKit/MediaGridUIView.swift:540`)
  sets `shouldAcquirePlayer = shouldWarmPlayer && infraReady`, where
  `shouldWarmPlayer = ratio >= FeedPlaybackTuning.videoWarmVisibilityRatio`.
- `videoWarmVisibilityRatio == 0` (`Sources/DataModels/Constants.swift:54`), so
  `shouldAcquirePlayer` is effectively **true for every visible cell**. So the warm
  threshold is *not* the gate.
- Player acquisition (`MediaCellUIView.schedulePlayerAcquireIfNeeded:1376`,
  `acquirePlayer:1420`) checks `isVisible` + `shouldAcquirePlayer` only — **not** primary.
- The non-primary spinner runs through `shouldShowVisibleVideoCoverSpinner`
  (`MediaCellUIView.swift:895`): `isVisible && isVideoAttachment && shouldAcquirePlayer && !hasCover`.

So a visible non-primary cell *should* acquire and show a spinner. The most likely real
causes, in order:

1. **Player-creation concurrency throttling.** `MAX_CONCURRENT_PLAYER_CREATIONS == 2` with
   one slot reserved for the primary (`SharedAssetCache`). Non-primary visible cells'
   acquisition is *queued*, so they never enter `.playerLoading`, so the spinner branch in
   `transitionTo` (`:688`) never fires. They only真正 start when one becomes primary.
2. **Cover/poster loading is on the slow main-actor image path** (see §3), so a cell with no
   cached cover sits blank — perceived as "media not loaded."
3. The spinner is only re-evaluated on `transitionTo`. A cell that becomes visible while
   already in `.thumbnail`/`.noContent` may not re-run the spinner decision.

**Recommended diagnosis (do NOT blind-fix; the state machine is intricate):** temporarily
log, for one visible non-primary cell, `isVisible/shouldAcquirePlayer/videoCellState` and
whether `schedulePlayerAcquireIfNeeded` reaches `acquirePlayerAsync` vs. is queued at
`SharedAssetCache.canStartCreation`. That pinpoints whether it's (1) throttling or (2) cover
loading.

Likely eventual fix: when a warm-visible cell is queued for a player slot, transition it to
`.playerLoading` and show the cover spinner (or the poster) immediately, rather than waiting
until a slot frees. And ensure cover/poster generation for warm-visible videos isn't
starved by the image main-actor bottleneck.

---

## 3. Slow images — root cause (your "avatars/images load slowly")

`Sources/Core/GlobalImageLoadManager.swift:68` is **`@MainActor final class`**. Its
`loadImage(request:)` (`:143`) is therefore main-actor-isolated and runs its whole body on
the main thread, per request, including:

- `BlackList.isBlacklisted`, memory-cache lookups via `cacheKeysQueue.sync` (a sync read
  against a queue that also services barrier writers),
- **`isMemoryPressureHigh()`** — two `task_info(…)` syscalls (`:1061-1110`) on main,
  **on every load attempt**,
- cache-eviction fan-out on main.

During scroll, dozens of cells fire `loadImage`/`cancelLoad` at once; everything serializes
on main behind the syscalls and barrier syncs. Decode on the feed path is already off-main
(`MediaCellUIView.swift:1085` uses `Task.detached`) — the bottleneck is the **dispatch
coordination on main**, not decode.

**Fix (medium effort, high value):** make `GlobalImageLoadManager` a non-`@MainActor`
`actor` (or push the `loadImage` body off main); only the `completion`/`@Published` updates
need `@MainActor`. Also: sample `isMemoryPressureHigh()` periodically (e.g. every 2–3 s) and
cache the result instead of calling it per request.

Secondary: avatars bypass `GlobalImageLoadManager` (`AvatarUIView.swift:194`,
`Avatar.swift:232`) and use `URLSession.shared`, which caps ~6 connections/host — if all
avatars resolve to one IPFS node, only 6 download in parallel.

---

## 4. Remaining main-thread-blocking sites (freeze/jank) — repo-wide

Same class as §1, blocking primitives other than hprose. Prioritized:

**Freeze-likely:**
- `LocalHTTPServer.swift:808` — `group.wait(timeout: .now() + 2.0)` in `start()`, called from
  `AppDelegate.didFinishLaunchingWithOptions` (main). Blocks launch up to 2 s. Use the
  existing `startAndWaitAsync()` (`:727`) instead.
- Main-thread image decode + `Data(contentsOf:)` via `ImageCacheManager.getCompressedImage`
  (the file itself warns at `:496-498`): `MediaBrowserView.swift:778,854`,
  `TweetDetailView.swift:615` (function is **not** async despite the comment),
  `ChatMessageView.swift:500`, `AvatarFullScreenView.swift:133-139`, `TweetUploadManager.swift:1528`,
  `DocumentPicker.swift:65`. Fix: wrap in `Task.detached(priority: .userInitiated)`, copy the
  `MediaCellUIView.swift:1085-1089` pattern.
- CoreData `performAndWait` from `@MainActor`: `TweetCacheManager.swift:612`
  (`deleteExpiredTweets` at startup — iterates+decodes every cached tweet on main),
  `:452` (`fetchTweetSync`, called per quoted tweet during scroll), `:74` (hourly timer),
  `:174,180,220` / `:744` (clear-cache settings), `ChatCacheManager.swift:345`. Convert to the
  `context.perform` + `withCheckedContinuation` pattern already used by their async siblings.

**Race (`@unchecked Sendable` with unsynchronized state):**
- `LocalHTTPServer.listener` — **fixed this session** (added `listenerLock`; was read/written
  from `queue`, `listenerQueue`, and Task hops → retain/release race under every video load).
- `MemoryCapManager.currentMemoryUsage` (`:25`) — written on main, read off-main; stale read
  can wrongly abort/permit an image download.
- `VideoConversionService.currentConversion/progressCallback` (`:31-32`) — cancel-during-start race.
- `TweetCacheManager.tweetAccessTimes` (`:25`) — no lock; latent today (callers happen to be
  main) but one background caller is a hard crash. Mirror `TweetHeightCache`'s `NSLock`.
- `CoreDataManager.cacheContext/cacheReadContext` (`:55,63`) — `lazy var` is non-atomic;
  eager-init in `init`.
- `HproseClient` reuse across threads (`HproseClientPool`) — thread-safety depends on the
  hprose library; worth confirming since invokes now run concurrently off-main.

**Dead code (delete so it can't be revived):** `AppDelegate.swift:963`
(`Thread.sleep` in unused `restartVideoInfrastructure`), `LocalHTTPServer.swift:716`
(`Thread.sleep` in deprecated `startAndWait`), `GlobalImageLoadManager.swift:932,941,946`
+ `loadImageOptimizedForDisplay` (`:1346`, zero callers — would decode on main if wired up).

---

## 5. Verified clean (so the sweep is known-complete)

No direct hprose `client.invoke` outside `HproseInstance`. No `DispatchQueue.main.sync`.
No `DispatchSemaphore`. No synchronous `URLSession`. No locks held across `await` (33
`NSLock`/`os_unfair_lock` sites all have short critical sections). Feed/scroll image decode
is correctly off-main. `BlackList`, `NodePool`, `NodeConnectionPool`, `ImageCacheManager`,
`TweetHeightCache` etc. are correctly protected.

---

## 6. Recommended fix order

1. **Slow images:** `GlobalImageLoadManager` `@MainActor` → `actor` + periodic memory sampling
   (§3). Biggest user-visible win; may also improve the video "media not loaded" perception.
2. **Video spinner bug:** diagnose per §2 (log one warm-visible non-primary cell), then fix
   the queued-cell spinner / cover path.
3. **Decode-site wraps** (§4) — mechanical, copy `MediaCellUIView:1085`.
4. **CoreData `performAndWait` → `context.perform`** sweep (§4).
5. **Launch:** use `startAndWaitAsync()` to remove the 2 s `group.wait` (§4).
6. **Remaining races:** `TweetCacheManager.tweetAccessTimes` lock; confirm `HproseClient`
   thread-safety; `MemoryCapManager`/`VideoConversionService` locks.
7. **Delete dead code** (§4).

---

*Generated as part of the Swift 6 migration review. The startup/login freezes, the
`BlackList` crash, and the `LocalHTTPServer.listener` race are already fixed; items above
remain.*
