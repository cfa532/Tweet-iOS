# Sequential Video Playback Documentation Index

## Main Documentation

**📘 [SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md](./SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md)**  
**This is the main, comprehensive document** covering all aspects of sequential video playback implementation, fixes, and architecture.

## Latest Fixes (December 7, 2025)

**📗 [SEQUENTIAL_VIDEO_DUPLICATE_FIXES_DEC7.md](./SEQUENTIAL_VIDEO_DUPLICATE_FIXES_DEC7.md)**  
Details the fixes for:
- Both videos playing simultaneously
- Duplicate `handleVideoFinished` callbacks

## Deprecated Documents

The following documents have been consolidated into `SEQUENTIAL_VIDEO_PLAYBACK_COMPLETE.md`:

- `SEQUENTIAL_VIDEO_COMPLETE_FIX_SUMMARY.md` - Original summary (now deprecated)
- `SEQUENTIAL_VIDEO_SCROLLBACK_FIX_DEC7.md` - Scrollback fix details (now deprecated)
- `UNIFIED_SEQUENTIAL_VIDEO_LOGIC.md` - Unified logic details (now deprecated)
- `FIXED_MISSING_OBSERVERS_ON_CACHED_PLAYERS.md` - Observer fix details (now deprecated)
- `FIXED_MEDIAGRID_STATE_INTERFERENCE.md` - State interference fix (now deprecated)
- `REMOVED_ISSEQUENTIALPLAYBACKENABLED_FLAG.md` - Flag removal details (now deprecated)

These documents are kept for historical reference but should not be used for implementation guidance.

## Quick Reference

### Key Concepts
- **VideoManager**: Singleton managing sequential playback state
- **MediaGridView**: Orchestrates playback setup and lifecycle
- **SimpleVideoPlayer**: Individual video player with completion observers
- **Observer Setup**: Critical for detecting video completion
- **State Persistence**: Per-tweet saved state for resume functionality

### Common Issues
- **Both videos playing**: Check VideoManager approval in KVO handlers
- **Second video not playing**: Check observer attachment logs
- **Duplicate callbacks**: Check guard in `handleVideoFinished()`
- **State not saved**: Check `onDisappear` logic

### Debugging
Look for these log prefixes:
- `[MediaGridView]` - Grid lifecycle
- `[VideoManager]` - State management
- `[OBSERVER SETUP]` - Observer attachment
- `[VIDEO FINISHED]` - Completion callbacks
- `[VIDEO CACHE]` - Player reuse
- `[VIDEO READY]` - KVO handlers

## Related Documentation

- `VideoPlaybackAlgorithm.md` - General video playback algorithm
- `VIDEO_PLAYER_ARCHITECTURE.md` - Video player architecture overview
