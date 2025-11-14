# Sharing System

**Last Updated:** November 14, 2025  
**Status:** ✅ Production

---

## Overview

The sharing system provides context-aware URL generation that adapts based on where the share action is initiated. It uses IP-based URLs for detail view sharing to ensure compatibility with the web application's Vue HashHistory router.

---

## URL Formats

### Detail View Sharing (TweetDetailView / CommentDetailView)

When sharing from detail views, the app generates **IP-based entry URLs** with hash fragments:

```
{author's baseUrl}/entry?aid={appIdHash}&ver=last#/tweet/{tweetMid}/{authorId}
```

**Example:**
```
http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/abc123/user456
```

**Components:**
- **baseUrl**: Author's IP-based URL (e.g., `http://125.229.161.122:8080`)
- **aid**: App ID hash from `AppConfig.appIdHash` (auto-selects debug/release)
- **ver**: Version parameter set to `"last"` for latest app version
- **Hash Fragment**: `#/tweet/{mid}/{authorId}` - Vue router path

### Feed/Grid Sharing (TweetItemView)

When sharing from the feed or grid view, the app uses the **traditional domain format**:

```
{domainToShare}/tweet/{tweetMid}/{authorId}
```

**Example:**
```
https://tweet.fireshare.us/tweet/abc123/user456
```

---

## Why Different Formats?

### IP-Based URLs in Detail View

The detail view uses **IP-based URLs** because:

1. **Direct Author Access**: Each tweet author hosts their content on their own IP address
2. **Decentralized Architecture**: Content is distributed across multiple user-hosted nodes
3. **Immediate Resolution**: No DNS lookup needed, direct IP connection
4. **Web App Compatibility**: Works seamlessly with Vue Router's HashHistory mode

### Domain URLs in Feed

The feed uses **domain URLs** because:

1. **User-Friendly**: Easier to remember and share
2. **Brand Consistency**: Uses the main application domain
3. **SEO Friendly**: Better for search engine indexing
4. **Gateway Access**: Routes through the main gateway for distributed content

---

## Web Application Integration

### Vue Router HashHistory

The web application uses **HashHistory** mode in Vue Router, which relies on URL hash fragments for routing:

```javascript
// Web app router configuration
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/tweet/:mid/:authorId',
      component: TweetDetailComponent
    }
  ]
})
```

### Why HashHistory?

1. **IP Compatibility**: Hash fragments work with any IP address or domain
2. **No Server Configuration**: Doesn't require server-side routing rules
3. **Client-Side Routing**: All routing handled by JavaScript
4. **Bookmark Friendly**: URLs with hashes are fully shareable

### URL Flow Example

1. **User shares from TweetDetailView:**
   ```
   http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/abc123/user456
   ```

2. **Recipient opens link in web browser:**
   - Browser loads `entry` page from author's IP
   - Vue app initializes with `aid` and `ver` parameters
   - Vue Router reads hash fragment: `#/tweet/abc123/user456`
   - App navigates to tweet detail view with specified mid and authorId

3. **Content loads directly from author's node:**
   - No intermediary servers needed
   - Fast, decentralized content delivery
   - Author maintains control of their content

---

## Implementation Details

### Context Detection

The system uses an `isInDetailView` flag to determine the appropriate URL format:

```swift
struct TweetActionButtonsView: View {
    var isInDetailView: Bool = false
    
    private func tweetShareText(_ tweet: Tweet) -> String {
        let urlText: String
        if isInDetailView {
            // Detail view: IP-based entry URL
            let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
            urlText = "\(baseUrlString)/entry?aid=\(AppConfig.appIdHash)&ver=last#/tweet/\(tweet.mid)/\(tweet.authorId)"
        } else {
            // Feed: Traditional domain URL
            var text = hproseInstance.domainToShare
            text.append("/tweet/\(tweet.mid)/\(tweet.authorId)")
            urlText = text
        }
        return urlText
    }
}
```

### Screenshot Capture

The share button also captures context-appropriate video screenshots:

**In TweetDetailView:**
- Captures from the currently playing video in detail view
- Uses player cache key: `"tweetDetail_\{mediaID}"`
- Shows exact frame user is watching

**In Feed/Grid:**
- Captures from grid view player
- Uses player cache key: `\{mediaID}`
- May differ from detail view if user scrolled

### BaseURL Resolution

The system uses a fallback chain for baseUrl resolution:

```swift
let baseUrlString = tweet.author?.baseUrl?.absoluteString ?? AppConfig.baseUrl
```

1. **Primary**: Tweet author's baseUrl (IP-based, if available)
2. **Fallback**: AppConfig.baseUrl (default server URL)

This ensures the share URL always works, even if author's IP is temporarily unavailable.

---

## Build Configuration

### App ID Hash Selection

The app automatically selects the correct app ID hash based on build configuration:

```swift
// AppConfig.swift
static let appIdHash: String = {
    switch BuildConfiguration.current {
    case .debug:
        return "FGPaNfKA-RwvJ-_hGN0JDWMbm9R"
    case .release:
        return "h5U5jxPr2p2tg2kMr8UeyRMNIJ_"
    }
}()
```

**Debug Build:**
- Uses debug app ID hash
- Points to development web app instance

**Release Build:**
- Uses production app ID hash
- Points to production web app instance

---

## Share Content Format

### Complete Share Message

The share sheet includes:

1. **Content Preview** (if available):
   - Tweet title (truncated to 40 chars)
   - OR tweet content (truncated to 40 chars)
   - OR attachment types (e.g., "📹 Video, 📷 Image")

2. **URL** (format depends on context)

3. **Screenshot** (for media attachments):
   - Current video frame (if video)
   - Image thumbnail (if image)
   - Cropped to 270x270 pixels

**Example:**
```
Check out this amazing video! 🎥

http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/abc123/user456

[Screenshot attachment]
```

---

## Files Modified

### November 14, 2025 - Share System Enhancement

**TweetActionButtonsView.swift**
- Added `isInDetailView` parameter
- Implemented dual URL format logic
- Enhanced video screenshot capture with context awareness

**TweetDetailView.swift**
- Pass `isInDetailView: true` to TweetActionButtonsView
- Ensures detail view sharing uses IP-based URLs

**CommentDetailView.swift**
- Pass `isInDetailView: true` to TweetActionButtonsView
- Maintains consistency with TweetDetailView

---

## Testing Checklist

### Detail View Sharing
- [ ] Open tweet in TweetDetailView
- [ ] Tap share button
- [ ] Verify URL format: `{ip}/entry?aid={hash}&ver=last#/tweet/{mid}/{authorId}`
- [ ] Verify screenshot shows current frame from detail view player
- [ ] Open shared link in web browser
- [ ] Verify Vue app loads and navigates to tweet

### Feed Sharing
- [ ] Share tweet from feed (TweetItemView)
- [ ] Verify URL format: `{domain}/tweet/{mid}/{authorId}`
- [ ] Verify traditional domain-based URL
- [ ] Screenshot matches grid view player state

### Build Configurations
- [ ] Debug build uses debug app ID hash
- [ ] Release build uses release app ID hash
- [ ] Both configurations generate valid URLs

---

## Future Considerations

### Potential Enhancements

1. **QR Code Generation**: Generate QR codes for easy mobile sharing
2. **Deep Links**: Support app-to-app sharing with custom URL scheme
3. **Link Preview**: Rich link previews for social media platforms
4. **Analytics**: Track share actions and conversions
5. **Custom Share Messages**: Allow users to customize share text

### Migration Notes

If the web app switches from HashHistory to HTML5 History mode:
- Remove hash fragment from URL format
- Update URL generation to use clean paths
- Ensure server-side routing configuration
- Maintain backward compatibility with existing shared links

---

## Related Documentation

- **[BASEURL_RESOLUTION_AND_CACHE_RENDERING.md](./BASEURL_RESOLUTION_AND_CACHE_RENDERING.md)** - BaseURL resolution system (deprecated)
- **[INSTANT_TWEET_RENDERING.md](./INSTANT_TWEET_RENDERING.md)** - Current tweet rendering system
- **[VIDEO_SYSTEM.md](./VIDEO_SYSTEM.md)** - Video player architecture
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Overall app architecture

