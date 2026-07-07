/**
 * dtweet.com deep-link worker
 *
 * - /.well-known/apple-app-site-association  -> iOS Universal Links
 * - /.well-known/assetlinks.json             -> Android App Links
 * - /tweet/{tweetId}/{authorId}              -> landing page (app users never see it;
 *                                               the OS opens the app directly)
 * - /user/{userId}                           -> landing page
 * - anything else                            -> home page
 */

const IOS_TEAM_ID = "96LBXG78A7";
const IOS_BUNDLE_IDS = ["com.example.Tweet", "com.example.Tweet.debug"];
const ANDROID_APPS = [
  {
    package: "us.fireshare.tweet",
    sha256: [
      // Google Play App Signing key (Play Store installs)
      "8A:D4:2F:4C:0C:83:10:4C:22:B6:35:11:35:CE:67:11:53:98:09:D9:96:C2:EE:CB:E6:F4:82:E8:0C:60:36:6E",
      // Local upload key tweet_keystore.jks (sideloaded release builds, play + full flavors)
      "42:B9:90:AF:10:57:F6:2B:14:02:F2:14:BC:C1:F8:87:57:64:FA:AC:9C:8A:15:D2:B7:16:02:77:6B:F2:37:39",
    ],
  },
  {
    package: "us.fireshare.tweet.debug",
    sha256: [
      // debug-keystore/debug.keystore
      "90:9D:FF:B9:6B:29:6C:6D:F5:B5:99:FD:22:3C:B5:D8:B9:20:C0:E4:55:22:86:27:F1:31:84:BD:B5:E8:22:D8",
    ],
  },
];

const APP_STORE_ID = "6751131431";
const APP_STORE_URL = `https://apps.apple.com/app/id${APP_STORE_ID}`;
const PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=us.fireshare.tweet";
const WEB_APP_BASE = "http://t1.fireshare.us";
const WEB_APP_AID_HASH = "h5U5jxPr2p2tg2kMr8UeyRMNIJ_";

// mimei IDs are base64url-ish tokens; reject anything else before echoing into HTML
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.hostname === "www.dtweet.com") {
      url.hostname = "dtweet.com";
      return Response.redirect(url.toString(), 301);
    }

    const path = url.pathname;

    if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
      return json(appleAppSiteAssociation());
    }
    if (path === "/.well-known/assetlinks.json") {
      return json(assetLinks());
    }

    const segments = path.split("/").filter(Boolean);

    if (segments[0] === "tweet" && segments.length >= 2 && ID_RE.test(segments[1])) {
      const tweetId = segments[1];
      const authorId = segments.length >= 3 && ID_RE.test(segments[2]) ? segments[2] : "";
      return landingPage({
        universalLink: url.toString(),
        schemeUrl: `tweet://tweet/${tweetId}/${authorId}`,
        webUrl: `${WEB_APP_BASE}/entry?aid=${WEB_APP_AID_HASH}&ver=last#/tweet/${tweetId}/${authorId}`,
        heading: "View this post in dTweet",
      });
    }

    if ((segments[0] === "user" || segments[0] === "profile") && segments.length >= 2 && ID_RE.test(segments[1])) {
      return landingPage({
        universalLink: url.toString(),
        schemeUrl: `tweet://user/${segments[1]}`,
        webUrl: null,
        heading: "View this profile in dTweet",
      });
    }

    return landingPage({
      universalLink: `https://dtweet.com/`,
      schemeUrl: null,
      webUrl: `${WEB_APP_BASE}/entry?aid=${WEB_APP_AID_HASH}&ver=last`,
      heading: "dTweet — a decentralized micro-blog",
    });
  },
};

function json(obj) {
  return new Response(JSON.stringify(obj, null, 2), {
    headers: {
      "content-type": "application/json",
      "cache-control": "public, max-age=3600",
    },
  });
}

function appleAppSiteAssociation() {
  return {
    applinks: {
      details: [
        {
          appIDs: IOS_BUNDLE_IDS.map((b) => `${IOS_TEAM_ID}.${b}`),
          components: [
            { "/": "/tweet/*" },
            { "/": "/user/*" },
            { "/": "/profile/*" },
          ],
        },
      ],
    },
  };
}

function assetLinks() {
  return ANDROID_APPS.map((app) => ({
    relation: ["delegate_permission/common.handle_all_urls"],
    target: {
      namespace: "android_app",
      package_name: app.package,
      sha256_cert_fingerprints: app.sha256,
    },
  }));
}

function landingPage({ universalLink, schemeUrl, webUrl, heading }) {
  const openApp = schemeUrl
    ? `<a class="btn primary" href="${schemeUrl}">Open in dTweet app</a>`
    : "";
  const viewWeb = webUrl
    ? `<a class="btn" href="${webUrl}">View on web</a>`
    : "";

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}, app-argument=${universalLink}">
<title>dTweet</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         margin: 0; display: flex; min-height: 100vh; align-items: center; justify-content: center;
         background: #f5f8fa; color: #14171a; }
  @media (prefers-color-scheme: dark) { body { background: #15202b; color: #f5f8fa; } }
  .card { text-align: center; padding: 2.5rem 1.5rem; max-width: 26rem; }
  h1 { font-size: 1.4rem; margin-bottom: 2rem; }
  .btn { display: block; margin: 0.75rem auto; padding: 0.9rem 1.5rem; max-width: 18rem;
         border-radius: 9999px; border: 1px solid #1d9bf0; color: #1d9bf0;
         text-decoration: none; font-weight: 600; }
  .btn.primary { background: #1d9bf0; color: #fff; }
  .stores { margin-top: 2rem; }
  .stores a { display: inline-block; margin: 0.3rem; color: inherit; opacity: 0.8;
              text-decoration: none; font-size: 0.9rem; border: 1px solid currentColor;
              border-radius: 8px; padding: 0.5rem 1rem; }
</style>
</head>
<body>
<div class="card">
  <h1>${heading}</h1>
  ${openApp}
  ${viewWeb}
  <div class="stores">
    <p>Don't have the app yet?</p>
    <a href="${APP_STORE_URL}">&#63743; App Store</a>
    <a href="${PLAY_STORE_URL}">&#9654; Google Play</a>
  </div>
</div>
</body>
</html>`;

  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
}
