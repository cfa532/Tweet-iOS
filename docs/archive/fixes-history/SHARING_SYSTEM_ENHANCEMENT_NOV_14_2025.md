# Sharing System Enhancement

**Date:** November 14, 2025  
**Status:** ✅ Complete

---

## Problem

When sharing videos from TweetDetailView:
1. Share button always captured screenshots from MediaCell (grid view) player instead of the currently playing video in detail view
2. Shared URLs used generic format, not optimized for the web app's Vue HashHistory router
3. No differentiation between sharing from detail view vs feed

---

## Root Cause

1. **Screenshot Mismatch:**
   - SimpleVideoPlayer ALWAYS cached players with key: `\{mediaID}` regardless of mode
   - TweetActionButtonsView incorrectly tried to look for `"tweetDetail_\{mediaID}"` key in detail view
   - This mismatch caused screenshot capture to fail in TweetDetailView (player lookup returned nil)

2. **URL Format:**
   - All shares used the same URL format regardless of context
   - Web app uses Vue HashHistory requiring hash fragments for routing
   - IP-based entry URLs needed for direct author content access

---

## Solution

### 1. Context-Aware Screenshot Capture

Fixed cache key lookup in `TweetActionButtonsView`:

```swift
struct TweetActionButtonsView: View {
    var isInDetailView: Bool = false
    
    private func generateVideoPreviewImage(for url: URL, isHLS: Bool = false) async -> UIImage? {
        // SimpleVideoPlayer always caches with just the mediaID (mid), regardless of mode
        // So we always use mediaID as the cache key
        let cacheKey: String = mediaID
        
        // Look up player with correct cache key
        if let cachedPlayer = SharedAssetCache.shared.getCachedPlayer(for: cacheKey) {
            // Capture from the correct player
        }
    }
}
```

**Fix Details:**
- Removed incorrect conditional cache key logic
- Now always uses `mediaID` to match how `SimpleVideoPlayer` actually caches players
- This allows screenshot capture to successfully find and use the cached player in TweetDetailView

### 2. IP-Based Entry URLs for Detail View

Implemented dual URL format system:

**Detail View (TweetDetailView/CommentDetailView):**
```
{author's baseUrl}/entry?aid={AppConfig.appIdHash}&ver=last#/tweet/{mid}/{authorId}
```

**Feed View (TweetItemView):**
```
{domainToShare}/tweet/{mid}/{authorId}
```

**Implementation:**
```swift
private func tweetShareText(_ tweet: Tweet) -> String {
    let urlText: String
    if isInDetailView {
        // IP-based entry URL with hash fragment
        let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
        urlText = "\(baseUrlString)/entry?aid=\(AppConfig.appIdHash)&ver=last#/tweet/\(tweet.mid)/\(tweet.authorId)"
    } else {
        // Traditional domain URL
        var text = hproseInstance.domainToShare
        text.append("/tweet/\(tweet.mid)/\(tweet.authorId)")
        urlText = text
    }
    return urlText
}
```

---

## Files Modified

### TweetActionButtonsView.swift
- Added `isInDetailView: Bool = false` parameter
- Updated `generateVideoPreviewImage()` to use context-aware cache keys
- Implemented dual URL format logic in `tweetShareText()`

### TweetDetailView.swift
- Pass `isInDetailView: true` when creating TweetActionButtonsView
- Ensures detail view context is propagated

### CommentDetailView.swift
- Pass `isInDetailView: true` when creating TweetActionButtonsView
- Maintains consistency with TweetDetailView

---

## Benefits

### 1. Accurate Video Screenshots
- Detail view shares now capture from the video actually playing in detail view
- Shows exact frame user is watching
- No more confusion between grid and detail view states

### 2. Web App Integration
- **IP-Based URLs**: Direct access to author's content node
- **Hash Fragments**: Compatible with Vue HashHistory router
- **Entry Format**: Proper app initialization with `aid` and `ver` parameters

### 3. Decentralized Architecture Support
- Each author's content hosted on their own IP
- No centralized server dependency
- Fast, direct content delivery

### 4. Context Awareness
- Different URL formats for different contexts
- Feed sharing uses user-friendly domain URLs
- Detail sharing uses direct IP-based URLs

---

## Vue Router Compatibility

The web app uses **HashHistory** mode:

```javascript
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/tweet/:mid/:authorId', component: TweetDetailComponent }
  ]
})
```

### URL Flow

1. **iOS app generates:**
   ```
   http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/abc123/user456
   ```

2. **Browser receives:**
   - Loads entry page from author's IP
   - Vue app initializes with `aid` and `ver` parameters
   - Router reads hash: `#/tweet/abc123/user456`
   - Navigates to tweet detail view

3. **Content loads:**
   - Directly from author's node
   - No intermediary servers
   - Fast decentralized delivery

---

## Testing Verified

### ✅ Detail View Screenshot
- Open tweet in TweetDetailView
- Play video for several seconds
- Tap share button
- Screenshot shows current frame from detail view (not grid)

### ✅ Detail View URL Format
- Share from TweetDetailView
- URL format: `{ip}/entry?aid={hash}&ver=last#/tweet/{mid}/{authorId}`
- Contains author's IP address
- Includes app ID hash
- Has hash fragment for Vue router

### ✅ Feed View URL Format
- Share from feed (TweetItemView)
- URL format: `{domain}/tweet/{mid}/{authorId}`
- Uses traditional domain
- Maintains backward compatibility

### ✅ Web App Integration
- Open shared URL in browser
- Vue app loads correctly
- Routes to tweet detail view
- Content loads from author's IP

---

## Documentation

Created **SHARING_SYSTEM.md** covering:
- URL format differences
- Vue HashHistory integration
- IP-based sharing strategy
- Screenshot capture logic
- Build configuration
- Testing checklist

Updated **INDEX.md**:
- Added SHARING_SYSTEM.md to Core Systems
- Updated last modified date

---

## Code Quality

### Backward Compatible
- Default parameter: `isInDetailView: Bool = false`
- All existing usages continue to work
- No breaking changes

### Clean Implementation
- Single parameter controls both screenshot and URL behavior
- No code duplication
- Clear separation of concerns

### Future-Proof
- Easy to add more contexts if needed
- Supports different sharing strategies
- Flexible URL format system

---

## Related Documentation

- [**SHARING_SYSTEM.md**](../SHARING_SYSTEM.md) - Complete sharing system documentation
- [**VIDEO_SYSTEM.md**](../VIDEO_SYSTEM.md) - Video player architecture
- [**INSTANT_TWEET_RENDERING.md**](../INSTANT_TWEET_RENDERING.md) - Tweet rendering system

