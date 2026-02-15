# Avatar Update Notification Fix

**Date:** October 25, 2025  
**Status:** ✅ **FIXED**  
**Priority:** 🔴 **CRITICAL**

---

## Problem

When user changed their avatar:
- ✅ Backend updated successfully
- ✅ Cache cleared
- ✅ `appUser.avatar` updated
- ❌ **Avatar on ProfileEditView didn't update**
- ❌ **Avatar on AppHeaderView didn't update**
- ❌ **Avatars in tweet list didn't update**

Only updated after full app restart.

### Root Cause

SwiftUI's `@Published` observation wasn't triggering `.onChange(of: user.avatar)` reliably for Avatar components. The User singleton pattern worked, but change detection failed.

---

## Solution

Added a **notification broadcast system** to force all Avatar components to reload when avatar changes.

### Implementation

#### 1. Define Notification (NotificationNames.swift)

```swift
extension Notification.Name {
    static let avatarDidChange = Notification.Name("avatarDidChange")
}
```

#### 2. Post Notification on Avatar Upload (ProfileEditView.swift, lines 145-149)

```swift
// After updating appUser.avatar
NotificationCenter.default.post(
    name: .avatarDidChange, 
    object: nil, 
    userInfo: ["userId": hproseInstance.appUser.mid, "newAvatar": uploaded.mid]
)
```

#### 3. Listen to Notification (Avatar.swift, lines 80-97)

```swift
.onReceive(NotificationCenter.default.publisher(for: .avatarDidChange)) { notification in
    if let userId = notification.userInfo?["userId"] as? String, userId == user.mid {
        // Only reload if not already loading (prevent infinite loop)
        guard !isLoading else { return }
        
        cachedImage = nil
        loadFailed = false
        if let avatarUrl = user.avatarUrl {
            loadAvatar(from: avatarUrl)
        }
    }
}
```

#### 4. Force ProfileEditView Avatar Update (ProfileEditView.swift)

```swift
@State private var avatarUpdateTrigger = 0

// In avatar upload handler:
avatarUpdateTrigger += 1

// In Avatar view:
Avatar(user: hproseInstance.appUser, size: 80)
    .id("profile_avatar_\(avatarUpdateTrigger)")
```

---

## How It Works

### Event Flow

```
1. User uploads new avatar
   ↓
2. Upload to IPFS → "QmNEW..."
   ↓
3. Clear old avatar cache (ImageCacheManager.clearCache)
   ↓
4. Update appUser.avatar = "QmNEW..."
   ↓
5. avatarUpdateTrigger += 1 (ProfileEditView's avatar recreates immediately)
   ↓
6. Post .avatarDidChange notification
   ↓
7. ALL Avatar components receive notification
   ↓
8. Each Avatar (if matching userId):
   ├─ Check if not already loading (prevent loop)
   ├─ Clear cachedImage
   ├─ Call loadAvatar()
   └─ Load new avatar from network
   ↓
✅ All avatars update across entire app!
```

### Infinite Loop Prevention

**Problem discovered during testing:**
- Notification triggers loadAvatar()
- Avatar sets `isLoading = true`
- But notification handler was resetting `isLoading = false`
- This caused infinite loop of reload attempts

**Fix:**
```swift
guard !isLoading else {
    NSLog("DEBUG: [Avatar] Already loading, skipping notification reload")
    return
}
```

Only reload if not currently loading.

---

## Why @Published Wasn't Enough

**Theory:** `@Published` should notify all `@ObservedObject` views automatically

**Reality in this app:**
- User singleton pattern works correctly
- `@Published var avatar` is properly defined
- But SwiftUI's change detection was flaky
- `.onChange(of: user.avatar)` didn't always fire

**Why:**
- SwiftUI might batch updates
- Views might be off-screen and skip updates
- Navigation stack complexity
- Timing of when views observe changes

**Solution:** Explicit notification ensures **all** Avatar components get the update, regardless of SwiftUI's observation behavior.

---

## Comparison with Android

Android version (working correctly):

```kotlin
// Update BOTH appUser AND ViewModel's StateFlow
appUser = appUser.copy(avatar = avatar)
_user.value = user.value.copy(avatar = avatar)  // StateFlow update
```

**Key difference:**
- Android explicitly updates `_user.value` (StateFlow)
- ALL UI components use `user.collectAsState()`
- Guaranteed update propagation

**iOS approach:**
- Relies on User singleton `@Published` (less reliable)
- Added notification as **guarantee** mechanism
- Hybrid: @Published + Notification = bulletproof

---

## Files Modified

1. **Sources/Core/NotificationNames.swift**
   - Added `.avatarDidChange` notification definition

2. **Sources/Screens/ProfileEditView.swift**
   - Lines 42: Added `avatarUpdateTrigger` state
   - Lines 66: Added `.id("profile_avatar_\(avatarUpdateTrigger)")`
   - Lines 141-150: Post notification after avatar update

3. **Sources/Features/MediaViews/Avatar.swift**
   - Lines 80-97: Added `.onReceive` handler with loop prevention
   - Lines 93-103: Added comprehensive logging to `loadAvatar()`

4. **Sources/Core/ImageCacheManager.swift**
   - Lines 125-138: Added `removeImage()` method (from earlier fix)

---

## Testing Results

✅ **ProfileEditView avatar:** Updates immediately  
✅ **AppHeaderView avatar:** Updates immediately  
✅ **Tweet list avatars:** Update immediately  
✅ **No infinite loop:** `isLoading` guard prevents it  
✅ **Cache cleared:** Old avatar removed, no stale images  

---

## Lessons Learned

### 1. Don't Rely Solely on @Published

SwiftUI's automatic observation is great in theory, but add **explicit** mechanisms for critical updates.

### 2. Notification Pattern for Broadcast Updates

When multiple components need to react to same change:
- @Published = best effort
- Notification = guarantee

### 3. Guard Against Infinite Loops

When notifications trigger reloads, always check state before acting:
```swift
guard !isLoading else { return }
```

### 4. Learn from Other Platforms

Android's explicit `StateFlow` update pattern is more predictable than iOS's implicit `@Published`.

---

## Status

✅ **Implementation:** Complete  
✅ **Testing:** Verified working  
✅ **Infinite loop:** Fixed  
✅ **All views update:** Confirmed  

**Avatar updates now work consistently across the entire app!**

