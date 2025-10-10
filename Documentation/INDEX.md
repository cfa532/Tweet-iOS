# Tweet-iOS Documentation Index

**Last Updated:** October 10, 2025  
**Documentation Version:** 2.0

Welcome to the Tweet-iOS documentation! This index provides quick access to all documentation organized by topic.

---

## 📚 Table of Contents

- [Getting Started](#getting-started)
- [Architecture & Design](#architecture--design)
- [Video System](#video-system)
- [Feature Documentation](#feature-documentation)
- [Performance & Optimization](#performance--optimization)
- [Development Guides](#development-guides)
- [Bug Fixes & Issues](#bug-fixes--issues)
- [Legacy & Historical](#legacy--historical)

---

## Getting Started

### Essential Reading

| Document | Description | Status |
|----------|-------------|--------|
| [README.md](../README.md) | Main project overview, setup instructions, features | ✅ Current |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | High-level architecture, patterns, layer breakdown | ✅ Current |
| [FEATURES.md](./FEATURES.md) | Complete feature list with implementation details | ✅ Current |
| [TODO.md](../TODO.md) | Project todos and development status | ✅ Current |

### Quick Start

1. Read [README.md](../README.md) for project overview and setup
2. Review [ARCHITECTURE.md](./ARCHITECTURE.md) to understand the app structure
3. Explore [FEATURES.md](./FEATURES.md) for detailed feature documentation
4. Check [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md) for video system overview

---

## Architecture & Design

### Core Architecture

| Document | Description | Last Updated |
|----------|-------------|--------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Complete architecture overview with MVVM pattern, layers, data flow | Oct 2025 |
| [CommentSystemREADME.md](./CommentSystemREADME.md) | Comment system architecture, tweet types, notification filtering | Current |
| [NETWORK_RESILIENCE.md](./NETWORK_RESILIENCE.md) | Network layer, error handling, retry logic | Current |

### Design Patterns

**Used Patterns:**
- MVVM (Model-View-ViewModel)
- Singleton (Shared managers)
- Factory (Object creation with caching)
- Observer (NotificationCenter, Combine)
- Repository (Data access abstraction)
- Delegate (Callbacks, protocols)

**Reference:** [ARCHITECTURE.md - Design Patterns](./ARCHITECTURE.md#key-design-patterns)

---

## Video System

### Primary Documentation

| Document | Description | Status |
|----------|-------------|--------|
| [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md) | **START HERE** - Complete video system overview | ✅ Production |
| [VIDEO_CACHING_SYSTEM.md](./VIDEO_CACHING_SYSTEM.md) | Disk caching, memory management, cache layers | ✅ Production |
| [VIDEO_PERFORMANCE_OPTIMIZATION.md](./VIDEO_PERFORMANCE_OPTIMIZATION.md) | Performance improvements and optimization techniques | ✅ Current |

### Implementation Details

| Document | Description | Last Updated |
|----------|-------------|--------------|
| [CACHED_VIDEO_LOADING_OPTIMIZATION.md](./CACHED_VIDEO_LOADING_OPTIMIZATION.md) | CachingPlayerItem mechanics, segment preloading | Oct 2025 |
| [VideoPlaybackAlgorithm.md](./VideoPlaybackAlgorithm.md) | Playback algorithm and state management | Oct 2025 |
| [SEQUENTIAL_VIDEO_PLAYBACK_IMPLEMENTATION.md](./SEQUENTIAL_VIDEO_PLAYBACK_IMPLEMENTATION.md) | Sequential playback in feeds | Oct 2025 |
| [VIDEO_CONVERSION_SERVICE.md](./VIDEO_CONVERSION_SERVICE.md) | Video format conversion, HLS generation | Oct 2025 |

### Video System Fixes & Debugging

| Document | Description | Status |
|----------|-------------|--------|
| [FULLSCREEN_BLACK_SCREEN_FIX.md](./FULLSCREEN_BLACK_SCREEN_FIX.md) | Fixed black screen on fullscreen transitions | ✅ Resolved |
| [FULLSCREEN_MUTE_STATE_FIX.md](./FULLSCREEN_MUTE_STATE_FIX.md) | Fixed mute state synchronization | ✅ Resolved |
| [MEDIACELL_MUTE_STATE_FIX.md](./MEDIACELL_MUTE_STATE_FIX.md) | Fixed MediaCell mute state issues | ✅ Resolved |
| [VIDEO_STATE_MANAGEMENT_FIX.md](./VIDEO_STATE_MANAGEMENT_FIX.md) | Video state management improvements | ✅ Resolved |
| [TWEETDETAIL_PLAYER_CLEANUP_FIX.md](./TWEETDETAIL_PLAYER_CLEANUP_FIX.md) | TweetDetail player lifecycle fixes | ✅ Resolved |
| [TWEETDETAIL_SINGLETON_PLAYER.md](./TWEETDETAIL_SINGLETON_PLAYER.md) | Singleton player for detail views | ✅ Implemented |
| [FULLSCREEN_VIDEO_DEBUG_SESSION.md](./FULLSCREEN_VIDEO_DEBUG_SESSION.md) | Debugging session notes | Historical |

### Video System Key Concepts

**Components:**
1. **SimpleVideoPlayer** - Unified video player (3 modes: mediaCell, mediaBrowser, tweetDetail)
2. **VideoStateCache** - Player state sharing for seamless transitions
3. **SharedAssetCache** - Asset and player caching with disk persistence
4. **CachingPlayerItem** - HLS segment caching
5. **ResourceLoaderDelegate** - HLS content loading
6. **LocalHTTPServer** - Serves cached media (port 8080)
7. **DetailVideoManager** - Singleton for detail view playback

**Reading Order:**
1. [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md) - Overview
2. [VIDEO_CACHING_SYSTEM.md](./VIDEO_CACHING_SYSTEM.md) - Caching details
3. [CACHED_VIDEO_LOADING_OPTIMIZATION.md](./CACHED_VIDEO_LOADING_OPTIMIZATION.md) - Implementation

---

## Feature Documentation

### User Features

| Document | Description | Status |
|----------|-------------|--------|
| [FEATURES.md](./FEATURES.md) | Complete feature list with implementation details | ✅ Current |
| [CHAT_AND_SEARCH_FEATURES.md](./CHAT_AND_SEARCH_FEATURES.md) | Chat system and search functionality | 🔄 In Progress |
| [CommentSystemREADME.md](./CommentSystemREADME.md) | Comment and reply system | ✅ Complete |
| [PUSH_NOTIFICATIONS.md](./PUSH_NOTIFICATIONS.md) | Push notification setup and handling | ✅ Complete |

### Content Moderation

**Features Implemented:**
- User blocking
- Tweet reporting
- Content filtering (keywords, content types)
- Terms of Service acceptance

**Reference:** [TODO.md - Content Moderation](../TODO.md#content-moderation-features)

### Media Features

| Feature | Documentation |
|---------|---------------|
| Video Playback | [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md) |
| Image Handling | [FEATURES.md - Image Handling](./FEATURES.md#image-handling) |
| Audio Playback | [FEATURES.md - Audio Playback](./FEATURES.md#audio-playback) |
| Media Browser | [FEATURES.md - Media Handling](./FEATURES.md#media-handling) |
| Image Zoom | [IMAGE_ZOOM_ALGORITHM.md](./IMAGE_ZOOM_ALGORITHM.md) |

---

## Performance & Optimization

### Optimization Guides

| Document | Description | Impact |
|----------|-------------|--------|
| [VIDEO_PERFORMANCE_OPTIMIZATION.md](./VIDEO_PERFORMANCE_OPTIMIZATION.md) | Video system optimizations | High |
| [VIDEO_OPTIMIZATION_SUMMARY.md](./VIDEO_OPTIMIZATION_SUMMARY.md) | Summary of video improvements | Medium |
| [TWEET_MEMORY_CACHE_ALGORITHM.md](./TWEET_MEMORY_CACHE_ALGORITHM.md) | Tweet caching strategy | Medium |
| [README.md - Scrolling Performance](../README.md#tweet-list-scrolling-performance) | List scrolling optimizations | High |

### Performance Metrics

**Video System:**
- MediaCell → Fullscreen: Instant (0ms)
- Cached video load: <100ms
- Network video load: 1-3s first segment

**Memory Usage:**
- Target: <800MB active
- Cleanup trigger: 800MB
- Max player cache: 25 players (~250MB)

**Cache Efficiency:**
- Player reuse: 100% for MediaCell ↔ MediaBrowser
- Disk cache hit rate: ~70% for repeated views

---

## Development Guides

### Build & Debug

| Document | Description | Status |
|----------|-------------|--------|
| [DEBUG_BUILD_INSTRUCTIONS.md](./DEBUG_BUILD_INSTRUCTIONS.md) | How to build debug version | ✅ Current |
| [PERMISSION_LOCALIZATION_GUIDE.md](./PERMISSION_LOCALIZATION_GUIDE.md) | Localizing permission requests | ✅ Current |

### Code Quality

| Document | Description | Status |
|----------|-------------|--------|
| [CODE_SMELL_REPORT.md](./CODE_SMELL_REPORT.md) | Code quality issues and recommendations | Historical |
| [IMPROPER_DELAY_USAGE_REPORT.md](./IMPROPER_DELAY_USAGE_REPORT.md) | Timing issue analysis | Historical |

### Session Notes

| Document | Description | Status |
|----------|-------------|--------|
| [SESSION_FIXES_SUMMARY.md](./SESSION_FIXES_SUMMARY.md) | Bug fix session summary | Historical |
| [REFACTORING_COMPLETE.md](./REFACTORING_COMPLETE.md) | Refactoring session notes | Historical |
| [WORKING_IMPLEMENTATION.md](./WORKING_IMPLEMENTATION.md) | Implementation notes | Historical |

---

## Bug Fixes & Issues

### Resolved Issues

#### Video System
- ✅ [FULLSCREEN_BLACK_SCREEN_FIX.md](./FULLSCREEN_BLACK_SCREEN_FIX.md) - Black screen on fullscreen
- ✅ [FULLSCREEN_MUTE_STATE_FIX.md](./FULLSCREEN_MUTE_STATE_FIX.md) - Mute state issues
- ✅ [MEDIACELL_MUTE_STATE_FIX.md](./MEDIACELL_MUTE_STATE_FIX.md) - MediaCell mute issues
- ✅ [VIDEO_STATE_MANAGEMENT_FIX.md](./VIDEO_STATE_MANAGEMENT_FIX.md) - State management
- ✅ [TWEETDETAIL_PLAYER_CLEANUP_FIX.md](./TWEETDETAIL_PLAYER_CLEANUP_FIX.md) - Player cleanup

#### Data Sync
- ✅ [TWEET_SYNC_ISSUE_ANALYSIS.md](./TWEET_SYNC_ISSUE_ANALYSIS.md) - Tweet sync problems

#### Audio
- ✅ [AUDIO_CALL_COMPATIBILITY_FIX.md](./AUDIO_CALL_COMPATIBILITY_FIX.md) - Call interruption handling

### Issue Analysis

**Video Issues:** Most video issues were related to:
1. Player lifecycle management
2. Mute state synchronization
3. Layer attachment/detachment
4. Cache key conflicts

**Solutions Implemented:**
- Unified `SimpleVideoPlayer` with mode parameter
- `VideoStateCache` for player sharing
- Automatic mute state based on mode
- MediaID-based caching (IPFS hashes)

---

## Legacy & Historical

### Analysis Documents (Historical)

| Document | Description | Status |
|----------|-------------|--------|
| [SIMPLEVIDEOPLAYER_ANALYSIS.md](./SIMPLEVIDEOPLAYER_ANALYSIS.md) | Player component analysis | Historical |
| [README_VIDEO_LOADING.md](./README_VIDEO_LOADING.md) | Video loading documentation | Superseded |

### Session Notes (Historical)

| Document | Description |
|----------|-------------|
| [SESSION_FIXES_SUMMARY.md](./SESSION_FIXES_SUMMARY.md) | Bug fix session |
| [REFACTORING_COMPLETE.md](./REFACTORING_COMPLETE.md) | Refactoring session |
| [WORKING_IMPLEMENTATION.md](./WORKING_IMPLEMENTATION.md) | Implementation notes |
| [FULLSCREEN_VIDEO_DEBUG_SESSION.md](./FULLSCREEN_VIDEO_DEBUG_SESSION.md) | Debug session |

### Superseded Documents

These documents contain historical information but have been superseded by newer documentation:

- `README_VIDEO_LOADING.md` → Use [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md)
- `SIMPLEVIDEOPLAYER_ANALYSIS.md` → Current implementation in [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md)

---

## Quick Reference by Topic

### 🎥 Video Playback
- Architecture: [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md)
- Caching: [VIDEO_CACHING_SYSTEM.md](./VIDEO_CACHING_SYSTEM.md)
- Performance: [VIDEO_PERFORMANCE_OPTIMIZATION.md](./VIDEO_PERFORMANCE_OPTIMIZATION.md)

### 💬 Comments & Social
- Comments: [CommentSystemREADME.md](./CommentSystemREADME.md)
- Chat: [CHAT_AND_SEARCH_FEATURES.md](./CHAT_AND_SEARCH_FEATURES.md)
- Features: [FEATURES.md](./FEATURES.md)

### 🏗️ Architecture & Design
- Overview: [ARCHITECTURE.md](./ARCHITECTURE.md)
- Network: [NETWORK_RESILIENCE.md](./NETWORK_RESILIENCE.md)
- Caching: [TWEET_MEMORY_CACHE_ALGORITHM.md](./TWEET_MEMORY_CACHE_ALGORITHM.md)

### 🚀 Performance
- Video: [VIDEO_PERFORMANCE_OPTIMIZATION.md](./VIDEO_PERFORMANCE_OPTIMIZATION.md)
- Scrolling: [README.md](../README.md#tweet-list-scrolling-performance)
- Memory: [TWEET_MEMORY_CACHE_ALGORITHM.md](./TWEET_MEMORY_CACHE_ALGORITHM.md)

### 🐛 Troubleshooting
- Video black screen: [FULLSCREEN_BLACK_SCREEN_FIX.md](./FULLSCREEN_BLACK_SCREEN_FIX.md)
- Mute issues: [FULLSCREEN_MUTE_STATE_FIX.md](./FULLSCREEN_MUTE_STATE_FIX.md)
- Audio interruptions: [AUDIO_CALL_COMPATIBILITY_FIX.md](./AUDIO_CALL_COMPATIBILITY_FIX.md)

### 🔧 Development
- Debug build: [DEBUG_BUILD_INSTRUCTIONS.md](./DEBUG_BUILD_INSTRUCTIONS.md)
- Localization: [PERMISSION_LOCALIZATION_GUIDE.md](./PERMISSION_LOCALIZATION_GUIDE.md)
- TODO: [TODO.md](../TODO.md)

---

## Documentation Statistics

**Total Documents:** 38 markdown files  
**Last Major Update:** October 10, 2025  
**Documentation Coverage:**
- ✅ Video System: Complete
- ✅ Architecture: Complete
- ✅ Features: Complete
- 🔄 Chat System: In Progress
- ✅ Performance: Complete
- ✅ Bug Fixes: Documented

---

## Contributing to Documentation

When updating documentation:

1. **Update the "Last Updated" date** at the top of the file
2. **Mark status** (✅ Complete, 🔄 In Progress, ⚠️ Outdated)
3. **Update this index** if you add/remove/rename documents
4. **Link to related documents** for cross-reference
5. **Include code examples** where helpful
6. **Add diagrams** for complex systems

---

## Need Help?

**Can't find what you're looking for?**

1. Check the [README.md](../README.md) for a general overview
2. Search for keywords in [FEATURES.md](./FEATURES.md)
3. For video issues, start with [VIDEO_SYSTEM_ARCHITECTURE.md](./VIDEO_SYSTEM_ARCHITECTURE.md)
4. For architecture questions, see [ARCHITECTURE.md](./ARCHITECTURE.md)

**Still stuck?**
- Check historical documents in [Legacy & Historical](#legacy--historical)
- Review related bug fix documents in [Bug Fixes & Issues](#bug-fixes--issues)
- Look at session notes for context on past decisions

---

**Happy coding! 🚀**

