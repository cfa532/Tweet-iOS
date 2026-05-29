# Sharing System

**Last Updated:** April 14, 2026  
**Status:** ✅ Production

---

## Overview

The sharing system provides context-aware URL generation that adapts based on where the share action is initiated. It uses IP-based URLs for detail view sharing to ensure compatibility with the web application's Vue HashHistory router.

On iOS, the share flow also provides rich metadata to the system share sheet using `UIActivityItemSource` and `LPLinkMetadata`. That metadata is what allows apps such as WeChat to render a card-like preview even though the app is not using the WeChat SDK.

This behavior is platform-specific. Android's generic `ACTION_SEND` flow does not expose an equivalent metadata path that WeChat reliably turns into the same card UI. Matching the iOS result on Android would generally require either:

1. WeChat Open SDK integration with a registered WeChat `AppID`, or
2. A public URL that WeChat can unfurl server-side into a preview card based on webpage metadata.

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

### Rich Share Metadata on iOS

The iOS implementation does more than share plain text plus a URL:

1. `CustomShareItem` returns the actual share text for all targets.
2. `activityViewControllerLinkMetadata(...)` provides `LPLinkMetadata` with:
   - the share URL
   - a title derived from tweet title/content/attachment types
   - `iconProvider` / `imageProvider` backed by the preview image
3. A standalone `CustomShareImage` is also supplied because WeChat's iOS share extension responds better when a separate image item is present.

This is why the iOS app can produce a WeChat card-like share result without a WeChat `AppID`: the card is being inferred from Apple's share metadata APIs, not from the WeChat native SDK.

### Android Limitation

Android currently shares as plain `text/plain` through the system sharesheet. That is enough to share a tweet URL, but not enough to force WeChat to render the same app-provided card format that iOS gets through `LPLinkMetadata`.

If Android needs a native WeChat card with app-controlled title/description/thumbnail, it would need:

1. WeChat Open Platform registration
2. a WeChat `AppID`
3. WeChat Android SDK integration using `WXWebpageObject` / `WXMediaMessage`
4. a compressed thumbnail that fits WeChat's size limits

If no `AppID` is available, the fallback path is to rely on WeChat previewing a public webpage URL on its own.

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

### Platform Comparison

**iOS**
- Shares text + URL
- Supplies `LPLinkMetadata` title/image metadata
- Supplies a separate preview image item
- Can appear as a rich card in WeChat without WeChat SDK integration

**Android (current)**
- Shares only text + URL through `ACTION_SEND`
- Does not provide app-controlled rich link metadata to WeChat
- Cannot reliably reproduce the same WeChat card UI without WeChat SDK integration

**Android (without WeChat AppID)**
- Best possible outcome is a plain shared URL that WeChat may unfurl on its own
- Final preview depends on the shared webpage's public metadata and WeChat's crawler/cache behavior

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
3. **Public Metadata Optimization**: Improve webpage `og:title`, `og:description`, and `og:image` so platforms like WeChat can unfurl shared URLs more consistently
4. **Analytics**: Track share actions and conversions
5. **Custom Share Messages**: Allow users to customize share text

### WeChat Notes

If Android cannot obtain a WeChat `AppID`, there is no native SDK path to guarantee the same share card behavior as iOS. In that case, the practical strategy is:

1. Keep sharing a stable public tweet URL
2. Make sure the destination webpage exposes strong public metadata
3. Treat WeChat card rendering as server-side URL unfurling behavior rather than app-driven share metadata

Important limitation: detail-view share URLs currently encode the tweet route in the hash fragment (`#/tweet/...`). Server-side crawlers do not send URL fragments in HTTP requests, so WeChat unfurling cannot reliably derive tweet-specific metadata from those URLs alone. A clean canonical URL such as `/tweet/{mid}/{authorId}` is much more suitable for crawler-generated cards.

### Migration Notes

If the web app switches from HashHistory to HTML5 History mode:
- Remove hash fragment from URL format
- Update URL generation to use clean paths
- Ensure server-side routing configuration
- Maintain backward compatibility with existing shared links

---

## Related Documentation

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Overall app architecture
- **[VIDEO_PLAYBACK_PIPELINE.md](./VIDEO_PLAYBACK_PIPELINE.md)** - Video playback and network behavior
- **[UNIVERSAL_LINKS.md](./UNIVERSAL_LINKS.md)** - Link routing behavior

