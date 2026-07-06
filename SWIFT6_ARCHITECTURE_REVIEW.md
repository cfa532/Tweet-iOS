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
- ~~`LocalHTTPServer` `group.wait(timeout: .now() + 2.0)` in `start()`, called from
  `AppDelegate.didFinishLaunchingWithOptions` (main). Blocks launch up to 2 s.~~
  **FIXED (Jul 2026):** launch now fires `startAndWaitAsync()` in a `Task`; the blocking
  `start()` and deprecated `startAndWait()` were deleted. Player creation is protected by
  `ensureReadyForPlaybackAsync()` if it wins the startup race.
- Main-thread image decode + `Data(contentsOf:)` via `ImageCacheManager.getCompressedImage`
  (the file itself warns at `:496-498`): `MediaBrowserView.swift:778,854`,
  `TweetDetailView.swift:615` (function is **not** async despite the comment),
  `ChatMessageView.swift:500`, `AvatarFullScreenView.swift:133-139`, `TweetUploadManager.swift:1528`,
  `DocumentPicker.swift:65`. Fix: wrap in `Task.detached(priority: .userInitiated)`, copy the
  `MediaCellUIView.swift:1085-1089` pattern.
- CoreData `performAndWait` from `@MainActor` — **mostly fixed (Jul 2026)**:
  `deleteExpiredTweets` (fire-and-forget `perform`), hourly `performPeriodicCleanup`
  (`perform`), `manualClearAllCache` + `ChatCacheManager.clearAllCache` (now `async` with
  `await context.perform`; dead `clearCacheOnSignout` deleted), `SharedAssetCache.
  findAuthorIdForVideo` (uses async `fetchTweet`). **Kept deliberately synchronous:**
  `fetchTweetSync` in `TweetItemView.onAppear` (retweet layout needs the original tweet
  before first layout pass — async would reintroduce height jumps) and
  `SingletonVideoManagers.resolveNextVideo` (video-end path, in-memory hit in practice).
  `ChatCacheManager`'s remaining ~10 `performAndWait` message read/write paths are still
  sync — convert opportunistically if chat jank is ever reported.

**Race (`@unchecked Sendable` with unsynchronized state) — ALL FIXED as of Jul 2026:**
- `LocalHTTPServer.listener` — fixed (added `listenerLock`; was read/written
  from `queue`, `listenerQueue`, and Task hops → retain/release race under every video load).
- `MemoryCapManager.currentMemoryUsage` — fixed (`memoryUsageLock`).
- `VideoConversionService.currentConversion/progressCallback` — fixed (`conversionStateLock`).
- `TweetCacheManager.tweetAccessTimes` — fixed (`accessTimesLock` + locked helpers).
- `CoreDataManager.cacheContext/cacheReadContext` — fixed (`contextLock` +
  `lockedBackgroundContext`).
- `HproseClient` reuse across threads (`HproseClientPool`) — **RESOLVED (Jul 2026)**, and
  the investigation found a worse bug: the pool's checkout model never released clients
  (`releaseClient` had zero callers), so every RPC created a fresh `HproseHttpClient` whose
  `NSURLSession` (whose delegate strongly retains the client — a retain cycle) was never
  invalidated → **one leaked session + client per RPC call**. Redesigned: the pool now hands
  out ONE shared client per (endpoint URL, timeout) pair, configured once at creation and
  never mutated after (timeout is part of the pool key; `User.writableClient(timeout:)` for
  the 30s/240s classes). Concurrent invokes on a shared client are safe: hprose keeps
  per-call state in context/settings objects, NSURLSession is thread-safe, and the only
  shared mutation (failover URI rotation) is `@synchronized` and unused in our single-URI
  setup. `clear()`/`clear(for:)` now actually `close()` sessions. `HproseClient` is declared
  `@unchecked @retroactive Sendable` on this basis — **do not set properties on a client
  returned by the pool**.

**Dead code:** ~~`AppDelegate` `Thread.sleep` in unused `restartVideoInfrastructure`;
`LocalHTTPServer` `Thread.sleep` in deprecated `startAndWait`;
`GlobalImageLoadManager` `loadImageOptimizedForDisplay` chain (5 funcs, zero callers);
`TweetCacheManager.clearCacheOnSignout`~~ — **all deleted (Jul 2026)**.

---

## 5. Verified clean (so the sweep is known-complete)

No direct hprose `client.invoke` outside `HproseInstance`. No `DispatchQueue.main.sync`.
No `DispatchSemaphore`. No synchronous `URLSession`. No locks held across `await` (33
`NSLock`/`os_unfair_lock` sites all have short critical sections). Feed/scroll image decode
is correctly off-main. `BlackList`, `NodePool`, `NodeConnectionPool`, `ImageCacheManager`,
`TweetHeightCache` etc. are correctly protected.

---

## 6. Recommended fix order

1. **Slow images (§3) — RESOLVED DIFFERENTLY (Jul 2026):** the dominant per-request cost
   (two `task_info` syscalls per load on main) was fixed by the off-main memory sampler;
   cache checks are memory-only on main. The full `actor` conversion was evaluated and
   **deliberately not done**: it would break the synchronous memory-cache fast path
   (`request.completion(image)` inline is what makes cell reuse flicker-free) and introduce
   cancel/load reordering risk, for what is now just dictionary bookkeeping on main.
   Do not revisit unless profiling shows `loadImage` itself hot on main.
2. **Video spinner bug:** diagnose per §2 (log one warm-visible non-primary cell), then fix
   the queued-cell spinner / cover path.
3. **Decode-site wraps** (§4) — mechanical, copy `MediaCellUIView:1085`.
4. ~~**CoreData `performAndWait` → `context.perform`** sweep (§4).~~ **DONE (Jul 2026)**
   except deliberate holdouts noted in §4.
5. ~~**Launch:** use `startAndWaitAsync()` to remove the 2 s `group.wait` (§4).~~ **DONE (Jul 2026)**
6. ~~**Remaining races**~~ **DONE (Jul 2026)** including the `HproseClient` question — which
   turned out to be a per-RPC NSURLSession leak; see §4.
   Also evaluated: actor-ifying `BlackList`/`NodePool`/`TweetDeletionRegistry` — rejected;
   their callers are synchronous `filter`/`guard` paths (UIKit cell config, SwiftUI list
   computation) where forcing `await` is worse than the audited locks they already have.
7. ~~**Delete dead code** (§4).~~ **DONE (Jul 2026)**.

---

*Generated as part of the Swift 6 migration review. The startup/login freezes, the
`BlackList` crash, and the `LocalHTTPServer.listener` race are already fixed; items above
remain.*
