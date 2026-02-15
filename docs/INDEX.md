# Tweet-iOS Documentation Index

**Last Updated:** February 2026

---

## Getting Started

| Document | Description |
| -------- | ----------- |
| [QUICKSTART.md](./QUICKSTART.md) | Getting started guide for new developers |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | App architecture: UIKit/SwiftUI hybrid, data flow, key managers |
| [FEATURES.md](./FEATURES.md) | Complete feature list and capabilities |
| [DEBUG_BUILD_INSTRUCTIONS.md](./DEBUG_BUILD_INSTRUCTIONS.md) | Build instructions, debugging, log capture |

---

## Core Systems

### Video

| Document | Description |
| -------- | ----------- |
| [VIDEO_SYSTEM.md](./VIDEO_SYSTEM.md) | Complete video architecture and orchestration |
| [VideoPlaybackAlgorithm.md](./VideoPlaybackAlgorithm.md) | Autoplay, visibility detection, sequential playback |
| [VIDEO_PRIORITY_ALGORITHM.md](./VIDEO_PRIORITY_ALGORITHM.md) | Video download priority and concurrency |
| [HLS_VIDEO_IMPLEMENTATION.md](./HLS_VIDEO_IMPLEMENTATION.md) | HLS streaming with local caching proxy |
| [HLS_CONVERSION_ALGORITHM.md](./HLS_CONVERSION_ALGORITHM.md) | Server-side HLS conversion pipeline |
| [architecture/VIDEO_COORDINATOR_ANALYSIS.md](./architecture/VIDEO_COORDINATOR_ANALYSIS.md) | Per-feed VideoPlaybackCoordinator analysis |
| [features/RETWEET_VIDEO_ISSUE.md](./features/RETWEET_VIDEO_ISSUE.md) | Retweet video race condition analysis |

### Caching & Memory

| Document | Description |
| -------- | ----------- |
| [MEMORY_MANAGEMENT.md](./MEMORY_MANAGEMENT.md) | Memory monitoring, thresholds, cleanup strategies |
| [TWEET_CACHE_STRATEGY.md](./TWEET_CACHE_STRATEGY.md) | Dual-strategy caching (main feed vs profile) |
| [PERMANENT_CACHE_SYSTEM.md](./PERMANENT_CACHE_SYSTEM.md) | Permanent caching for private/bookmarked tweets |
| [IMAGE_ZOOM_ALGORITHM.md](./IMAGE_ZOOM_ALGORITHM.md) | Dynamic image zoom in MediaBrowserView |

### Networking

| Document | Description |
| -------- | ----------- |
| [NETWORK_RESILIENCE.md](./NETWORK_RESILIENCE.md) | Multi-layer caching, BlackList, retry logic |
| [NODEPOOL.md](./NODEPOOL.md) | Self-healing IP cache with trust vs verify strategies |
| [GETPROVIDERIP_FLOW.md](./GETPROVIDERIP_FLOW.md) | Provider IP resolution with health checking |
| [BLACKLIST_MEDIA_INTEGRATION.md](./BLACKLIST_MEDIA_INTEGRATION.md) | BlackList system for failed media URLs |

### Scroll & Layout

| Document | Description |
| -------- | ----------- |
| [architecture/SCROLL_POSITION_FLOW.md](./architecture/SCROLL_POSITION_FLOW.md) | Scroll position preservation flow |
| [architecture/SCROLL_POSITION_PRESERVATION.md](./architecture/SCROLL_POSITION_PRESERVATION.md) | In-memory scroll position (no disk persistence) |
| [STARTUP_PERFORMANCE_OPTIMIZATION.md](./STARTUP_PERFORMANCE_OPTIMIZATION.md) | Phased startup with lazy initialization |

---

## Features

| Document | Description |
| -------- | ----------- |
| [CHAT_AND_SEARCH_FEATURES.md](./CHAT_AND_SEARCH_FEATURES.md) | Chat system and search functionality |
| [CommentSystemREADME.md](./CommentSystemREADME.md) | Comment/reply system implementation |
| [UPLOAD_SYSTEM.md](./UPLOAD_SYSTEM.md) | Upload system with progress tracking |
| [SHARING_SYSTEM.md](./SHARING_SYSTEM.md) | IP-based sharing URLs with Vue HashHistory |
| [PUSH_NOTIFICATIONS.md](./PUSH_NOTIFICATIONS.md) | Local notifications (current) + APNs push (planned) |

---

## Guides

| Document | Description |
| -------- | ----------- |
| [UNIVERSAL_LINKS.md](./UNIVERSAL_LINKS.md) | Universal links setup and testing |
| [PERMISSION_LOCALIZATION_GUIDE.md](./PERMISSION_LOCALIZATION_GUIDE.md) | Permission string localization |
| [Server_API.md](./Server_API.md) | Server API reference (symlink to backend repo) |

---

## Archive

Historical documentation preserved in [archive/](./archive/). Contains 170+ files including:

- **Session-specific fix logs** from Oct 2025 - Jan 2026 (pre-UIKit migration)
- **Old performance audits** and optimization reports
- **Superseded architecture docs** (SwiftUI-only feed, old video systems)
- **Consolidated originals** (NodePool, Universal Links, Push Notifications pairs)

Most archived docs reference the old SwiftUI feed architecture replaced by pure UIKit cells in Feb 2026 (Phases 1-5).
