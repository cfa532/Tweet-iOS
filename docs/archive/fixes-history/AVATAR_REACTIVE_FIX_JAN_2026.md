# Avatar Reactive Fix - January 2026 (Fundamental Approach)

## Problem Statement

Tweet avatars were not updating promptly when the author (User) object was loaded or updated. The issue occurred when:
1. User data was loaded from cache with valid `baseUrl` and `avatar`
2. User data was refreshed from server (with same values)
3. Avatar never reloaded because no trigger detected the change

## Root Cause - Architectural Issue

The Avatar view was using **imperative state management** instead of being **fully reactive**:

```swift
@ObservedObject var user: User  // ✅ Observes user
@State private var cachedImage: UIImage?  // ❌ Imperative state

// Problem: When user.avatarUrl changes, the view body re-renders
// BUT cachedImage state persists, so old image continues to show
```

### Why Notifications Were a Band-Aid

The previous approach relied on `.userDidUpdate` notifications to manually trigger cache clearing. This was a band-aid because:
1. Notifications are imperative (manual triggering)
2. Required careful coordination of when to post
3. Missed cases where notification wasn't posted
4. Not idiomatic SwiftUI (should use declarative reactivity)

## The Fundamental Fix - Pure SwiftUI Reactivity

### Key Insight

Since `User` has `@Published var avatar` and `@Published var baseUrl`, and the Avatar view has `@ObservedObject var user`, the computed property `user.avatarUrl` **automatically recomputes** when either property changes. We just need to **react to that change**.

### Solution - `.onChange(of: user.avatarUrl)`

Instead of notifications, use SwiftUI's built-in change detection:

```swift
.onChange(of: user.avatarUrl) { oldUrl, newUrl in
    if oldUrl != newUrl {
        // URL changed - clear cache and reload
        cachedImage = nil
        loadFailed = false
        if let newUrl = newUrl {
            loadAvatar(from: newUrl)
        }
    }
}
```

### Additional Fix - Reset State When User Changes

When the Avatar view is recycled to show a different user, reset all state:

```swift
.onChange(of: user.mid) { oldMid, newMid in
    if oldMid != newMid {
        // Viewing different user - reset state
        cachedImage = nil
        loadFailed = false
        if let avatarUrl = user.avatarUrl {
            loadAvatar(from: avatarUrl)
        }
    }
}
```

## How It Works - Complete Flow

### Scenario 1: User Loaded from Cache

```
1. Tweet loads → tweet.author = User.getInstance(mid: "user123")
   ├─ User singleton has: avatar="QmABC...", baseUrl=nil
   └─ user.avatarUrl returns nil

2. Avatar view appears
   ├─ Sees avatarUrl is nil
   ├─ Shows gray placeholder
   └─ Sets currentAvatarUrl = nil

3. User data fetched from server
   ├─ User.baseUrl = "http://192.168.1.10:8080"
   └─ User properties are @Published → triggers SwiftUI update

4. Avatar view's body re-renders (SwiftUI automatic)
   ├─ user.avatarUrl now returns "http://192.168.1.10:8080/ipfs/QmABC..."
   └─ .onChange(of: user.avatarUrl) detects change! ✅

5. .onChange handler executes
   ├─ Clears cachedImage = nil
   ├─ Clears loadFailed = false
   └─ Calls loadAvatar(from: newUrl) ✅

6. Avatar loads and displays! ✅
```

### Scenario 2: Avatar Changed (Profile Update)

```
1. User updates their avatar on server
   └─ New avatar MimeiId: "QmXYZ..."

2. fetchUser() retrieves updated user data
   └─ User.avatar = "QmXYZ..." (triggers @Published)

3. SwiftUI detects @Published change
   └─ Avatar view's body re-renders

4. user.avatarUrl recomputes
   ├─ Old: "http://192.168.1.10:8080/ipfs/QmABC..."
   └─ New: "http://192.168.1.10:8080/ipfs/QmXYZ..."

5. .onChange(of: user.avatarUrl) detects change! ✅
   └─ Loads new avatar ✅
```

### Scenario 3: View Recycled for Different User

```
1. Avatar view showing User A
   └─ cachedImage = User A's avatar

2. View recycled to show User B
   └─ user property changes (SwiftUI reassignment)

3. .onChange(of: user.mid) detects change! ✅
   ├─ Clears cachedImage = nil (removes User A's avatar)
   ├─ Resets loadFailed = false
   └─ Loads User B's avatar ✅
```

## Code Changes

### Avatar.swift

Added state tracking:
```swift
@State private var currentUserId: String = ""
@State private var currentAvatarUrl: String? = nil
```

Added reactive handlers:
```swift
.onChange(of: user.mid) { oldMid, newMid in
    // Reset state when viewing different user
}

.onChange(of: user.avatarUrl) { oldUrl, newUrl in
    // Reload when URL changes (avatar or baseUrl changed)
}
```

## Why This Is Fundamental

### Declarative vs Imperative

**Before (Imperative - Band-Aid):**
```
Manual trigger (notification) → Manual action (clear cache) → Manual load
```

**After (Declarative - Fundamental):**
```
Data changes (@Published) → SwiftUI detects → .onChange reacts
```

### Follows SwiftUI Principles

1. **Single Source of Truth**: `user.avatarUrl` is computed from `@Published` properties
2. **Automatic Propagation**: Changes flow automatically through SwiftUI
3. **Declarative**: We declare what should happen when values change
4. **No Manual Coordination**: Don't need to remember to post notifications

### Eliminates Timing Issues

- No need to worry about when notifications are posted
- No risk of missing a notification
- No race conditions between notification and state updates
- Works for ALL scenarios automatically

## Benefits

1. **Truly Reactive**: Follows SwiftUI's declarative paradigm ✅
2. **Automatic**: No manual notification coordination ✅
3. **Reliable**: Works for all scenarios (cached, fresh, updated) ✅
4. **Maintainable**: Clear cause-and-effect relationships ✅
5. **Performant**: Only reloads when URL actually changes ✅

## Edge Cases Handled

1. **URL changes from nil → valid**: Loads avatar ✅
2. **URL changes from valid → different valid**: Reloads avatar ✅
3. **URL changes from valid → nil**: Clears avatar ✅
4. **User changes**: Resets all state ✅
5. **Same URL (no change)**: Does nothing (efficient) ✅

## Testing

### Test 1: Initial Load
- Start app → avatars should load once users are fetched
- Expected: Gray placeholder → Real avatar

### Test 2: Profile View Navigation
- Tap avatar → view profile → back to tweet list
- Expected: Avatar remains loaded (no flicker)

### Test 3: Avatar Update
- Change avatar in profile → return to tweets
- Expected: New avatar shows everywhere

### Test 4: Cache Scenarios
- Clear memory cache → scroll list
- Expected: Avatars load from disk cache or network

## Related Files

- `/Sources/Features/MediaViews/Avatar.swift` - Primary changes
- No changes needed to `User.swift` or `Tweet.swift`
- Notifications remain as backup (`.appUserReady`, `.avatarDidChange`)

## Future Considerations

This pattern can be extended to other views:
- Any view observing a User can use `.onChange(of: user.property)`
- No need for notifications for most reactive updates
- Notifications remain useful for cross-view coordination (e.g., app lifecycle events)

## Migration from Band-Aid

The notifications in `User.updateUserInstance()` can potentially be removed in the future since:
1. SwiftUI's `@Published` mechanism handles propagation
2. `.onChange(of:)` handles reactive updates
3. Notifications only needed for non-view components

However, keeping them as defensive backup is fine for now.
