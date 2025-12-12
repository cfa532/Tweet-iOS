# Video Playback Resume Fix - Implementation Summary

## Problem
Videos were restarting from the beginning every time the screen was locked/unlocked, even though the player was saving state. The issue was that saved state was lost when the player was recreated.

## Solution
Implemented a **persistent video state manager** that survives player recreation, combined with proper cleanup when navigating away.

## Changes Made

### 1. **PersistentVideoStateManager.swift** (NEW)
- Stores video playback state (position, playing status, context) that survives player recreation
- Automatically expires stale states after 1 hour
- Context-aware: separates states for detail view vs fullscreen

### 2. **SingletonVideoManagers.swift** (UPDATED)
- `handleAppWillResignActive()`: Now saves state to persistent storage in addition to local storage
- `DetailVideoManager.setCurrentVideo()`: Restores saved position when creating/loading video
- `DetailVideoManager.clearCurrentVideo()`: Saves state before clearing (for navigation away)
- `FullScreenVideoManager.clearSingletonPlayer()`: Saves state before clearing

### 3. **TweetDetailView.swift** (UPDATED)
- `.onDisappear`: Now immediately calls `DetailVideoManager.shared.clearCurrentVideo()`
- This ensures video stops playing when user navigates away from detail view
- State is saved before stopping, so returning restores position

### 4. **AppDelegate.swift** (UPDATED)
- `handleAppDidBecomeActive()`: Clears stale video states (>1 hour old)
- Prevents memory buildup from old states

### 5. **VideoPlaybackSettings.swift** (NEW - Optional)
- Future-proofing for user preference to continue playback on screen lock
- Currently disabled (always pauses)

## How It Works

### Screen Lock/Unlock Flow:
1. **Screen locks** → `handleAppWillResignActive()`
   - Saves current time + playing status to `PersistentVideoStateManager`
   - Pauses player

2. **Screen unlocks** → `handleAppDidBecomeActive()`
   - If player is healthy: seeks to saved position, resumes if was playing
   - If player is broken: clears player, lets view recreate it

3. **Player recreated** → `setCurrentVideo()`
   - Checks `PersistentVideoStateManager` for saved state
   - If found: seeks to saved position, resumes if was playing
   - If not found: starts from beginning (new video)

### Navigation Away Flow:
1. **User navigates away** → `TweetDetailView.onDisappear`
   - Calls `clearCurrentVideo()` immediately
   - Saves current position to `PersistentVideoStateManager`
   - Stops playback completely

2. **User returns** → `TweetDetailView` recreates
   - New `DetailMediaCell` calls `setCurrentVideo()`
   - Restores saved position from `PersistentVideoStateManager`
   - Resumes from where user left off

### Fullscreen Flow:
- Same as detail view but uses `.fullScreen` context
- Separate states prevent interference between detail and fullscreen

## Key Features

✅ Videos resume from saved position after screen lock/unlock
✅ Position persists even if player is recreated
✅ Videos stop immediately when navigating away
✅ Position restored when returning to video
✅ Separate states for detail view vs fullscreen
✅ Automatic cleanup of stale states (>1 hour)
✅ Context-aware: only restores if same screen
✅ Expires old states to prevent memory buildup

## Testing Checklist

- [ ] Lock screen while video playing in detail view → unlock → should resume from same position
- [ ] Lock screen while video playing in fullscreen → unlock → should resume from same position
- [ ] Navigate away from detail view → return → should resume from where left off
- [ ] Exit fullscreen → reopen → should resume from where left off
- [ ] Long screen lock (>5 min) causing player recreation → should still resume correctly
- [ ] Navigate between multiple videos → each should remember its own position
- [ ] Leave app idle for >1 hour → old states should be cleaned up

## Future Enhancements

If you want to add "continue playing on screen lock" feature:
1. Enable background audio in Xcode capabilities
2. Modify `handleAppWillResignActive()` to check `VideoPlaybackSettings.shared.continuePlaybackOnScreenLock`
3. Only pause if setting is false
4. Still pause on true backgrounding (`handleAppDidEnterBackground`)

## Notes

- State is saved for **5 minutes** - after that, video starts from beginning (prevents stale state)
- States are **context-aware** - detail view states won't apply to fullscreen and vice versa
- Old states are **auto-cleaned** after 1 hour to prevent memory buildup
- Works with **both** regular videos and HLS videos
- Handles **player recreation** gracefully (e.g., after long background)
