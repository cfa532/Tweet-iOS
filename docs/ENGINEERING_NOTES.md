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

## 3) Historical UIKit Migration Context

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

- `../ARCHITECTURE.md`
- `../VIDEO_PLAYBACK_PIPELINE.md`
- `../MEMORY_MANAGEMENT.md`
- `../NETWORK_RESILIENCE.md`
