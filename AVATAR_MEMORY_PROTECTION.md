# Avatar Memory Protection

## Summary
Added protection for avatar images in memory cache to prevent them from being released during cache cleanup operations.

## Problem
When `ImageCacheManager.releasePartialCache()` was called during memory pressure, it would clear ALL images from memory cache, including avatars. This caused:
- Constant avatar re-loading as users scroll
- Poor user experience (flickering avatars)
- Wasted network bandwidth
- Unnecessary disk I/O

## Solution
Implemented selective memory cache clearing that protects avatars:

### 1. Added Cache Key Tracking
```swift
// Track all in-memory cached images
private var memoryCachedKeys: Set<String> = []

// Track avatar cache keys specifically  
private var avatarCacheKeys: Set<String> = []

private let cacheKeysQueue = DispatchQueue(label: "com.tweet.cacheKeys", attributes: .concurrent)
```

### 2. Updated cacheImageInMemory()
Now tracks all cached images and identifies avatars:
```swift
private func cacheImageInMemory(_ image: UIImage, forKey key: String) {
    // ... existing code ...
    
    // Track this key for selective memory cache release
    cacheKeysQueue.async(flags: .barrier) {
        self.memoryCachedKeys.insert(key)
        
        // Mark as avatar if key contains "avatar_"
        if key.contains("avatar_") {
            self.avatarCacheKeys.insert(key)
        }
    }
}
```

### 3. Updated releasePartialCache()
Changed from clearing ALL memory cache to selective removal:

**Before:**
```swift
// Clear memory cache completely (NSCache doesn't support partial clearing)
cache.removeAllObjects()  // ❌ Removes avatars too!
```

**After:**
```swift
// Selectively clear memory cache (protect avatars)
cacheKeysQueue.sync {
    let nonAvatarKeys = memoryCachedKeys.subtracting(avatarCacheKeys)
    let countToRemove = max(0, (nonAvatarKeys.count * percentageToRemove) / 100)
    
    if countToRemove > 0 {
        // Remove percentage of non-avatar images from memory
        let keysToRemove = Array(nonAvatarKeys.prefix(countToRemove))
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
            memoryCachedKeys.remove(key)
        }
        print("DEBUG: [ImageCacheManager] Released \(keysToRemove.count) images from memory (avatars protected: \(avatarCacheKeys.count))")
    }
}
```

### 4. Updated clearAvatarCache() and clearAllAvatarCache()
Now properly clean up tracking sets when avatars are explicitly cleared.

## How Avatar Detection Works
Avatars are identified by their cache key containing `"avatar_"`:
- Avatar cache keys come from `User.avatar` (MimeiId)
- These MimeiIds contain the `"avatar_"` prefix
- Example: `"avatar_user123_compressed"`

## Files Modified
1. `Sources/Core/ImageCacheManager.swift`
   - Added `avatarCacheKeys` and `memoryCachedKeys` tracking
   - Updated `cacheImageInMemory()` to track keys
   - Updated `releasePartialCache()` to selectively remove non-avatars
   - Updated `clearAvatarCache()` and `clearAllAvatarCache()` to clean up tracking sets

## Expected Behavior

### Memory Cache Cleanup:
```
OLD:
🗑️ Releasing 20% of image cache
   Cleared ALL 50 images (including 15 avatars) ❌

NEW:
🗑️ Releasing 20% of image cache
   Released 7 images from memory (avatars protected: 15) ✅
```

### User Experience:
- ✅ Avatars stay in memory during scrolling
- ✅ No avatar re-loading/flickering
- ✅ Faster timeline scrolling
- ✅ Reduced network and disk I/O

### Disk Cache:
Avatar protection on disk was already implemented and remains unchanged.

## Build Status
✅ BUILD SUCCEEDED

## Testing
To verify:
1. Scroll through timeline (loads many avatars)
2. Trigger memory pressure (load videos, images)
3. Check logs - should show `(avatars protected: N)`
4. Scroll back up - avatars should appear instantly (from memory)
