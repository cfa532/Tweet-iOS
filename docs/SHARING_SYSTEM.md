# Sharing System

**Last Updated:** August 6, 2026
**Status:** ✅ Production

---

## Overview

The sharing system provides context-aware URL generation that adapts based on
where the share action is initiated. Domain-based links are opened by TweetWeb
when a native app does not claim them. Provider-IP links use the separate
Leither `entry` form required for direct node access.

The `#` in a domain URL such as `http://t1.www3.shop/#tweet/...` is part of
TweetWeb's external share-link contract. It does not mean TweetWeb uses Vue
`createWebHashHistory()` for domain navigation. TweetWeb keeps
`createWebHistory()` for normal domain routes. Hash routing is reserved for the
provider-IP `entry?...#/tweet/...` form.

On iOS, the share flow also provides rich metadata to the system share sheet using `UIActivityItemSource` and `LPLinkMetadata`. That metadata is what allows apps such as WeChat to render a card-like preview even though the app is not using the WeChat SDK.

This behavior is platform-specific. Android's generic `ACTION_SEND` flow does not expose an equivalent metadata path that WeChat reliably turns into the same card UI. Matching the iOS result on Android would generally require either:

1. WeChat Open SDK integration with a registered WeChat `AppID`, or
2. A public URL that WeChat can unfurl server-side into a preview card based on webpage metadata.

---

## URL Formats

### Provider-IP Entry Sharing (Detail Dropdown)

The detail dropdown's dedicated share-link action generates an **IP-based
entry URL** with a hash fragment:

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

### Backend-Domain Sharing (Detail View / Comments)

When sharing through the backend-provided domain, the app uses TweetWeb's
**fragment-form domain share format**:

```
{domainToShare}/#tweet/{tweetMid}/{authorId}
```

**Example:**
```
http://t1.www3.shop/#tweet/abc123/user456
```

---

## Why Different Formats?

### Provider-IP URLs in the Detail Dropdown

The detail dropdown offers an **IP-based URL** because:

1. **Direct Author Access**: Each tweet author hosts their content on their own IP address
2. **Decentralized Architecture**: Content is distributed across multiple user-hosted nodes
3. **Immediate Resolution**: No DNS lookup needed, direct IP connection
4. **Entry Routing Compatibility**: The `entry` loader reads the route from the hash fragment

### Domain URLs

Backend-domain sharing uses **domain URLs** because:

1. **User-Friendly**: Easier to remember and share
2. **Brand Consistency**: Uses the main application domain
3. **TweetWeb Share Contract**: Uses `/#tweet/...` for externally shared tweet links
4. **Gateway Access**: Routes through the main gateway for distributed content

---

## Web Application Integration

### Domain URLs: History Mode

TweetWeb uses **HTML5 history mode** for normal domain navigation:

```javascript
// Web app router configuration
const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/tweet/:mid/:authorId',
      component: TweetDetailComponent
    }
  ]
})
```

An external domain share such as `/#tweet/{mid}/{authorId}` is recognized at
TweetWeb ingress and resolved to the existing `/tweet/{mid}/{authorId}` history
route. The fragment is an external URL envelope; it does not change the
router's history implementation.

### Provider-IP URLs: Entry Hash Routing

The provider-IP form is different:

1. The browser must first load `/entry?aid=...&ver=last` from the selected node.
2. The server never receives the fragment.
3. After the entry app loads, `#/tweet/{mid}/{authorId}` selects the tweet.
4. This hash-routing form is retained specifically for direct IP/node URLs.

### URL Flow Example

1. **User shares from TweetDetailView:**
   ```
   http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/abc123/user456
   ```

2. **Recipient opens link in web browser:**
   - Browser loads `entry` page from author's IP
   - Vue app initializes with `aid` and `ver` parameters
   - The IP-entry router reads hash fragment: `#/tweet/abc123/user456`
   - App navigates to tweet detail view with specified mid and authorId

3. **Content loads directly from author's node:**
   - No intermediary servers needed
   - Fast, decentralized content delivery
   - Author maintains control of their content

---

## Implementation Details

### Context Detection

The current share policy selects one of three explicit URL styles:

```swift
enum TweetShareLinkStyle {
    case deeplink   // dtweet.com/#tweet/... for plain feed rows
    case webDomain // check_upgrade domain/#tweet/... for direct detail/comment shares
    case providerIP // provider/entry?...#/tweet/... for the detail dropdown
}
```

The provider-IP form is not the general detail-view default. It is selected by
the detail dropdown's dedicated “share link” action.

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

## Current Implementation Files

**TweetActionButtonsView.swift**
- Plain feed rows use `dtweet.com/#tweet/...`.
- Detail, fullscreen, and comment shares use the backend-provided
  `domain/#tweet/...` form.
- Screenshot capture remains context-aware.

**TweetDetailView.swift**
- The direct share button uses the backend-provided domain.
- The dropdown share-link action uses the provider-IP entry URL.

**CommentDetailView.swift**
- Comment sharing uses the backend-provided domain and appends parent context
  inside the fragment-form URL.

---

## Testing Checklist

### Detail Dropdown Provider-IP Sharing
- [ ] Open tweet in TweetDetailView
- [ ] Open the dropdown and choose the share-link action
- [ ] Verify URL format: `{ip}/entry?aid={hash}&ver=last#/tweet/{mid}/{authorId}`
- [ ] Verify screenshot shows current frame from detail view player
- [ ] Open shared link in web browser
- [ ] Verify Vue app loads and navigates to tweet

### Backend-Domain Sharing
- [ ] Share a tweet from a detail view or comment row
- [ ] Verify URL format: `{domain}/#tweet/{mid}/{authorId}` when using the backend-provided domain
- [ ] Verify TweetWeb opens the external fragment-form URL and resolves the history-mode tweet route
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

Important limitation: domain and provider-IP share URLs currently encode the
tweet identity after `#`. Server-side crawlers do not send URL fragments in
HTTP requests, so WeChat unfurling cannot reliably derive tweet-specific
metadata from those URLs alone. A clean canonical URL such as
`/tweet/{mid}/{authorId}` is much more suitable for crawler-generated cards.

### Migration Notes

TweetWeb already uses HTML5 history mode for normal domain navigation. Do not
remove `#` from domain share URLs merely because of that router setting; the
fragment-form URL is a separate external contract. If the provider-IP entry
loader is changed in the future, migrate its `#/tweet/...` route separately and
keep backward compatibility with existing node links.

---

## Related Documentation

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Overall app architecture
- **[VIDEO_PLAYBACK_PIPELINE.md](./VIDEO_PLAYBACK_PIPELINE.md)** - Video playback and network behavior
- **[UNIVERSAL_LINKS.md](./UNIVERSAL_LINKS.md)** - Link routing behavior
