# MuteState Startup Race Condition Fix

**Date**: October 16, 2025  
**Issue**: Videos in MediaCell play unmuted for ~1 second at app startup, even though global MuteState is set to muted

## Problem Description

When the app starts, videos in MediaCell would briefly play **unmuted** even though the user's saved preference was **muted**. This caused an unexpected audio blast for ~1 second before the correct mute state was applied.

### Symptoms
- Videos play with audio at app startup
- After 1 second, audio stops and videos become muted
- Happens consistently on cold app launch
- Issue only affects first few videos loaded
- After initial load, mute state works correctly

## Root Cause

**Race condition between MuteState initialization and PreferenceHelper availability:**

### Initialization Timeline (Before Fix)

```
1. AppDelegate.didFinishLaunchingWithOptions()
2. TweetApp.initialize() starts (async)
3. MediaCell renders (UI shows cached content immediately)
4. MediaCell accesses MuteState.shared
5. MuteState.init() calls refreshFromPreferences()
6. Tries to read: HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false
   ❌ preferenceHelper is nil (not initialized yet)
   ❌ Returns default: false (unmuted)
7. Videos play unmuted
8. Later: TweetApp sets HproseInstance.shared.preferenceHelper
9. Later: TweetApp.initialize() calls MuteState.shared.refreshFromPreferences()
   ✅ Now reads correct value: true (muted)
10. Videos become muted (too late!)
```

### The Three Issues

1. **Default Value Mismatch**
   - Line 12: `@Published var isMuted: Bool = false`
   - PreferenceHelper default: `true` (muted)
   - Result: MuteState defaults to unmuted, PreferenceHelper defaults to muted

2. **Fallback Logic Broken**
   - Line 55: `HproseInstance.shared.preferenceHelper?.getSpeakerMute() ?? false`
   - When `preferenceHelper` is nil, returns `false` (unmuted)
   - Doesn't match PreferenceHelper's default behavior

3. **Timing Race**
   - MuteState can be accessed before PreferenceHelper is initialized
   - No synchronization between initialization order
   - UserDefaults is always available but wasn't used as fallback

## Solution Implemented

### 1. Change Default Value to Match PreferenceHelper

**File**: `Sources/Utils/MuteState.swift`

```swift
// Before
@Published var isMuted: Bool = false { // Default to unmuted

// After
@Published var isMuted: Bool = true { // Default to muted (matches PreferenceHelper default)
```

**Impact**: If all else fails, default to muted (safe default that prevents unexpected audio).

### 2. Add UserDefaults Fallback with Correct Default Logic

**File**: `Sources/Utils/MuteState.swift`

```swift
func refreshFromPreferences() {
    let savedMuteState: Bool
    if let helper = HproseInstance.shared.preferenceHelper {
        // Use PreferenceHelper if available
        savedMuteState = helper.getSpeakerMute()
    } else {
        // Fallback: Read directly from UserDefaults if PreferenceHelper not ready
        // IMPORTANT: Match PreferenceHelper's default logic (default to muted if not set)
        if UserDefaults.standard.object(forKey: "speakerMuted") == nil {
            savedMuteState = true  // Default to muted
        } else {
            savedMuteState = UserDefaults.standard.bool(forKey: "speakerMuted")
        }
    }
    
    if self.isMuted != savedMuteState {
        self.isMuted = savedMuteState
    }
}
```

**Key Changes**:
- Check if `preferenceHelper` exists before using it
- If not available, read directly from UserDefaults
- Match PreferenceHelper's default logic: if key doesn't exist, default to `true` (muted)
- UserDefaults is always available, even before PreferenceHelper is initialized

### 3. Initialize MuteState Early in AppDelegate

**File**: `Sources/App/AppDelegate.swift`

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    // ... other initialization
    
    // CRITICAL: Initialize MuteState early to ensure it's ready before videos load
    // This prevents race condition where videos play unmuted at app startup
    _ = MuteState.shared
    print("[AppDelegate] MuteState initialized early")
    
    // ... rest of initialization
}
```

**Impact**: 
- MuteState is initialized during app launch, not lazily
- Reads correct value from UserDefaults immediately
- Ready before any MediaCells render

### 4. Apply Same Logic to userDefaultsDidChange

**File**: `Sources/Utils/MuteState.swift`

```swift
@objc private func userDefaultsDidChange() {
    let newMuteState: Bool
    if let helper = HproseInstance.shared.preferenceHelper {
        newMuteState = helper.getSpeakerMute()
    } else {
        // Fallback: Read directly from UserDefaults
        if UserDefaults.standard.object(forKey: "speakerMuted") == nil {
            newMuteState = true  // Default to muted
        } else {
            newMuteState = UserDefaults.standard.bool(forKey: "speakerMuted")
        }
    }
    
    if self.isMuted != newMuteState {
        DispatchQueue.main.async {
            self.isMuted = newMuteState
        }
    }
}
```

**Impact**: Ensures consistency across all code paths.

## New Initialization Timeline (After Fix)

```
1. AppDelegate.didFinishLaunchingWithOptions()
2. Line 30: _ = MuteState.shared (explicit initialization)
3. MuteState.init() calls refreshFromPreferences()
4. preferenceHelper is nil, so fallback to UserDefaults
5. UserDefaults.standard.object(forKey: "speakerMuted") is checked:
   - If nil → savedMuteState = true (muted) ✅
   - If exists → Read actual value ✅
6. isMuted is set to correct value immediately
7. MediaCell renders later
8. MediaCell accesses MuteState.shared (already initialized)
9. Videos respect correct mute state from the start ✅
```

## Why This Works

### Three Layers of Defense

1. **Default value**: `isMuted = true` (safe default)
2. **UserDefaults fallback**: Always available, reads correct value
3. **PreferenceHelper**: Once available, takes over as primary source

### No More Race Condition

- MuteState is initialized in `AppDelegate.didFinishLaunchingWithOptions()` (line 30)
- This happens **before** ContentView renders
- UserDefaults is always available (no initialization needed)
- Correct mute state is set before first video loads

## Testing

### Test Case 1: Fresh Install (No Saved Preference)
1. Delete app and reinstall
2. Launch app
3. **Expected**: Videos are muted by default
4. **Actual**: ✅ Videos are muted (default to true)

### Test Case 2: User Has Saved Mute = True
1. User has previously set mute to true
2. Restart app
3. **Expected**: Videos are muted on startup
4. **Actual**: ✅ Videos are muted (reads from UserDefaults)

### Test Case 3: User Has Saved Mute = False
1. User has previously set mute to false
2. Restart app
3. **Expected**: Videos are unmuted on startup
4. **Actual**: ✅ Videos are unmuted (reads from UserDefaults)

### Test Case 4: Cold Launch with Many Videos
1. Force quit app
2. Launch app
3. Scroll through feed with many videos
4. **Expected**: All videos respect mute state from start
5. **Actual**: ✅ No audio blast, all videos muted correctly

## Logs to Verify

### Successful Early Initialization:
```
[AppDelegate] MuteState initialized early
DEBUG: [MUTE STATE] PreferenceHelper not ready, reading directly from UserDefaults: true
DEBUG: [MUTE STATE] Refreshed from preferences: true
```

### Later PreferenceHelper Initialization:
```
DEBUG: [MUTE STATE] Refreshed from preferences: true
```
(No change because UserDefaults already had correct value)

## Files Modified

1. **Sources/Utils/MuteState.swift**
   - Changed default value from `false` to `true`
   - Added UserDefaults fallback in `refreshFromPreferences()`
   - Added UserDefaults fallback in `userDefaultsDidChange()`
   - Matched PreferenceHelper's default logic in fallbacks

2. **Sources/App/AppDelegate.swift**
   - Added early MuteState initialization in `didFinishLaunchingWithOptions()`

## Related Issues

- **MediaCell Mute State Fix** (docs/archive/fixes/MEDIACELL_MUTE_STATE_FIX.md)
  - That fix addressed race conditions in player creation
  - This fix addresses race condition in MuteState initialization
  - Both fixes work together for complete solution

## Impact

- ✅ No more unmuted audio blast at app startup
- ✅ Videos respect mute state from first frame
- ✅ Works even before PreferenceHelper is initialized
- ✅ Consistent behavior across fresh installs and existing users
- ✅ Safer default (muted) prevents unexpected audio

