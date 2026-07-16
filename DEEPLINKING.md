# Deep Linking and Browser-Compatible URLs

This document describes the `dtweet.com` deep-link setup and the rules that
keep it compatible with existing Leither web URLs such as `t1.fireshare.us` and
`t1.www333.store`.

The goal is:

- `http://dtweet.com/tweet/{mid}/{authorId}` opens the native app when the app
  is installed.
- The same URL opens a real web page when the app is not installed or when the
  user opens it in a desktop browser.
- Existing Leither-hosted web domains keep their original routing behavior.
- Public web access does not require Tailscale or any private network route.

## URL model

| URL | Role | Expected behavior |
|---|---|---|
| `dtweet.com` | Public deep-link and web fallback host | iOS/Android verify it as an app-link domain. Browsers receive the TweetWeb app from the Cloudflare Worker. |
| `www.dtweet.com` | Alias | Redirects permanently to `dtweet.com`. |
| `dl.dtweet.com` | Public gateway alias | Served by the same Cloudflare Worker and static assets. Kept only for compatibility; new shared links should not need it. |
| `t1.fireshare.us`, `t1.www333.store`, other Leither domains | Legacy web app hosts | Must keep using normal Leither route discovery. Do not force these through the dtweet gateway behavior. |
| check_upgrade domain | Backend-controlled share domain | Used by some existing share paths and user settings. Independent of `dtweet.com`. |
| provider IP entry URL | Direct node fallback | `http://{providerIP}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}`. Works without DNS. |

Use `dtweet.com` for share links that should behave like universal/app links.
Do not share `dl.dtweet.com` as the primary public link unless a specific
compatibility case needs it.

## Request flow

### App installed

1. The user taps `http://dtweet.com/tweet/{mid}/{authorId}` or
   `https://dtweet.com/tweet/{mid}/{authorId}`.
2. iOS Universal Links or Android App Links check the association file already
   cached from `https://dtweet.com/.well-known/...`.
3. The OS opens the native app before the normal browser navigation completes.
4. The app parses `/tweet/{mid}/{authorId}` and opens the tweet.

The native app does not depend on the Worker serving the tweet page for this
case. The Worker only needs to serve valid association files over HTTPS.

### App not installed, or desktop browser

1. The browser opens `dtweet.com`.
2. The Cloudflare Worker serves the TweetWeb bundle from its static assets.
3. TweetWeb runs on the public gateway host and sends API/media requests through
   the same public origin when needed.
4. Private routes, including Tailscale `100.64.0.0/10` addresses, are filtered
   out for the public gateway so browsers do not hit Private Network Access
   blocks.

This is why `dtweet.com` can be a browser URL without requiring Tailscale.

### Existing Leither domains

When the page host is `t1.fireshare.us`, `t1.www333.store`, or another normal
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
3. Serve the browser fallback app for `dtweet.com`, `www.dtweet.com`, and
   `dl.dtweet.com`.

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

Do not make `dtweet.com` browser navigation redirect to `dl.dtweet.com` as a
required step. The compatible setup is for `dtweet.com` itself to be
browser-openable while `dl.dtweet.com` remains only an alias.

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

Current path components:

```text
/tweet/*
/user/*
/profile/*
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

Current packages:

```text
us.fireshare.tweet
us.fireshare.tweet.debug
```

Keep all required SHA-256 fingerprints in the Worker:

- Google Play App Signing key
- local upload key used by release sideloads
- debug keystore for debug builds

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
- Legacy hosts such as `t1.fireshare.us` and `t1.www333.store` must return
  false from `isPublicWebGatewayHost()`.

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
| Feed share button, plain tweet rows | `http://dtweet.com/tweet/{mid}/{authorId}` | Standard app-link URL with browser fallback. |
| Detail-view share button | `http://{check_upgrade domain}/tweet/{mid}/{authorId}` | Preserves backend-controlled legacy behavior. |
| Detail-view dropdown menu to share | `http://{author provider IP}/entry?aid={appIdHash}&ver=last#/tweet/{mid}/{authorId}` | Works without DNS or app-link setup. |
| Comment rows, fullscreen player, media browser | check_upgrade domain | Existing behavior. |

Comment shares append:

```text
?fromComment=true&parentTweetId={mid}&parentAuthorId={mid}
```

For provider-IP URLs, the comment parameters live inside the hash route.

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

Defines `TweetShareLinkStyle` and `buildShareText`. Feed cells use the dtweet
deep-link style. Detail dropdown sharing uses provider-IP format.

```text
Sources/Tweet/TweetActionButtonsView.swift
```

SwiftUI action bar. `isInDetailView: true` uses the check_upgrade domain;
normal feed sharing uses the dtweet deep-link format.

```text
Sources/Utils/DeeplinkManager.swift
```

Parses `/tweet/{mid}/{authorId}`, `/user/{id}`, `/profile/{id}`, and the
`tweet://` custom scheme. It is host-agnostic after the OS has opened the app.

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
4. Configure Android intent filters for `dtweet.com` and keep `assetlinks.json`
   in sync with all signing certificates.
5. Build TweetWeb so `dist/index.html` uses bare local asset names.
6. Keep TweetWeb gateway detection limited to the exact dtweet host allowlist.
7. Publish/deploy the Worker and Leither app using the owner's normal release
   process.
8. Verify these cases after publishing:
   - `https://dtweet.com/.well-known/apple-app-site-association` returns JSON.
   - `https://dtweet.com/.well-known/assetlinks.json` returns JSON.
   - `http://dtweet.com/tweet/{mid}/{authorId}` opens the app on a device with
     the app installed.
   - `https://dtweet.com/tweet/{mid}/{authorId}` renders TweetWeb in a desktop
     browser.
   - `http://t1.fireshare.us/` still renders the legacy Leither web app.
   - `http://t1.www333.store/` still renders the legacy Leither web app.

## Common failure modes

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
