# Tweet-iOS Architecture Overview

**Last Updated:** June 2026
**Version:** 3.3

## What This Architecture Optimizes For

Tweet-iOS is designed around a practical goal: keep the app fast and stable when users are scrolling media-heavy feeds on unreliable networks.

The core strategy is:
- Render the feed with UIKit where scroll performance matters most.
- Keep product surfaces in SwiftUI for developer speed and clearer composition.
- Centralize hard problems (networking, media, caching, lifecycle recovery) in a small set of Core managers.
- Prefer graceful degradation (cache-first rendering, cancellation, retries, fallbacks) over rigid "all-or-nothing" flows.

## Design Principles

1. **Fast first paint**
   - Show cached content early, then reconcile with server state.
2. **Single source of truth per concern**
   - API calls through `HproseInstance`, video player lifecycle through `SharedAssetCache`, upload lifecycle through `UploadProgressManager`.
3. **Resource-aware media handling**
   - Only load what is likely to be watched next; cancel expensive work once it is no longer relevant.
4. **Lifecycle resilience**
   - Treat foreground/background transitions as first-class events, not edge cases.
5. **Feature modules on top of shared infrastructure**
   - Home/Chat/Compose/Search/Profile focus on product behavior and reuse Core systems.

## Glossary (Quick Read)

- **Primary video**: The single video currently prioritized for playback and network bandwidth in a feed.
- **Preload**: Background preparation of likely-next media (asset/player/network) before it becomes primary.
- **Directional preload**: Preloading biased toward current scroll direction (usually the next items users are most likely to watch).
- **Protected set**: Media IDs temporarily shielded from cancellation/eviction because they are visible or about to be visible.
- **Deduplication**: Reusing in-flight segment/range work so duplicate network requests are avoided.
- **Slot**: A per-node concurrency budget unit used by `NodeConnectionPool` to prevent background downloads from starving foreground playback.

## Top-Level Module Map

| Module | Main Paths | Why it exists |
| --- | --- | --- |
| App Shell | `Sources/App` | Own app startup, lifecycle bridging, root tab/navigation orchestration |
| Core Infrastructure | `Sources/Core` | Hold shared mechanics: API, media orchestration, cache, memory, notifications |
| Feed + Tweet UI | `Sources/Tweet` | Provide high-performance tweet list/detail/comment rendering |
| Product Features | `Sources/Features` | Implement user-facing flows (Home/Compose/Chat/Search/Profile/Legal) |
| Video Proxy/Cache | `Sources/CachingPlayerItem` | Isolate media proxy, IPFS-aware transport, segment/range caching |
| Data Models | `Sources/DataModels` | Define shared entities and IDs used across all modules |
| Account/Settings | `Sources/Screens` | Keep auth and settings surfaces separated from feature modules |
| Utilities | `Sources/Utils` | Contain cross-cutting UI/helpers (theme, deep links, prefs, etc.) |

## How The App Is Organized

### 1) Startup and Lifecycle

**Key files:** `Sources/App/TweetApp.swift`, `Sources/App/AppDelegate.swift`

Design idea:
- Separate "show something now" from "finish full initialization".

Mechanism:
- `AppState.initialize()` sets up local basics and `initializeAppUser()` first.
- Cached content is allowed to render immediately (`canShowCachedContent`).
- Full network bootstrap (`initAppEntry`) continues in background.
- `AppDelegate` starts `LocalHTTPServer` early and owns lifecycle-sensitive recovery paths.

Why this matters:
- Users avoid staring at an empty loading screen while network/IP resolution completes.
- Video infrastructure is initialized predictably and repaired on lifecycle transitions.

### 2) Home Feed and Timeline Rendering

**Key files:** `Sources/Features/Home/FollowingsTweetView.swift`, `Sources/Tweet/TweetListView.swift`, `Sources/Tweet/UIKit/TweetTableViewController.swift`

Design idea:
- The feed is the hottest path, so it gets the most performance-oriented rendering stack.

Mechanism:
- Cache-first fetch path for initial list display.
- UIKit table/cell rendering for timeline media-heavy scrolling.
- SwiftUI remains the composition layer above UIKit bridge components.

Why this matters:
- Scroll smoothness remains stable even with mixed text/media content and frequent list updates.

### 3) Video Playback Architecture

**Key files:** `Sources/Core/VideoPlaybackCoordinator.swift`, `Sources/Core/SharedAssetCache.swift`, `Sources/Core/VideoLoadingManager.swift`, `Sources/CachingPlayerItem/LocalHTTPServer.swift`, `Sources/CachingPlayerItem/NodeConnectionPool.swift`

Design idea:
- Treat playback as a scheduling problem, not just a player problem.

At a high level:
- `VideoPlaybackCoordinator` decides *what should play now*.
- `VideoLoadingManager` decides *what should load now*.
- `SharedAssetCache` decides *what should stay alive now*.
- `LocalHTTPServer` and `NodeConnectionPool` decide *how network bandwidth is allocated now*.

#### Video strategy: from user intent to network behavior

**Visibility-driven autoplay**
- Visibility is measured at the media cell level, not the containing tweet row.
- Any positive media-cell intersection can begin cover/player loading.
- Autoplay still uses stricter visible-video selection so rapid edge intersections do not steal playback.
- Continue threshold is stricter, which reduces rapid start/stop flapping while scrolling.

**Directional preload strategy**
- Preload only invisible media. Visible media loads through the visible-cell path and must not be counted as directional preload.
- Preload the next likely-to-watch invisible video with a small directional window.
- Main, standard, and profile feeds pre-create up to 1 nearby off-screen player after scroll stop.
- Feed-level player creation is capped at 2 in-flight creations, with visible/primary work taking priority.
- Directional image preload stays wider: 2 rows ahead, 1 opposite row, max 4 invisible image tasks.
- Directional image/video preloads start only when the selected visible primary video is actually playing or recently playing.
- Keep preload scope intentionally tight to avoid over-downloading content users may never see.

**Off-screen cancellation strategy**
- Scroll start cancels pending directional image/video preload work before new dragging/deceleration begins.
- Once media is behind the active window, cancel unnecessary work in batches.
- Cancellation includes async loading, in-flight player creation, and proxy downloads.
- Protected sets prevent accidental cancellation of media that is on-screen or actively selected.

**Primary video prioritization**
- As soon as coordinator selects a primary video, proxy/network paths prioritize it.
- Primary is promoted explicitly (`setPrimaryMediaID`) instead of relying on passive queue timing.
- If the primary is still loading, buffering, or recovering, invisible preloads pause so foreground playback gets the bandwidth.

**IPFS optimization strategy**
- Deduplicate segment/range work whenever possible.
- Use longer tolerance for non-primary/preload paths, shorter response for primary paths.
- Manage slot budgets per node (`host:port`) so one noisy node does not starve all playback.
- Keep non-primary soft cap low (`maxPreloadSlots = 3`) while allowing primary-specific bypass/caps.

#### Human-friendly interaction flow (primary vs preload)

```
User scrolls feed
  -> Coordinator updates on-screen media set
    -> Next directional videos selected for preload (small window)
      -> SharedAssetCache starts preload players/assets
        -> LocalHTTPServer performs range/segment fetch with dedup

Primary video is selected
  -> Coordinator marks primary in proxy (setPrimaryMediaID)
    -> Node pool favors primary traffic over preloads
      -> Visible playback stabilizes first
        -> stale/off-screen preload work is cancelled or deprioritized
```

#### Why this design works

- It prevents "good network assumptions" from breaking UX on weak links.
- It protects foreground intent (what user is watching now) from background greed (what might be watched next).
- It keeps memory and bandwidth bounded by policy, not by chance.

### 4) Upload and Media Processing

**Key files:** `Sources/Core/TweetUploadManager.swift`, `Sources/Core/UploadProgressManager.swift`, `Sources/Core/VideoConversionService.swift`

Design idea:
- Uploads should be reliable and understandable, even when app state changes.

Mechanism:
- Serialize upload execution through a shared queue.
- Track stage-level progress centrally.
- Persist pending tweet uploads for recovery/retry flows.

Why this matters:
- Prevents race conditions between concurrent media uploads.
- Gives users consistent progress feedback and resumable behavior.

### 5) Chat

**Key files:** `Sources/Features/Chat/ChatSessionManager.swift`, `Sources/Features/Chat/ChatRepository.swift`, `Sources/Core/ChatCacheManager.swift`

Design idea:
- Chat should feel responsive even before backend sync completes.

Mechanism:
- Cache sessions/messages locally, merge with backend checks.
- Surface unread count in root tab shell.
- Use local notification manager for message alerts and interaction routing.

### 6) Search and Profile

**Key files:** `Sources/Features/Search/SearchScreen.swift`, `Sources/Features/Profile/ProfileView.swift`

Design idea:
- Reuse shared feed/model/media infrastructure instead of building special paths.

Mechanism:
- Search blends network queries and local cache support.
- Profile timelines reuse timeline rendering and media subsystems.

### 7) Network and Backend Integration

**Key files:** `Sources/Core/HproseInstance.swift`, `Sources/Core/HproseClientPool.swift`, `Sources/Core/NodePool.swift`, `Sources/Core/BlackList.swift`

Design idea:
- Make backend access predictable by routing all remote calls through one gateway layer.

Mechanism:
- `HproseInstance` is the RPC boundary for feature modules.
- Client pooling + IP discovery/health checks + node tracking improve resilience.
- Blacklist logic avoids repeatedly expensive failing media/network attempts.

## Cross-Module Interaction Model

```
TweetApp / AppDelegate
  -> ContentView (root tabs + navigation)
    -> Feature modules (Home / Chat / Compose / Search / Profile)
      -> Core managers (cache, video, upload, notifications)
        -> HproseInstance (network gateway)
          -> Leither/Hprose backend

Feed and media views
  -> VideoPlaybackCoordinator
    -> SharedAssetCache
      -> LocalHTTPServer + NodeConnectionPool
        -> IPFS/provider network endpoints
```

## Data and State Strategy

- **Stable model identity:** `Tweet` and `User` instance registries reduce duplicate object drift across views.
- **Layered persistence:** memory state + Core Data cache + network refresh.
- **State propagation:** `@StateObject`, `@Published`, and notification events for cross-boundary coordination.
- **Concurrency model:** async/await and `@MainActor` for UI-facing flows; internal lock/actor patterns for shared resources.

## Cross-Cutting Systems

### Caching
- Tweets/users and chat use dedicated persistent cache managers.
- Media uses player/asset caches plus proxy-backed disk caching for HLS/progressive paths.

### Memory Control
- Managers coordinate cleanup under memory pressure without blindly destroying foreground playback.
- Lifecycle transitions trigger scoped cleanup and recovery to avoid stale/invalid media state.

### Resilience
- Startup and foreground recovery paths handle stale IP/network conditions.
- Message checks, retries, and pending upload recovery reduce user-visible failure impact.

## Platform Constraints

- Root app entry (`TweetApp`, `ContentView`) is iOS 17 annotated.
- Some isolated feature components still compile with iOS 16 annotations, but runtime app behavior follows root targets.
- Feed rendering intentionally prioritizes UIKit performance, while feature composition remains SwiftUI-first.

## Backend / Server Relationship

Tweet-iOS communicates with a separate backend repository:

- Local path: `/Users/cfa532/Documents/GitHub/TweetBackendApp`
- GitHub repo: `TweetBackendApp` under account `cfa532`

Server entry points are JavaScript functions invoked via `lapi.RunMApp("filename", params, [])`.
When API behavior changes, iOS and backend changes should be reviewed together.

## Related Docs

- [Documentation Index](./INDEX.md)
- [Video Playback Pipeline](./VIDEO_PLAYBACK_PIPELINE.md)
- [Upload System](./UPLOAD_SYSTEM.md)
- [Memory Management](./MEMORY_MANAGEMENT.md)
- [Network Resilience](./NETWORK_RESILIENCE.md)
- [Chat and Search Features](./CHAT_AND_SEARCH_FEATURES.md)
