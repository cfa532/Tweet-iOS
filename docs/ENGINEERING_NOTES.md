# Engineering Notes

This note captures implementation context that is useful for maintainers but not central to day-to-day product docs.

## 1) Performance Architecture Strategy

### Core observation

Long-session regressions are usually driven by **resource accumulation** (players, timers, observers, network work), not only by layout cost.

### Strategy

Use coordinated control planes instead of per-cell autonomy:

- Playback coordination decides what should play now.
- Loading coordination decides what should load now.
- Cache coordination decides what should stay alive now.
- Proxy/network coordination decides who gets bandwidth now.

### Practical rules

1. Keep single-playback semantics in each feed context.
2. Prefer delegate/coordinator control over broad fan-out observer patterns.
3. Keep preload windows small and directional.
4. Cancel stale/off-screen work aggressively, but protect near-visible targets.
5. Make foreground media intent win over background preload work.

### Success indicators

- stable memory over long browsing sessions
- fewer stalls from background preloads starving visible playback
- lower timer/observer overhead
- fewer duplicate network requests under slow IPFS conditions

## 2) Memory Fix Consolidation

These fixes were previously tracked in separate files and are consolidated here.

### Player cleanup correctness

In `SharedAssetCache`, cleanup paths use full player teardown (`releasePlayer(...)`) rather than partial pause-only cleanup.

Why it matters:
- releases player item buffers more reliably
- cancels loading on old items
- avoids retained AVFoundation objects lingering in memory

### Loading/preload task lifecycle cleanup

`loadingTasks` and `preloadTasks` are removed on completion (success and failure), not only on error.

Why it matters:
- completed tasks do not accumulate in dictionaries
- fewer retained references to assets/player state

### Temp file cleanup on failed downloads

Image download paths now ensure temporary files are cleaned up even when requests fail or are cancelled.

Why it matters:
- avoids disk/temp buildup during flaky network periods
- reduces side effects from repeated retries

### Memory pressure behavior tuning

Cache release behavior was tuned from overly aggressive bulk drops to more balanced partial release.

Why it matters:
- avoids repeated clear/reload churn
- improves scrolling stability and network efficiency

### Avatar cache protection

Avatar cache keys are tracked and protected during partial image-cache release.

Why it matters:
- avoids avatar flicker/reload loops
- keeps high-value UI assets stable under pressure

### Operational expectation

After these fixes:
- memory usage should plateau instead of monotonically growing in long sessions
- cleanup cycles should remove meaningful retained media state
- network failures should not leave growing temp/task residue
- avatars should remain stable during partial cache release

## 3) Feed Pagination Must Be Driven by Content, Not by State Transitions

### The failure

A device trace showed the main feed fetching **63 pages (~230 "valid" tweets) while the user
had scrolled past 22 rows** — roughly ten times the content actually needed, each page a
server round trip plus a table mutation landing mid-scroll. It is a scroll-**down**-only
cost, because auto-load only fires near the bottom, which is why it read as "scroll down is
rougher than scroll up".

### Why it ran away

Two mechanisms combined:

1. The chained auto-load check fires on the `isLoadingMore` **state transition**
   (`updateLoadingState` → `scheduleAutoLoadMoreCheck`), not on content arriving.
2. `appendTweetsPreservingOrder` dedupes by tweet id. A ranked server feed hands back tweets
   the client already holds under a new page number, so a "valid" page can add **zero** rows.

Zero new rows means the remaining-rows-below-viewport measure never moves, so the threshold
stays crossed and the next page is requested the instant the previous one lands. The loop
can only end when the server finally returns a partial page.

### The rule

> An automatic page that added nothing does not earn another automatic page.

`triggerAutoLoadMoreIfNeeded` records the row count when it issues an automatic load and
refuses to chain if the count did not grow. The user scrolling again goes through the
gesture-driven branch, which is separately capped per gesture. Screen-filling at launch is
unaffected: pages that genuinely add rows still chain.

### Related rule for merges

`Tweet.update(from:)` guards every write on the value actually differing. Assigning a
`@Published` property publishes whether or not the value changed, and this path runs for
every tweet a paginated response re-delivers — unguarded, one merge woke every bound cell
(body, action bar, header) for rows whose content was byte-identical, during a scroll.

## 4) One-Time Framework Initialisation Must Not Land in `cellForRowAt`

Several scroll lurches turned out not to be *our* work at all, but the first call into a
system framework, paid inside `cellForRowAt` inside the CA commit — so the whole frame is
lost and the list jumps by however far the coast had travelled.

Found with `MainThreadStallSampler` (in `TweetTableViewCell.swift`) lowered to a 40ms
threshold. Its default 120ms is tuned for hangs and steps straight over this class of bug —
**lower the threshold when chasing a lurch rather than a freeze.**

| Cost | Trigger | Fix |
| --- | --- | --- |
| **133ms** `CUIStructuredThemeStore lookupAssetForKey:` | `createTweetMenu` builds ~9 `UIAction`s, each with `UIImage(systemName:)`; its cache key includes the tweet id, so every cell reuse rebuilt it | `MenuSymbol` cache in `TweetCellContentView` — one CoreUI lookup per symbol, process-wide |
| **145ms** `FigVideoContainerLayer initWithUUID:` | the process's first `AVPlayerLayer()`, built lazily by the first video row dequeued | `AppDelegate.warmVideoLayerRuntime()` pays it at launch |
| **61ms** `liblangid` / CoreNLP `identifyLanguage` | `NSDataDetector` link scanning inside `makeContentAttributedString`, reached from `heightForRowAt` | not fixed — it is a `TweetHeightPrewarmer` miss; see below |
| **40–316ms** `libhvf` / `libFontParser` glyph paths | CoreGraphics rasterising CJK glyph outlines during `CALayer _display` | not fixed; heavily simulator-inflated |

### The rule

> Anything that is expensive exactly once per process should be made to happen at launch,
> where a stall is invisible, rather than lazily on whatever frame first needs it.

`AppDelegate` already had this pattern for Swift's protocol-conformance caches
(`warmPrintConformanceCaches`, ~127ms). Video-layer registration now joins it.

### Residual

The two unfixed rows above are both **prewarm misses**: `TweetHeightPrewarmer` normally
typesets off the main thread, but a fast fling can outrun it, and a miss is expensive
because `makeContentAttributedString` binary-searches the truncation point with a full
`sizeThatFits` per iteration *and* runs `NSDataDetector` over the text. Measured on the
simulator, where both CoreText and glyph rasterisation cost far more than on device —
profile there before optimising further.

## 5) Historical UIKit Migration Context

This section preserves lightweight historical context from the feed migration period.

### What changed

The feed moved from SwiftUI-heavy cell composition toward UIKit-first rendering to improve timeline performance and reduce view churn.

### Lasting outcomes

- Feed rendering is UIKit-first for performance-critical surfaces.
- Video playback is coordinated at feed level, not independently per cell.
- Shared media/cache managers are central infrastructure.
- Scroll/media lifecycle handling is tied to visibility and navigation context.

## Source of Truth

For current behavior, rely on:

- `./ARCHITECTURE.md`
- `./VIDEO_PLAYBACK_PIPELINE.md`
- `./MEMORY_MANAGEMENT.md`
- `./NETWORK_RESILIENCE.md`
- `./FEED_ROW_HEIGHTS.md`
