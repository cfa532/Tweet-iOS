# Deep Linking & Share-URL Configuration

How dtweet.com deep links work across iOS, Android, and the web, and which
URL each share action produces. This is the cross-platform spec; the Android
repo (`~/Documents/GitHub/Tweet`) carries the same document.

## Domains & infrastructure

| Host | Role |
|---|---|
| `dtweet.com` | Deep-link domain (Cloudflare Worker, `cloudflare/dtweet-worker/`). Serves `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` over https; redirects browser page loads `302 → http://dl.dtweet.com/<path>`; proxies stray API calls to Leither. Deploy with `npx wrangler deploy`. |
| `dl.dtweet.com` | Http-only web app (Cloudflare-proxied DNS → ksbox nginx :80 → Leither :8080, Leither domain-routes it to the TweetWeb app). The Worker answers its https requests with `301 → http` so browsers' forced-https upgrades fall back to http. |
| check_upgrade domain | Whatever domain the backend returns from `check_upgrade` (stored in `HproseInstance.domainToShare`, user-overridable in profile settings). |

The web stack (Leither + TweetWeb) is **http-only**: TweetWeb hardcodes
`http://` for its `/webapi/` RPC and talks directly to provider-node IPs, so
an https page would have all of it blocked as mixed content. https exists
solely where Apple/Google require it (the two well-known files + redirects).

## Who opens the link

- **App installed**: the OS intercepts `dtweet.com` links (http or https) via
  iOS Universal Links / Android App Links before any HTTP request happens and
  opens the tweet in the app.
- **No app**: the browser follows the Worker redirect and renders the tweet
  on `http://dl.dtweet.com/...`. Chrome may show a one-time
  "connection is not secure — Continue" interstitial on the https→http
  downgrade; Safari/Firefox fall back silently.

## Share-URL policy (which button produces which URL)

| Share action | URL format | Rationale |
|---|---|---|
| **Feed share button** (plain tweet rows only) | `http://dtweet.com/tweet/{mid}/{authorId}` (standard deep-link format) | Opens the app when installed; web fallback via Worker |
| **Detail-view share button** | `http://{check_upgrade domain}/tweet/{mid}/{authorId}` | Backend-controlled domain, independent of dtweet.com |
| **Detail-view dropdown menu → share** | `http://{author provider IP}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}` | Works with a bare node IP, no DNS/domain needed |
| **Everything else** (comment rows, fullscreen player, media browser) | check_upgrade domain — same as the detail-view share button | Unchanged legacy behavior |

Comment shares append `?fromComment=true&parentTweetId={mid}&parentAuthorId={mid}`
(inside the hash fragment for the provider-IP format).

## iOS implementation map

- `Tweet/Tweet.entitlements` — `applinks:dtweet.com` (Associated Domains).
- `Sources/App/AppConfig.swift` — `shareDomain = "http://dtweet.com"`.
- `Sources/Tweet/UIKit/TweetActionBarView.swift` — `TweetShareLinkStyle`
  enum (`.deeplink` / `.webDomain` / `.providerIP`) and `buildShareText`;
  feed cells use `.deeplink`, `buildDetailShareItems` (detail dropdown menu)
  forces `.providerIP` and refreshes the author's IPv4 first.
- `Sources/Tweet/TweetActionButtonsView.swift` — SwiftUI action bar;
  `isInDetailView: true` (set by `TweetDetailView`) → check_upgrade domain,
  otherwise deep-link format.
- `Sources/Utils/DeeplinkManager.swift` — parses incoming `/tweet/{mid}/{authorId}`,
  `/user/{id}`, `/profile/{id}` (host-agnostic) and `tweet://` scheme;
  falls back `getTweet` → `refreshTweet`, both of which populate `tweet.author`.
- `Sources/Core/HproseInstance.swift` — `checkAndUpdateDomain()` calls
  `check_upgrade` and stores the returned domain in `domainToShare`.

## Verification identities (in the Worker)

- iOS: Team `96LBXG78A7`, bundles `com.example.Tweet` / `.debug`
  (App Store id6751131431 "dTweet").
- Android: `us.fireshare.tweet` / `.debug`; fingerprints = Play App Signing
  cert + local upload key (`tweet_keystore.jks`) + debug keystore, so Play
  installs, sideloaded release builds, and debug builds all verify.
