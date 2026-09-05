# Deep Linking and Browser-Compatible URLs

This document describes the `dtweet.com` deep-link setup and the rules that
keep it compatible with existing Leither web URLs such as `t1.fireshare.us` and
`t1.w333w.site`.

The goal is:

- `http://dtweet.com/#tweet/{mid}/{authorId}` opens the native app when the app
  is installed.
- The same URL opens a real web page when the app is not installed or when the
  user opens it in a desktop browser.
- Existing Leither-hosted web domains keep their original routing behavior.
- Public web access does not require Tailscale or any private network route.

## Mutable browser fallback

The browser application domain is operational configuration, not a permanent
part of the deep-link contract. The source of truth is
`BROWSER_FALLBACK_ORIGIN` in
`cloudflare/dtweet-worker/src/index.js`. Its current value is
`http://t1.w333w.site`, but the owner may replace it at any time.

In routing requirements below, “the HTTP fallback” means the value of that
constant. Concrete `w333w.site` URLs document the current deployment or a
historical migration; they must not be copied into new routing logic as a
second source of truth. When the domain changes, update the Worker constant,
the corresponding nginx/DNS configuration, and the current-value examples in
the same operation. Follow TweetWeb's
`docs/BROWSER_FALLBACK_DOMAIN_MIGRATION.md` procedure.

## URL model

| URL | Role | Expected behavior |
|---|---|---|
| `dtweet.com` | Public deep-link wrapper | iOS/Android verify it as an app-link domain. Browser navigations are redirected by the Worker to `http://t1.w333w.site`; the browser retains the fragment locally. |
| `www.dtweet.com` | Alias | Redirects permanently to `dtweet.com`. |
| `dl.dtweet.com` | Public gateway alias | Served by the same Cloudflare Worker. Browser navigations redirect to `http://t1.w333w.site`; static assets, association files, and non-navigation origin requests keep their dedicated Worker branches. Kept only for compatibility; new shared links should not need it. |
| `t1.fireshare.us`, `t1.w333w.site`, other Leither domains | Web app hosts | `t1.w333w.site` is the current browser fallback target. These hosts keep normal Leither route discovery and must not be forced through dtweet gateway behavior. |
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
   redirects to `http://t1.w333w.site` and the browser retains the fragment.
   For a legacy `/tweet/...` path, the Worker explicitly redirects to
   `http://t1.w333w.site/#tweet/...`, moving its query into the fragment route.
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

The Worker has three jobs:

1. Serve iOS Universal Links association:
   `/.well-known/apple-app-site-association`
2. Serve Android App Links association:
   `/.well-known/assetlinks.json`
3. Redirect browser navigations on both `dtweet.com` and `dl.dtweet.com` to
   `http://t1.w333w.site`, while keeping `dl.dtweet.com` static assets,
   association files, and non-navigation origin requests on their existing
   Worker branches.

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
| Tweet action-bar share buttons | `http://dtweet.com/#tweet/{mid}/{authorId}` | Standard app-link URL with browser fallback, in feed, detail, comment, media, and fullscreen contexts. |
| Dropdown menu to share, feed and detail view alike | `http://{check_upgrade domain}/#tweet/{mid}/{authorId}` | Uses the backend-controlled domain and TweetWeb's external share-link format, with `dtweet.com` as fallback. |

The provider-IP format —
`http://{author public IPv4}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}`
— is no longer selected by any share action. It remains implemented as the
DNS-free format; see `getPublicIPv4BaseUrl` in `TweetActionBarView.swift` for how
the URL is composed and which addresses the validator rejects.

Comment shares append:

```text
?fromComment=true&parentTweetId={mid}&parentAuthorId={mid}
```

For provider-IP URLs, the comment parameters live inside the IP-entry hash
route. For domain URLs, they are part of the external fragment-form share link.

## iOS implementation map

```text
Tweet/Tweet.entitlements
```

Contains `applinks:dtweet.com`.

```text
Sources/App/AppConfig.swift
```

Contains `shareDomain = "http://dtweet.com"`.

```text
Sources/Tweet/UIKit/TweetActionBarView.swift
```

Defines `TweetShareLinkStyle` and `buildShareText`. Every action bar uses the
dtweet deep-link style, and dropdown sharing — feed and detail view alike — uses
the `check_upgrade` domain via `buildFeedMenuShareItems`. The provider-IP style
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
   - `https://dtweet.com/.well-known/apple-app-site-association` returns JSON.
   - `https://dtweet.com/.well-known/assetlinks.json` returns JSON.
   - `http://dtweet.com/#tweet/{mid}/{authorId}` opens the app on a device with
     the app installed.
   - `http://dtweet.com/tweet/{mid}/{authorId}` remains accepted by installed
     native apps and redirects browsers to
     `http://t1.w333w.site/#tweet/{mid}/{authorId}`.
   - `https://dtweet.com/#tweet/{mid}/{authorId}` redirects a desktop browser to
     the fragment-form route on `http://t1.w333w.site` and renders TweetWeb.
   - `https://dl.dtweet.com/#author/{authorId}` redirects a desktop browser to
     `http://t1.w333w.site/#author/{authorId}` and loads profile and tweet data.
   - An HTML `GET` to `https://dl.dtweet.com/author/{authorId}` returns `302` to
     `http://t1.w333w.site/#author/{authorId}`.
   - `https://dl.dtweet.com/index_entry.js` and both association files still
     return directly from the Worker without following the browser redirect.
   - `http://t1.fireshare.us/` still renders the legacy Leither web app.
   - `http://t1.w333w.site/` renders the Leither web app.

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
`BROWSER_FALLBACK_ORIGIN`—presently `http://t1.w333w.site`—for the two HTML
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
