# Deep Linking and Browser-Compatible URLs

This document describes the `dtweet.com` deep-link setup and the rules that
keep it compatible with existing Leither web URLs such as `t1.fireshare.us` and
`t1.w333w.site`.

The goal is:

- `https://dtweet.com/tweet/{mid}/{authorId}` opens the native app when the app
  is installed.
- The same URL opens a real web page when the app is not installed or when the
  user opens it in a desktop browser.
- Existing Leither-hosted web domains keep their original routing behavior.
- Public web access does not require Tailscale or any private network route.
- Shared tweet path URLs return Open Graph cards to LINE and other preview
  crawlers. Previously shared HTTP and fragment URLs keep opening as before.

## Mutable browser fallback

The browser application domain is operational configuration, not a permanent
part of the deep-link contract. The source of truth is
`BROWSER_FALLBACK_ORIGIN` in
`cloudflare/dtweet-worker/src/index.js`. Its current value is
`http://t1.www33.shop`, but the owner may replace it at any time.

In routing requirements below, “the HTTP fallback” means the value of that
constant. Concrete browser-fallback URLs document the current deployment or a
historical migration; they must not be copied into new routing logic as a
second source of truth. When the domain changes, update the Worker constant,
the corresponding nginx/DNS configuration, and the current-value examples in
the same operation. Follow TweetWeb's
`docs/BROWSER_FALLBACK_DOMAIN_MIGRATION.md` procedure.

## URL model

| URL | Role | Expected behavior |
|---|---|---|
| `dtweet.com` | Public deep-link wrapper | iOS/Android verify it as an app-link domain. Browser navigations are redirected by the Worker to `http://t1.www33.shop`; the browser retains the fragment locally. |
| `www.dtweet.com` | Alias | Redirects permanently to `dtweet.com`. |
| `dl.dtweet.com` | Public gateway alias | Served by the same Cloudflare Worker. Browser navigations redirect to `http://t1.www33.shop`; static assets, association files, and non-navigation origin requests keep their dedicated Worker branches. Kept only for compatibility; new shared links should not need it. |
| `t1.fireshare.us`, `t1.w333w.site`, `t1.www33.shop`, other Leither domains | Web app hosts | `t1.www33.shop` is the current browser fallback target. These hosts keep normal Leither route discovery and must not be forced through dtweet gateway behavior. |
| check_upgrade domain | Backend-controlled share domain | Used by some existing share paths and user settings. Independent of `dtweet.com`. |
| provider IP entry URL | Direct node fallback | `http://{providerIP}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}`. Works without DNS. |

Use `dtweet.com` for share links that should behave like universal/app links.
Do not share `dl.dtweet.com` as the primary public link unless a specific
compatibility case needs it.

The `#` in `domain/#tweet/...` is TweetWeb's external share-link delimiter; it
does not indicate that TweetWeb uses Vue `createWebHashHistory()` for domain
navigation. Normal domain navigation uses history mode. The distinct
`provider/entry?...#/tweet/...` form is the IP-entry hash-routing contract.

## Request flow

### App installed

1. The user taps `http://dtweet.com/#tweet/{mid}/{authorId}` or
   `https://dtweet.com/#tweet/{mid}/{authorId}`.
2. iOS Universal Links or Android App Links check the association file already
   cached from `https://dtweet.com/.well-known/...`.
3. The OS opens the native app before the normal browser navigation completes.
4. The app parses `tweet/{mid}/{authorId}` from the URL fragment and opens the
   tweet.

The native app does not depend on the Worker serving the tweet page for this
case. The Worker only needs to serve valid association files over HTTPS.

### App not installed, or desktop browser

1. The browser opens `dtweet.com`.
2. For `/#tweet/...`, the fragment is not sent in the HTTP request; the Worker
   redirects to `http://t1.www33.shop` and the browser retains the fragment.
   For a `/tweet/...` path, the Worker explicitly redirects to
   `http://t1.www33.shop/#tweet/...`, moving its query into the fragment route.
3. Chrome may try HTTPS first; because that host does not provide a valid HTTPS
   page, normal browser fallback settles on HTTP. Safari opens the HTTP target
   directly.
4. TweetWeb runs as a normal Leither-hosted app and uses HTTP/`ws://` provider
   routes without HTTPS mixed-content blocking.

The Worker-owned redirect avoids both the `dl.dtweet.com` HTTPS mixed-content
failure and an HTTPS-to-HTTP redirect loop.

### Existing Leither domains

When the page host is `t1.fireshare.us`, `t1.w333w.site`, or another normal
Leither web domain, TweetWeb must not switch into dtweet gateway mode. These
hosts keep their original provider-route behavior, including any private routes
that are valid for that host.

Compatibility depends on using an exact allowlist for gateway hosts:

```text
dtweet.com
www.dtweet.com
dl.dtweet.com
```

Do not implement gateway detection as "any public hostname". That breaks
existing Leither domains by making them use dtweet-only routing rules.

## Cloudflare Worker setup

Worker location:

```text
cloudflare/dtweet-worker/
```

The Worker has four jobs:

1. Serve iOS Universal Links association:
   `/.well-known/apple-app-site-association`
2. Serve Android App Links association:
   `/.well-known/assetlinks.json`
3. Redirect browser navigations on both `dtweet.com` and `dl.dtweet.com` to
   `http://t1.www33.shop`, while keeping `dl.dtweet.com` static assets,
   association files, and non-navigation origin requests on their existing
   Worker branches.
4. Serve tweet-specific Open Graph HTML to preview crawlers for path-based
   share URLs, using anonymous backend reads.

The Worker routes are configured in:

```text
cloudflare/dtweet-worker/wrangler.toml
```

Expected route shape:

```toml
routes = [
  { pattern = "dtweet.com", custom_domain = true },
  { pattern = "www.dtweet.com", custom_domain = true },
  { pattern = "dl.dtweet.com/*", zone_name = "dtweet.com" }
]
```

The Worker asset binding points at the TweetWeb production bundle:

```toml
[assets]
directory = "../../../TweetWeb/dist"
binding = "ASSETS"
not_found_handling = "single-page-application"
run_worker_first = true
```

Do not make `dtweet.com` browser navigation redirect to `dl.dtweet.com`, and do
not serve TweetWeb HTML navigation directly from the HTTPS `dl.dtweet.com`
asset binding. Either path runs TweetWeb under HTTPS, which blocks Leither's
HTTP and `ws://` provider requests as mixed content. The Worker must redirect
browser navigations on both hosts to the separate HTTP origin configured by
`BROWSER_FALLBACK_ORIGIN`.

The `dtweet.com` zone's old single Redirect Rule named
`Browser fallback to dl.dtweet.com` must remain disabled. Zone redirect rules
run before Workers and otherwise bypass the association-aware routing code.

## Association files

### iOS

The Worker response for `/.well-known/apple-app-site-association` must be JSON,
over HTTPS, with no redirect.

Current identities:

```text
Team ID: 96LBXG78A7
Bundle IDs:
  com.example.Tweet
  com.example.Tweet.debug
```

Current association components:

```text
/ (with hash fragment tweet/*)
/ (with hash fragment author/*)
/tweet/*
/author/*
```

iOS app configuration:

```text
Tweet/Tweet.entitlements
```

Required associated domain:

```text
applinks:dtweet.com
```

### Android

The Worker response for `/.well-known/assetlinks.json` must be JSON, over
HTTPS, with no redirect.

Current public package:

```text
us.fireshare.tweet
```

Keep all required SHA-256 fingerprints in the Worker:

- Google Play App Signing key
- local upload key used by release sideloads

The release entry must include both relations:

```text
delegate_permission/common.handle_all_urls
delegate_permission/common.get_login_creds
```

`common.get_login_creds` is required for Google Play credential sharing on
`dtweet.com`.

Do not include `us.fireshare.tweet.debug` in the public `dtweet.com`
`assetlinks.json`. Android may choose the debug app for production links if the
debug package is verified for the same host. Debug builds should use a separate
debug-only host or a direct `adb am start ...` command when testing deep-link
parsing.

## TweetWeb gateway behavior

TweetWeb must distinguish the dtweet public gateway from legacy Leither hosts.
The key file is in the sibling web repo:

```text
../TweetWeb/src/utils/browserNetwork.ts
```

Required behavior:

- `isPublicWebGatewayHost()` returns true only for `dtweet.com`,
  `www.dtweet.com`, and `dl.dtweet.com`.
- `browserUsableProviderRoutes()` filters private/Tailscale routes only when
  the current page host is one of those gateway hosts.
- Leither hosts such as `t1.fireshare.us` and `t1.w333w.site` must return
  false from `isPublicWebGatewayHost()`.

Redirecting browsers to `t1.w333w.site` does not change that classification:
after the redirect it is still a legacy Leither host and must retain normal
provider-route behavior.

The connection and store layers depend on that distinction:

```text
../TweetWeb/src/utils/connectionPool.ts
../TweetWeb/src/stores/leitherStore.ts
../TweetWeb/src/stores/tweetStore.ts
```

On gateway hosts, same-origin requests are allowed because the Cloudflare Worker
is the public broker. On legacy hosts, the app should keep the old direct
Leither/provider routing.

## TweetWeb build requirements for Leither

Leither resolves app object names literally. The generated HTML must refer to
local assets by bare object names, not with a leading `./` and not with query
strings.

Correct:

```html
<script type="text/javascript" src="hprose.js" crossorigin="anonymous"></script>
<script type="text/javascript" src="popper.min.js" crossorigin="anonymous"></script>
<script type="text/javascript" src="bootstrap.min.js" crossorigin="anonymous"></script>
<script type="module" crossorigin src="index_entry.js"></script>
```

Incorrect:

```html
<script type="text/javascript" src="./hprose.js?v=20260716"></script>
<script type="module" crossorigin src="./index_entry.js"></script>
```

The Vite transform that keeps these names bare lives in:

```text
../TweetWeb/vite.config.ts
```

This requirement matters for legacy Leither domains. If the HTML asks the
browser to load `/hprose.js` or `/index_entry.js` as a normal URL from
`t1.fireshare.us`, the Leither loader may return the loader HTML instead of the
JavaScript asset and the app will render an empty/error page.

## Share-URL policy

| Share action | URL format | Rationale |
|---|---|---|
| Tweet action-bar share buttons | `https://dtweet.com/tweet/{mid}/{authorId}` | App-link URL with browser fallback and server-readable IDs for preview cards, in feed, detail, comment, media, and fullscreen contexts. |
| Dropdown menu to share, feed and detail view alike | `http://{check_upgrade domain}/#tweet/{mid}/{authorId}` | Retains the backend-controlled domain for other destinations. Selecting LINE uses the canonical HTTPS dtweet path URL above. When the domain is a dtweet gateway alias (or missing), all destinations use that canonical path URL. |

The provider-IP format —
`http://{author public IPv4}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}`
— is no longer selected by any share action. It remains implemented as the
DNS-free format; see `getPublicIPv4BaseUrl` in `TweetActionBarView.swift` for how
the URL is composed and which addresses the validator rejects.

Comment shares append:

```text
?fromComment=true&parentTweetId={mid}&parentAuthorId={mid}
```

For provider-IP and other Leither domain URLs, comment parameters remain inside
the fragment route. For new dtweet path URLs, they are normal query parameters;
the Worker moves them into the fragment when redirecting to TweetWeb.

### Preview cards

`cloudflare/dtweet-worker/src/tweet-preview.js` recognizes LINE's `Linespider`
and common social preview crawlers before browser routing, without requiring
an HTML `Accept` header. A `GET /tweet/{mid}/{authorId}` from those crawlers
returns HTML with `og:title`, `og:description`, `og:image`, and a canonical URL.
Ordinary browsers retain the existing HTTP TweetWeb redirect; both variants
use `no-store` and vary on `User-Agent` and `Accept` to avoid mixing responses.

The Worker reads the release backend through the existing
`BROWSER_FALLBACK_ORIGIN`. `PREVIEW_APP_ID` in `wrangler.toml` must match the
deployed release backend manifest. It discovers providers with
`/getvar?name=mmprovs&arg0={mid}` at that origin. Ordinary JSON `/entry` reads
then go directly to the announced public provider through `cloudflare:sockets`.
Worker `fetch()` cannot address bare provider IPs, and anonymous
`/entry?nid=...` forwarding is rejected by Leither's system-session requirement.
The bounded HTTP/1.0 reads close their sockets on completion or timeout, and
cancel losing provider races before the next read. Discovery uses manual
redirect handling, since Workers do not support `redirect: "error"`.

Reads first find a provider serving the storage owner's User, then read the
Tweet there; a miss discovers the Tweet's own providers once. Comment shares
use `parentAuthorId` as storage owner. No explicit synchronization or provider
mutation is requested.

Private tweets return `403` without preview metadata. Unavailable data returns
`503` without invented metadata. Text is escaped before insertion into HTML.
Only the first attachment supplies the card thumbnail. An image uses
`previewMid` when present, otherwise its original `mid`; a video or HLS video
uses its uploaded JPEG `previewMid`. The Worker never scans later files for a
thumbnail, or substitutes the video file for a missing poster. `og:image`
points to the HTTPS dtweet URL
`/tweet/{mid}/{authorId}/preview-image`, preserving comment query parameters.
That endpoint accepts GET/HEAD from any image loader, resolves the public Tweet
and its selected attachment, and serves the unchanged raster image bytes from
the provider through the Worker. It accepts no arbitrary upstream URL or media
ID. Images are bounded to 8 MiB and use `no-store`; JSON reads retain their
1 MiB limit. HTTP headers and JSON are decoded as text, while image bodies stay
binary. This avoids exposing raw HTTP provider IPs and nonstandard ports to
LINE's image loader. A quote without attachments can use its public original's
first attachment. Text-only posts and first attachments without a supported
image/poster use the app icon.

For new iOS video uploads, `makeVideoPoster` extracts an orientation-correct
frame from the original local file off the main actor and encodes a JPEG of at
most 200 KiB and 1200 × 1200 pixels. The upload queue persists the accepted
video/HLS job receipt first, then uploads the poster to the same author's root
and saves its MID as `previewMid`. HLS completion preserves that field when
replacing the temporary job MID with the playback CID. Poster failure does
not discard a successful video upload; cancellation still stops the queue.
Video playback, normalization, HLS conversion and chat video uploads retain
their existing behavior. The shared backend already references `mid` and
`previewMid` for every attachment type, so no new backend field or API is needed.
Previously uploaded videos are not backfilled with posters.

The iOS share sheet omits the separate photo attachment when sharing to LINE,
so LINE receives the tweet text and URL and can create a link card. Other
destinations keep the separate photo behavior.
`CustomShareItem` also selects producer-supplied canonical dtweet text for LINE
when the menu's normal text uses a backend-domain fragment URL. Both variants
are prepared on the main actor, including comment context; the activity callback
never parses or repairs a legacy link and never reads a Tweet model. SwiftUI
action-bar items already use canonical dtweet text for every destination.

Old `/#tweet/...` links still open the app and website, but cannot gain a
tweet-specific server preview because their IDs are never sent over HTTP.
Share again from the updated app to obtain a preview-capable path URL. Backend
domains outside the dtweet gateway retain their existing sharing behavior.

## 2026-11-23: LINE rollout and WeChat investigation

### LINE changes delivered

- Updated iOS sharing to produce preview-capable HTTPS dtweet path URLs while
  retaining existing link parsing and native app opening. LINE menu shares use
  that URL even when other destinations receive the backend-domain URL.
- Deployed tweet-specific Open Graph HTML and the HTTPS raster-image endpoint
  in the dtweet Worker. The observed LINE crawler user agent was
  `facebookexternalhit/1.1;line-poker/1.0`. The user confirmed that an image
  appeared after the image was served through the HTTPS endpoint.
- Added optional JPEG poster uploads for new iOS tweet/comment/edit videos,
  preserving the video upload receipt, HLS completion and playback MID. The
  Worker selects only the first attachment. The updated Release app was built,
  installed and opened on cPhone17; the user subsequently confirmed that a new
  iOS video upload showed its thumbnail in LINE.
- A video published through another client or import tool had no `previewMid`
  on the three providers inspected, so its card used the app icon. Sharing an
  existing video does not create a poster. Other writers and old posts were
  not changed or backfilled.

### WeChat report and evidence

The user reported intermittent blank screens, with no confirmation dialog,
when opening this URL inside WeChat:

```text
http://t1.www33.shop/#tweet/NyO_IJ_5Os-KYbqTufs4mM0ALbv/iRor--GsfYguUgzVWDNyv8v6AAl
```

This URL goes directly to TweetWeb and bypasses the dtweet Worker. Static
review also showed that the LINE activity-specific branches retain the normal
shared text and separate image for WeChat. These findings do not establish
why the web page sometimes fails to open.

During read-only diagnostics, the tweet was publicly readable on three
providers. The web loader and application JavaScript requests inspected
returned HTTP 200, with permissive CORS headers on the provider responses.
Requests using a WeChat browser user agent followed the same dtweet browser
redirect as Safari. Successful HTTP responses and user-agent emulation do not
prove that startup completed in the user's WeChat browser.

TweetWeb's existing `TweetDetail.vue` startup gate checks `sessionStorage.isBot`
and `isWeChatBrowser()`. In a new WeChat session it calls
`confirm(t('download.openInDefaultBrowser'))`; confirmation records `isBot = No`
and starts loading, while a false result calls `history.go(-1)`. The gate's
intended purpose was not established during this investigation. Suppressed
dialogs were considered a possible explanation, but no failing WeChat runtime
capture confirmed that explanation.

### Changes made and reverted

The assistant removed the WeChat startup gate and added a loading shell with
a reload Retry button in TweetWeb's `index.html`. Both changes were built and
published before the cause was proven. The gate removal was not requested;
the user's Retry comment was a suggestion, not authorization to implement it.

After the user's correction, the original gate was restored exactly, and the
added startup shell and Retry button were removed. The corrected build was
uploaded and published to `/home/pi/demo/tweet1/` on gen8, including the current
production Go backend sources required by the release procedure. The same web
build was deployed to Cloudflare. Existing unrelated local TweetWeb edits were
preserved; this restored the two changed behaviors rather than rolling the
entire project back to an older source revision.

The final restoration deployment of `dtweet-deeplink` was
`e3a799f7-fb61-423f-9099-5dc38478e9fd`. Publication commands and the web build,
including TypeScript compilation, succeeded. The final required site-root
availability GET returned HTTP 200. No tests were run. That availability check
does not verify WeChat rendering or establish that the intermittent failure is
fixed.

### Remaining issue

The intermittent WeChat blank screen remains unresolved. The original gate and
entry markup are in place, and the pre-existing tweet-fetch error Retry UI
remains. No new startup Retry behavior remains from this investigation.

An attempt to capture WeChat log lines for `t1.www33.shop` on cPhone17 could not
start because the device was unavailable; the waiting logger was stopped. No
failing-load device capture was obtained. Further work needs evidence from an
actual failed load to distinguish loader, script startup, routing and tweet
fetch failures. Preserve the gate while investigating; understand its purpose
and obtain an explicit instruction before changing it.

## iOS implementation map

```text
Tweet/Tweet.entitlements
```

Contains `applinks:dtweet.com`.

```text
Sources/App/AppConfig.swift
```

Contains `shareDomain = "https://dtweet.com"`.

```text
Sources/Tweet/UIKit/TweetActionBarView.swift
```

Defines `TweetShareLinkStyle` and `buildShareText`. Every action bar uses the
dtweet deep-link style, and dropdown sharing — feed and detail view alike — uses
the `check_upgrade` domain via `buildFeedMenuShareItems`, with canonical dtweet
text supplied separately for LINE. The provider-IP style
remains defined as the DNS-free fallback format but no share action selects it.

```text
Sources/Tweet/TweetActionButtonsView.swift
```

SwiftUI action bar. Every share action uses the dtweet deep-link format.

```text
Sources/Utils/DeeplinkManager.swift
```

Parses `/tweet/{mid}/{authorId}`, the fragment-form `tweet/{mid}/{authorId}` share link,
`/user/{id}`, `/profile/{id}`, and the `tweet://` custom scheme. It is
host-agnostic after the OS has opened the app.

```text
Sources/Core/HproseInstance.swift
```

`checkAndUpdateDomain()` calls `check_upgrade` and stores the returned domain in
`domainToShare`.

## Setup checklist

1. Configure Cloudflare custom domains/routes for `dtweet.com`,
   `www.dtweet.com`, and `dl.dtweet.com`.
2. Serve the iOS and Android association files from the Worker over HTTPS with
   no redirect.
3. Add `applinks:dtweet.com` to the iOS entitlements.
4. Configure Android release intent filters for `dtweet.com` only and keep
   `assetlinks.json` in sync with release signing certificates only.
5. Build TweetWeb so `dist/index.html` uses bare local asset names.
6. Keep TweetWeb gateway detection limited to the exact dtweet host allowlist;
   `t1.w333w.site` remains a normal Leither host.
7. Keep the old `Browser fallback to dl.dtweet.com` zone Redirect Rule disabled.
8. Publish/deploy the Worker and Leither app using the owner's normal release
   process.
9. Verify these cases after publishing:
   - A `Linespider` request to a public
     `https://dtweet.com/tweet/{mid}/{authorId}` returns tweet-specific Open
     Graph HTML, and the announced image URL is publicly reachable.
   - The same path URL opens the installed app, or redirects a browser to the
     HTTP TweetWeb route with comment context preserved.
   - `https://dtweet.com/.well-known/apple-app-site-association` returns JSON.
   - `https://dtweet.com/.well-known/assetlinks.json` returns JSON.
   - `http://dtweet.com/#tweet/{mid}/{authorId}` opens the app on a device with
     the app installed.
   - `http://dtweet.com/tweet/{mid}/{authorId}` remains accepted by installed
     native apps and redirects browsers to
     `http://t1.www33.shop/#tweet/{mid}/{authorId}`.
   - `https://dtweet.com/#tweet/{mid}/{authorId}` redirects a desktop browser to
     the fragment-form route on `http://t1.www33.shop` and renders TweetWeb.
   - `https://dl.dtweet.com/#author/{authorId}` redirects a desktop browser to
     `http://t1.www33.shop/#author/{authorId}` and loads profile and tweet data.
   - An HTML `GET` to `https://dl.dtweet.com/author/{authorId}` returns `302` to
     `http://t1.www33.shop/#author/{authorId}`.
   - `https://dl.dtweet.com/index_entry.js` and both association files still
     return directly from the Worker without following the browser redirect.
   - `http://t1.fireshare.us/` still renders the legacy Leither web app.
   - `http://t1.www33.shop/` renders the Leither web app.

## Common failure modes

### `dl.dtweet.com` opens the shell but profiles and tweets do not load

This occurred on September 5, 2026 when the Worker returned TweetWeb HTML from
the HTTPS asset binding for a browser navigation. The HTML and JavaScript both
returned `200`, which made the gateway look healthy, but the browser console
showed every provider attempt failing with:

```text
SecurityError: An insecure WebSocket connection may not be initiated from a page loaded over HTTPS
```

The root cause is mixed content: TweetWeb still reaches Leither providers over
HTTP and `ws://`, so it cannot run under the HTTPS gateway origin. In
`cloudflare/dtweet-worker/src/index.js`, the `dl.dtweet.com` HTML-navigation
branch must call the same browser-fallback redirect logic used by `dtweet.com`.
Do not redirect to `http://dl.dtweet.com`; Chrome may upgrade it back to HTTPS
and create a loop.

Verify each request class independently with real `GET` requests. `HEAD` does
not enter the Worker's HTML-navigation branch:

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -H 'Accept: text/html' https://dl.dtweet.com/
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -H 'Accept: text/html' https://dl.dtweet.com/author/example-author
curl -fsS -o /dev/null -w '%{http_code} %{content_type}\n' \
  https://dl.dtweet.com/index_entry.js
curl -fsS -o /dev/null -w '%{http_code} %{content_type}\n' \
  https://dl.dtweet.com/.well-known/apple-app-site-association
```

Expected results are `302` redirects to the current
`BROWSER_FALLBACK_ORIGIN`—presently `http://t1.www33.shop`—for the two HTML
navigations and `200` responses for the asset and association file. Complete
the check in a real browser with a fragment-form author or tweet URL; fragments
are not sent to the Worker, so command-line HTTP checks alone cannot prove that
the browser preserved the route.

### Browser opens `dtweet.com` but legacy domains break

Gateway detection is probably too broad. Check that only these hosts return
true:

```text
dtweet.com
www.dtweet.com
dl.dtweet.com
```

Legacy hosts must not be treated as dtweet gateway hosts.

### Legacy domain page is blank

Inspect the rendered `index.html` script tags. If local assets contain query
strings or leading `./`, Leither may not resolve them as app objects.

The script names should be bare:

```text
hprose.js
popper.min.js
bootstrap.min.js
index_entry.js
```

### `dtweet.com` works only with Tailscale enabled

The browser fallback is using private provider routes directly. Public gateway
hosts must filter private/Tailscale addresses and route through the public
Cloudflare origin instead.

### iOS opens Safari instead of the app

Check:

- `Tweet/Tweet.entitlements` includes `applinks:dtweet.com`.
- The installed bundle ID is listed in the Worker association file.
- `https://dtweet.com/.well-known/apple-app-site-association` returns JSON with
  no redirect.
- The app was reinstalled after association changes, because iOS caches
  Universal Link associations.

### Android opens the browser instead of the app

Check:

- The installed package name is listed in `assetlinks.json`.
- The signing certificate fingerprint is listed in the Worker.
- The Android manifest has the matching App Link intent filter.
- `https://dtweet.com/.well-known/assetlinks.json` returns JSON with no
  redirect.

Do not keep old app-link hosts such as `fireshare.uk` in the Android manifest.
They create extra Play Console warnings and can make link ownership harder to
reason about.

### Android opens the debug app instead of the release app

Check:

- `assetlinks.json` does not list `us.fireshare.tweet.debug`.
- The debug build does not declare `dtweet.com` as its public app-link host.
- The Android app's debug build uses a placeholder host such as
  `debug.dtweet.invalid` with auto-verify disabled.
- Clear any manually chosen "open by default" setting for the debug app on the
  device after changing the association.
