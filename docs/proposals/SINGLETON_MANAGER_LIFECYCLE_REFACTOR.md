# Singleton Video Manager Lifecycle Refactor

## Current Problems

### 1. Always-On Lifecycle Observers

**Issue:** Singleton managers (`FullScreenVideoManager`, `DetailVideoManager`) register app lifecycle observers even when inactive (no fullscreen/detail view active).

**Impact:**
- Run unnecessary health checks for non-existent videos
- Post global notifications affecting unrelated MediaCell videos
- Waste resources on inactive managers

### 2. Global Broadcast Notifications

**Issue:** `reloadVisibleVideosOnly` is broadcast globally without context about which videos/managers need reloading.

**Impact:**
- MediaCell videos reload when fullscreen/detail managers have issues
- Tight coupling between unrelated video contexts
- No way to isolate manager-specific recovery

### 3. Cleanup Race Conditions

**Issue:** Delayed cleanup (300ms) + delayed health check (1000ms) = overlapping operations.

**Impact:**
- Health check finds "broken" players mid-cleanup
- Posts notifications for players that are being properly cleaned up
- Unnecessary recovery cycles

## Proposed Solution

### Option A: Conditional Lifecycle Registration (Minimal Change)

**Only register lifecycle observers when manager is active:**

```swift
@MainActor
class FullScreenVideoManager: ObservableObject {
    private var lifecycleObservers: [NSObjectProtocol] = []
    
    func activateForFullscreen() {
        guard lifecycleObservers.isEmpty else { return }
        
        // Register lifecycle observers ONLY when fullscreen is active
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, ...
            )
        )
    }
    
    func deactivate() {
        // Remove observers when fullscreen dismissed
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        
        // Clear player immediately (no delay)
        clearSingletonPlayer()
    }
}
```

**Benefits:**
- Managers only run lifecycle when actually managing videos
- No interference with MediaCell videos
- Clean separation of concerns

**Changes Required:**
- `MediaBrowserView.onAppear` → call `FullScreenVideoManager.shared.activateForFullscreen()`
- `MediaBrowserView.onDisappear` → call `FullScreenVideoManager.shared.deactivate()`
- `TweetDetailView` → similar for `DetailVideoManager`

### Option B: Scoped Notifications (Medium Change)

**Add context to notifications instead of global broadcast:**

```swift
// Define scoped notification types
extension Notification.Name {
    static let reloadMediaCellVideos = Notification.Name("reloadMediaCellVideos")
    static let reloadFullscreenVideo = Notification.Name("reloadFullscreenVideo")
    static let reloadDetailVideo = Notification.Name("reloadDetailVideo")
}

// Singleton managers post scoped notifications
class FullScreenVideoManager {
    func handleForegroundRecovery() {
        // Only post notification for fullscreen context
        NotificationCenter.default.post(name: .reloadFullscreenVideo, object: nil)
    }
}

// SimpleVideoPlayer listens to relevant notifications
SimpleVideoPlayer {
    .onReceive(NotificationCenter.default.publisher(for: mode == .mediaCell ? .reloadMediaCellVideos : .reloadFullscreenVideo)) { _ in
        handleReload()
    }
}
```

**Benefits:**
- Each context manages its own recovery
- No cross-contamination
- Clear responsibility boundaries

**Drawbacks:**
- Requires updating notification handlers across codebase
- More complex notification setup

### Option C: Direct Manager Control (Ideal, Large Change)

**Remove notifications entirely - each manager directly controls its videos:**

```swift
@MainActor
class FullScreenVideoManager {
    private weak var activePlayerView: SimpleVideoPlayer?
    
    func registerPlayer(_ player: SimpleVideoPlayer) {
        activePlayerView = player
    }
    
    func handleForegroundRecovery() {
        // Directly tell the active player to reload
        activePlayerView?.reloadForForegroundRecovery()
        
        // No global notifications needed
    }
}
```

**Benefits:**
- Direct control, no broadcast side effects
- Clear ownership (manager owns its player)
- No global state pollution

**Drawbacks:**
- Significant refactoring required
- Changes player-manager relationship
- More invasive change

## Recommended Approach

**Start with Option A (Conditional Lifecycle Registration):**

### Phase 1: Immediate Fix (Minimal Risk)

1. **Only register lifecycle observers when manager is active**
2. **Remove delayed health checks** - rely on immediate cleanup
3. **Remove `reloadVisibleVideosOnly` posts from singleton managers**

```swift
// FullScreenVideoManager
func activateForFullscreen() {
    // Register lifecycle observers
    setupAppLifecycleNotifications()
}

func deactivate() {
    // Unregister lifecycle observers
    teardownAppLifecycleNotifications()
    
    // Clear player immediately
    clearSingletonPlayer()
}

// Remove delayed health check entirely
// handleAppDidBecomeActive() {
//     // DON'T schedule delayed check
// }
```

### Phase 2: Scoped Notifications (Follow-up)

After Phase 1 is stable, migrate to scoped notifications (Option B) to further isolate contexts.

## Implementation Steps

### Step 1: Add Activation/Deactivation Methods

**FullScreenVideoManager:**
```swift
func activateForFullscreen() {
    guard lifecycleObservers.isEmpty else { return }
    setupAppLifecycleNotifications()
}

func deactivate() {
    teardownAppLifecycleNotifications()
    clearSingletonPlayer()
}

private func teardownAppLifecycleNotifications() {
    lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    lifecycleObservers.removeAll()
}
```

**DetailVideoManager:**
```swift
func activateForDetail() {
    guard lifecycleObservers.isEmpty else { return }
    setupAppLifecycleNotifications()
    beginDetailViewSession()
}

func deactivate() {
    teardownAppLifecycleNotifications()
    endDetailViewSession()
}
```

### Step 2: Update View Lifecycle

**MediaBrowserView:**
```swift
.onAppear {
    FullScreenVideoManager.shared.activateForFullscreen()
    setupFullScreenManager()
    // ...
}
.onDisappear {
    FullScreenVideoManager.shared.deactivate()
    // DON'T post reloadVisibleVideosOnly here either
}
```

**TweetDetailView:**
```swift
.onAppear {
    DetailVideoManager.shared.activateForDetail()
}
.onDisappear {
    DetailVideoManager.shared.deactivate()
}
```

### Step 3: Remove Delayed Health Checks

```swift
// REMOVE this entire block from handleAppDidBecomeActive
// Task { @MainActor [weak self] in
//     try? await Task.sleep(nanoseconds: 1_000_000_000)
//     if self.isPlayerBroken() {
//         self.clearBrokenPlayer()
//         NotificationCenter.default.post(name: .reloadVisibleVideosOnly, object: nil)
//     }
// }
```

### Step 4: Remove Global Notifications from Singleton Managers

Singleton managers should NOT post `reloadVisibleVideosOnly`. They manage their own players directly.

## Benefits of Recommended Approach

1. **No Interference:** Inactive managers don't run lifecycle checks
2. **Clean Separation:** Each context manages itself
3. **Predictable:** Lifecycle tied to view lifecycle
4. **Efficient:** No unnecessary health checks
5. **Minimal Risk:** Small, incremental changes

## Testing Strategy

1. **Test fullscreen flow:**
   - Open fullscreen → manager activates
   - Background app → only fullscreen manager recovers
   - Return to foreground → only fullscreen video reloads
   - Dismiss fullscreen → manager deactivates, MediaCell unaffected

2. **Test detail view flow:**
   - Similar to fullscreen

3. **Test MediaCell flow:**
   - Background → only MediaCell videos affected
   - No interference from singleton managers

4. **Test transitions:**
   - MediaCell → Fullscreen → Background → Foreground → Dismiss
   - Ensure no duplicate notifications or recovery cycles

## Migration Path

1. **Immediate (Today):** Remove delayed health check notifications (current band-aid fix)
2. **Short-term (This Week):** Implement activation/deactivation (Option A)
3. **Medium-term (Next Sprint):** Migrate to scoped notifications (Option B)
4. **Long-term (Consider):** Direct manager control (Option C) if notification complexity grows

## Conclusion

The current architecture has singleton managers "always listening" even when inactive, leading to:
- Unnecessary health checks
- Global notification interference  
- Cleanup race conditions

**Solution:** Tie manager lifecycle to view lifecycle - only activate when views are active, deactivate when views dismiss. This eliminates interference and creates clean separation of concerns.
