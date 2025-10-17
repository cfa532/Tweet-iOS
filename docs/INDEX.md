# Tweet-iOS Documentation Index

**Last Updated:** October 17, 2025

---

## 📚 Main Documentation

### Core Systems
| Document | Description | Status |
|----------|-------------|--------|
| [**UPLOAD_SYSTEM.md**](./UPLOAD_SYSTEM.md) | Complete upload system with progress tracking, multi-attachment support, background polling | ✅ Production |
| [**VIDEO_SYSTEM.md**](./VIDEO_SYSTEM.md) | Dual video architecture (new shared cache + old fullscreen), HLS/MP4 playback | ⚠️ Partial Migration |
| [**ARCHITECTURE.md**](./ARCHITECTURE.md) | Overall app architecture, MVVM patterns, data flow | ✅ Current |
| [**FEATURES.md**](./FEATURES.md) | Complete feature list and capabilities | ✅ Current |

### Features
| Document | Description | Status |
|----------|-------------|--------|
| [**CHAT_AND_SEARCH_FEATURES.md**](./CHAT_AND_SEARCH_FEATURES.md) | Chat system and search functionality | ✅ Production |
| [**CommentSystemREADME.md**](./CommentSystemREADME.md) | Comment/reply system implementation | ✅ Production |
| [**PUSH_NOTIFICATIONS.md**](./PUSH_NOTIFICATIONS.md) | Push notification setup and handling | ✅ Production |
| [**NETWORK_RESILIENCE.md**](./NETWORK_RESILIENCE.md) | Network error handling and retry logic | ✅ Production |

### Algorithms & Performance
| Document | Description | Status |
|----------|-------------|--------|
| [**IMAGE_ZOOM_ALGORITHM.md**](./IMAGE_ZOOM_ALGORITHM.md) | Image zoom and pan gestures | ✅ Production |
| [**TWEET_MEMORY_CACHE_ALGORITHM.md**](./TWEET_MEMORY_CACHE_ALGORITHM.md) | Tweet caching and memory management | ✅ Production |
| [**VideoPlaybackAlgorithm.md**](./VideoPlaybackAlgorithm.md) | Video autoplay and visibility detection | ✅ Production |

### Build & Development
| Document | Description | Status |
|----------|-------------|--------|
| [**DEBUG_BUILD_INSTRUCTIONS.md**](./DEBUG_BUILD_INSTRUCTIONS.md) | How to build debug/release versions, capture console logs, test background behavior | ✅ Current |
| [**PERMISSION_LOCALIZATION_GUIDE.md**](./PERMISSION_LOCALIZATION_GUIDE.md) | Localization setup for permissions | ✅ Current |

### Recent Critical Fixes
| Document | Description | Date |
|----------|-------------|------|
| [**fixes/PORT_INDEPENDENT_PLAYLIST_CACHING_FIX.md**](./fixes/PORT_INDEPENDENT_PLAYLIST_CACHING_FIX.md) | **FINAL FIX**: Port-independent HLS playlist caching for reliable background recovery | Oct 17, 2025 |
| [**fixes/SESSION_SUMMARY_OCT_17_2025.md**](./fixes/SESSION_SUMMARY_OCT_17_2025.md) | Complete session summary with all fixes, testing, and log access guide | Oct 17, 2025 |
| [**fixes/BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md**](./fixes/BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md) | Initial fix attempts for black screens after background | Oct 17, 2025 |
| [**fixes/VIDEO_MUTE_STATE_FIX.md**](./fixes/VIDEO_MUTE_STATE_FIX.md) | Fix for videos playing unmuted on app startup | Oct 17, 2025 |
| [**fixes/SESSION_SUMMARY_OCT_16_2025.md**](./fixes/SESSION_SUMMARY_OCT_16_2025.md) | Previous session fixes | Oct 16, 2025 |

---

## 📦 Archive

Historical documentation preserved for reference.

### Session Summaries
- [archive/sessions/SESSION_SUMMARY_OCT13_2025.md](./archive/sessions/SESSION_SUMMARY_OCT13_2025.md)
- [archive/sessions/SESSION_SUMMARY_OCT11_2025.md](./archive/sessions/SESSION_SUMMARY_OCT11_2025.md)
- [archive/sessions/SESSION_FIXES_SUMMARY.md](./archive/sessions/SESSION_FIXES_SUMMARY.md)
- [archive/sessions/BUILD_SUCCESS_SUMMARY.md](./archive/sessions/BUILD_SUCCESS_SUMMARY.md)

### Historical Fixes
- [archive/fixes/FULLSCREEN_BLACK_SCREEN_FIX.md](./archive/fixes/FULLSCREEN_BLACK_SCREEN_FIX.md)
- [archive/fixes/FULLSCREEN_MUTE_STATE_FIX.md](./archive/fixes/FULLSCREEN_MUTE_STATE_FIX.md)
- [archive/fixes/MEDIACELL_MUTE_STATE_FIX.md](./archive/fixes/MEDIACELL_MUTE_STATE_FIX.md)
- [archive/fixes/BACKGROUND_VIDEO_RECOVERY_FIX.md](./archive/fixes/BACKGROUND_VIDEO_RECOVERY_FIX.md)
- [archive/fixes/VIDEO_STATE_MANAGEMENT_FIX.md](./archive/fixes/VIDEO_STATE_MANAGEMENT_FIX.md)
- [archive/fixes/TWEETDETAIL_PLAYER_CLEANUP_FIX.md](./archive/fixes/TWEETDETAIL_PLAYER_CLEANUP_FIX.md)
- [archive/fixes/AUDIO_CALL_COMPATIBILITY_FIX.md](./archive/fixes/AUDIO_CALL_COMPATIBILITY_FIX.md)
- [archive/fixes/SCROLL_PERFORMANCE_FIX.md](./archive/fixes/SCROLL_PERFORMANCE_FIX.md)
- [archive/fixes/LOCAL_HTTP_SERVER_PORT_FIX.md](./archive/fixes/LOCAL_HTTP_SERVER_PORT_FIX.md)
- [archive/fixes/SDWEBIMAGE_WARNINGS_FIX.md](./archive/fixes/SDWEBIMAGE_WARNINGS_FIX.md)

### Old Implementations
- [archive/old-implementations/SIMPLEVIDEOPLAYER_ANALYSIS.md](./archive/old-implementations/SIMPLEVIDEOPLAYER_ANALYSIS.md)
- [archive/old-implementations/PROGRESSIVE_VIDEO_IMPLEMENTATION.md](./archive/old-implementations/PROGRESSIVE_VIDEO_IMPLEMENTATION.md)
- [archive/old-implementations/SEQUENTIAL_VIDEO_PLAYBACK_IMPLEMENTATION.md](./archive/old-implementations/SEQUENTIAL_VIDEO_PLAYBACK_IMPLEMENTATION.md)
- [archive/old-implementations/HLS_LIBX264_ALWAYS.md](./archive/old-implementations/HLS_LIBX264_ALWAYS.md)
- [archive/old-implementations/WORKING_IMPLEMENTATION.md](./archive/old-implementations/WORKING_IMPLEMENTATION.md)

### Code Quality Reports
- [archive/CODE_SMELL_REPORT.md](./archive/CODE_SMELL_REPORT.md)
- [archive/IMPROPER_DELAY_USAGE_REPORT.md](./archive/IMPROPER_DELAY_USAGE_REPORT.md)
- [archive/DEBUG_LOG_CLEANUP_FINAL.md](./archive/DEBUG_LOG_CLEANUP_FINAL.md)

---

## 🚀 Quick Links

### For New Developers
1. Start with [ARCHITECTURE.md](ARCHITECTURE.md) - Understand the app structure
2. Read [FEATURES.md](FEATURES.md) - Know what the app does
3. Check [DEBUG_BUILD_INSTRUCTIONS.md](DEBUG_BUILD_INSTRUCTIONS.md) - Set up your environment

### For Feature Development
- **Upload Features:** [UPLOAD_SYSTEM.md](UPLOAD_SYSTEM.md)
- **Video Features:** [VIDEO_SYSTEM.md](VIDEO_SYSTEM.md)
- **Chat Features:** [CHAT_AND_SEARCH_FEATURES.md](CHAT_AND_SEARCH_FEATURES.md)
- **Comment Features:** [CommentSystemREADME.md](CommentSystemREADME.md)

### For Troubleshooting
- **Upload Issues:** [UPLOAD_SYSTEM.md](UPLOAD_SYSTEM.md) → Error Handling section
- **Video Issues:** [VIDEO_SYSTEM.md](VIDEO_SYSTEM.md) → Known Issues section
- **Network Issues:** [NETWORK_RESILIENCE.md](NETWORK_RESILIENCE.md)

---

## 📊 Documentation Standards

### File Naming
- **Main docs:** `SYSTEM_NAME.md` (all caps)
- **Features:** `FeatureName.md` (PascalCase for complex)
- **Archived:** Keep original names

### Structure
All main documents should include:
1. Overview
2. Architecture/Components
3. Implementation Details
4. Configuration
5. Known Issues
6. Future Improvements

### Status Labels
- ✅ **Production** - Active, tested, in production
- ⚠️ **Partial** - Partially implemented, migration in progress
- 🚧 **WIP** - Work in progress
- ❌ **Deprecated** - No longer used, kept for reference

---

## 🔄 Recent Updates

### October 17, 2025
- ✅ **CRITICAL RESOLVED**: Port-Independent Playlist Caching
  - **Root cause identified**: Cached HLS playlists contained full URLs with port numbers
  - **Solution**: Cache playlists with absolute paths only (no scheme/host/port)
  - **Implementation**: Strip URLs to paths when caching, inject current port when serving
  - **Result**: Videos work reliably after backgrounding regardless of server port
  - **Files**: `LocalHTTPServer.swift` (stripPlaylistToRelativePaths, rewritePlaylistURLs)
- ✅ **CRITICAL**: Fixed videos unmuted on startup
  - Mute-at-inception pattern: `player.isMuted = true` immediately after creation
  - Mode-based unmuting in `configurePlayer()`
- ✅ Verified all fixes on real iPhone device in Release mode
- 📘 **Log Access Documentation**: Updated with correct `idevicesyslog` usage
- 📄 Added [fixes/PORT_INDEPENDENT_PLAYLIST_CACHING_FIX.md](./fixes/PORT_INDEPENDENT_PLAYLIST_CACHING_FIX.md)
- 📄 Added [fixes/SESSION_SUMMARY_OCT_17_2025.md](./fixes/SESSION_SUMMARY_OCT_17_2025.md)
- 📄 Updated [fixes/BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md](./fixes/BACKGROUND_VIDEO_BLACK_SCREEN_FIX.md)
- 📄 Updated [fixes/VIDEO_MUTE_STATE_FIX.md](./fixes/VIDEO_MUTE_STATE_FIX.md)

### October 14, 2025
- ✅ Upload dialog now appears immediately when user taps Publish
- ✅ Consolidated upload documentation into single UPLOAD_SYSTEM.md
- ✅ Consolidated video documentation into single VIDEO_SYSTEM.md
- ✅ Organized archive structure (sessions, fixes, old-implementations)

### October 13, 2025
- ✅ Fixed video upload dialog showing "Uploading image" for videos
- ✅ Simplified upload progress messages
- ✅ Fixed CID vs UUID issue for image attachments

### October 11, 2025
- ✅ Implemented comprehensive upload progress system
- ✅ Added multi-attachment support with sequential upload
- ✅ Implemented background polling for video processing

---

## 📝 Contributing to Documentation

### Adding New Documentation
1. Create file in `/docs/`
2. Use appropriate naming convention
3. Add entry to this INDEX.md
4. Include standard sections

### Updating Existing Documentation
1. Update "Last Updated" date
2. Document changes in "Recent Updates"
3. Update status label if needed

### Archiving Old Documentation
1. Move to appropriate `/docs/archive/` subdirectory
2. Update INDEX.md to reflect archive location
3. Optionally consolidate into main documentation

---

## 💡 Tips

- **Search this index** for keywords to find relevant documentation
- **Check archive** if looking for historical context
- **Main docs are authoritative** - archive is for reference only
- **Keep this index updated** when adding/removing documentation
