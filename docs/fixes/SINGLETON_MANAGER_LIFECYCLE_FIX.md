# Singleton Manager Lifecycle Fix

## Problem

Singleton video managers (`FullScreenVideoManager`, `DetailVideoManager`) were running lifecycle checks even when inactive, causing interference with MediaCell videos.

### Symptoms

1. **Spinner on first video after foreground return**
2. **Second video plays while first shows spinner**
3. **Multiple recovery cycles** (delayed health checks)
4. **Global notifications affecting unrelated videos**

### Root Cause

**Managers always listened to app lifecycle events:**

```swift
// OLD DESIGN (BROKEN)
class FullScreenVideoManager {
    private init() {
        setupAppLifecycleNotifications()  // ❌ Always listening!
    }
    
    func handleAppDidBecomeActive() {
        // Runs even when NO fullscreen view is open
        if isPlayerBroken() {
            clearBrokenPlayer()
            // Posts global notification affecting ALL videos
            NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
        }
    }
}
```

**What happened:**
1. User opens fullscreen earlier in session → manager creates player
2. User dismisses fullscreen → player cleared, but manager still listening
3. App backgrounds → manager saves state for non-existent video
4. App foregrounds → manager finds "broken" player (stale from previous usage)
5. Manager posts `reloadVisibleVideosOnly` → **affects MediaCell videos!**
6. MediaCell videos reload unnecessarily → spinners, duplicate recovery

**Design Flaw:** Managers had "always-on" lifecycle observers, causing:
- Unnecessary health checks when inactive
- Stale player state between sessions
- Global notification interference
- Tight coupling between unrelated video contexts

## Solution: Tie Manager Lifecycle to View Lifecycle

**Only activate managers when their views are active:**

### Architecture Changes

#### 1. Add Activation/Deactivation to Managers

**FullScreenVideoManager:**
```swift
class FullScreenVideoManager {
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isActive: Bool = false
    
    private init() {
        // DON'T setup lifecycle notifications in init
    }
    
    func activateForFullscreen() {
        guard !isActive else { return }
        isActive = true
        setupAppLifecycleNotifications()  // Register observers
        print("🎬 [FullScreenVideoManager] Activated")
    }
    
    func deactivate() {
        guard isActive else { return }
        isActive = false
        teardownAppLifecycleNotifications()  // Unregister observers
        clearSingletonPlayer()
        print("🎬 [FullScreenVideoManager] Deactivated")
    }
    
    private func teardownAppLifecycleNotifications() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }
}
```

**DetailVideoManager:** (Same pattern)

#### 2. Remove Delayed Health Checks

**OLD (PROBLEMATIC):**
```swift
func handleAppDidBecomeActive() {
    // Immediate check
    if getPlayer() != nil && isPlayerBroken() {
        clearBrokenPlayer()
        NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
    }
    
    // Delayed check (1 second later)
    Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if isPlayerBroken() {
            clearBrokenPlayer()
            NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)  // ❌ Interference!
        }
    }
}
```

**NEW (CLEAN):**
```swift
func handleAppDidBecomeActive() {
    if !hasRecoveredThisCycle {
        recoverFromBackground()
    }
    // NO delayed health checks
    // If manager is active, view handles recovery
    // If manager is inactive, nothing to check
}
```

#### 3. Update View Lifecycle

**MediaBrowserView:**
```swift
.onAppear {
    FullScreenVideoManager.shared.activateForFullscreen()  // ✅ Activate
    setupFullScreenManager()
    OverlayVisibilityCoordinator.shared.beginOverlay(...)
}
.onDisappear {
    FullScreenVideoManager.shared.deactivate()  // ✅ Deactivate
    OverlayVisibilityCoordinator.shared.endOverlay(...)
    // DON'T post reloadVisibleVideosOnly
}
```

**TweetDetailView:**
```swift
.onAppear {
    NavigationStateManager.shared.setDetailViewActive(true)
    DetailVideoManager.shared.activateForDetail()  // ✅ Activate
}
.onDisappear {
    NavigationStateManager.shared.setDetailViewActive(false)
    DetailVideoManager.shared.deactivate()  // ✅ Deactivate
}
```

**CommentDetailView:** (Same as TweetDetailView)

## Why This Works

### Before Fix

```
App Launch:
    FullScreenVideoManager init → setupAppLifecycleNotifications() ❌
    DetailVideoManager init → setupAppLifecycleNotifications() ❌
    (Managers listening even though no views active)

User opens fullscreen → plays video → dismisses:
    clearSingletonPlayer() (player cleared)
    But manager still listening to lifecycle! ❌

App backgrounds then foregrounds:
    FullScreenVideoManager: "I have stale player, it's broken!"
    Posts reloadVisibleVideosOnly → affects MediaCell videos ❌
    
    MediaCell videos: "Reload? But we're fine!"
    Recreate players → spinners → interference ❌
```

### After Fix

```
App Launch:
    FullScreenVideoManager init (NO lifecycle registration) ✅
    DetailVideoManager init (NO lifecycle registration) ✅

User opens fullscreen:
    MediaBrowserView.onAppear → activateForFullscreen() ✅
    Manager registers lifecycle observers ✅
    Plays video

User dismisses fullscreen:
    MediaBrowserView.onDisappear → deactivate() ✅
    Manager unregisters lifecycle observers ✅
    Clears player ✅
    (No stale state left behind)

App backgrounds then foregrounds:
    FullScreenVideoManager: (inactive, not listening) ✅
    DetailVideoManager: (inactive, not listening) ✅
    MediaCell videos: recover normally ✅
    No interference! ✅
```

## Benefits

### 1. Clean Separation of Concerns
- Each manager only runs when actively managing videos
- No cross-contamination between video contexts
- MediaCell, fullscreen, and detail views operate independently

### 2. No Stale State
- Managers deactivate immediately when views dismiss
- Player cleared synchronously with observer teardown
- No lingering "broken" players to trigger health checks

### 3. Predictable Lifecycle
- Manager lifecycle tied to view lifecycle (SwiftUI pattern)
- Activation = view appears, deactivation = view disappears
- Easy to reason about when managers are active

### 4. Performance Benefits
- No unnecessary health checks for inactive managers
- No global notification broadcasts when not needed
- Reduced overhead during app lifecycle transitions

### 5. Maintainability
- Clear ownership: view controls manager activation
- Single responsibility: managers only manage their own videos
- Fewer edge cases and race conditions

## Files Changed

### Core Changes

1. **Sources/Core/SingletonVideoManagers.swift**
   - Added `isActive` flag to track activation state
   - Added `lifecycleObservers` array to store observer tokens
   - Added `activateForFullscreen()` / `activateForDetail()` methods
   - Added `deactivate()` method
   - Added `teardownAppLifecycleNotifications()` method
   - Updated `setupAppLifecycleNotifications()` to return observer tokens
   - Removed delayed health checks from `handleAppDidBecomeActive()`
   - Removed `reloadVisibleVideosOnly` notification posts

### View Changes

2. **Sources/Features/MediaViews/MediaBrowserView.swift**
   - Added `activateForFullscreen()` call in `onAppear`
   - Changed `onDisappear` to call `deactivate()` instead of `clearSingletonPlayer()`
   - Removed `reloadVisibleVideosOnly` notification post

3. **Sources/Tweet/TweetDetailView.swift**
   - Changed `beginDetailViewSession()` to `activateForDetail()` in `onAppear`
   - Changed `endDetailViewSession()` to `deactivate()` in `onDisappear`

4. **Sources/Tweet/CommentDetailView.swift**
   - Added `activateForDetail()` call in `onAppear`
   - Added `deactivate()` call in `onDisappear`

## Testing

### Test Case 1: Short Background (5s)

**Before:**
```
App backgrounds → foregrounds
FullScreenVideoManager: "Player broken!"
Posts reloadVisibleVideosOnly
MediaCell videos reload → spinner on first video
Second video plays (partially visible)
```

**After:**
```
App backgrounds → foregrounds
FullScreenVideoManager: (inactive, silent) ✅
MediaCell videos: normal recovery ✅
First video plays immediately ✅
```

### Test Case 2: Fullscreen During Background

**Before:**
```
Open fullscreen → background → foreground
Manager posts reloadVisibleVideosOnly
Affects MediaCell even though fullscreen is active
Duplicate recovery cycles
```

**After:**
```
Open fullscreen → activates manager ✅
Background → manager handles own recovery ✅
Foreground → manager recovers own player ✅
No interference with MediaCell ✅
```

### Test Case 3: Detail View Navigation

**Before:**
```
Open detail → open quoted detail → background → foreground
Both detail view sessions trigger health checks
Multiple notifications posted
```

**After:**
```
Open detail → activates manager ✅
Open quoted detail → same manager (session count) ✅
Background → manager handles own recovery ✅
Dismiss details → deactivates manager ✅
Clean lifecycle ✅
```

## Migration Notes

### For Future Managers

If adding new singleton video managers:

1. **Don't register lifecycle in init:**
   ```swift
   private init() {
       // DON'T: setupAppLifecycleNotifications()
   }
   ```

2. **Add activation/deactivation:**
   ```swift
   func activate() {
       guard !isActive else { return }
       isActive = true
       setupAppLifecycleNotifications()
   }
   
   func deactivate() {
       guard isActive else { return }
       isActive = false
       teardownAppLifecycleNotifications()
   }
   ```

3. **Call from view lifecycle:**
   ```swift
   .onAppear { Manager.shared.activate() }
   .onDisappear { Manager.shared.deactivate() }
   ```

### Backward Compatibility

This change is **backward compatible** because:
- Old code that doesn't call activate/deactivate won't break
- Managers just won't register lifecycle observers
- Views that manage their own players directly are unaffected

## Related Issues

This fix also resolves:
- Race conditions between manager health checks and view lifecycle
- Duplicate recovery cycles after foreground return
- Unnecessary video player recreation
- Global notification side effects

## Conclusion

By tying singleton manager lifecycle to view lifecycle, we achieve:
- **Clean architecture:** Managers only active when needed
- **No interference:** Each context manages itself independently
- **Predictable behavior:** Lifecycle matches SwiftUI patterns
- **Better performance:** No unnecessary checks or notifications

This is the **proper architectural solution**, not a band-aid.

## Date

January 9, 2026
