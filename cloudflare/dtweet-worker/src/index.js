/**
 * dtweet.com deep-link worker
 *
 * - /.well-known/apple-app-site-association  -> iOS Universal Links
 * - /.well-known/assetlinks.json             -> Android App Links
 * - browser navigations                      -> redirected to the HTTP
 *   TweetWeb host, so users without the app see the real web page.
 *   Legacy /tweet/* and author paths are canonicalized to /#tweet/* and
 *   /#author/* respectively.
 * - non-navigation requests                  -> reverse-proxied to Leither
 *
 * Users WITH the app never reach this worker for supported fragment-form links: the OS
 * verifies the well-known files and opens the app directly.
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
];

const APP_STORE_ID = "6751131431";

// ksbox via nginx (port 80): dl.dtweet.com is a same-zone DNS record pointing
// at the server; nginx's dtweet.com.conf (*.dtweet.com) proxies to Leither :8080
// preserving the Host header, so Leither domain routing can take over later.
const ORIGIN = "http://dl.dtweet.com";
const BROWSER_FALLBACK_ORIGIN = "http://t1.w3w3.store";
const STATIC_ASSETS = new Set([
  "/index_entry.js",
  "/hprose.js",
  "/popper.min.js",
  "/bootstrap.min.js",
  "/gtag.js",
  "/ic_splash.png",
]);
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname === "www.dtweet.com") {
      url.hostname = "dtweet.com";
      return Response.redirect(url.toString(), 301);
    }

    const path = url.pathname;

    if (request.method === "GET" && STATIC_ASSETS.has(path)) {
      const asset = await env.ASSETS.fetch(request);
      const response = new Response(asset.body, asset);
      response.headers.set("x-dtweet-static-asset", path);
      return response;
    }

    // Keep dl.dtweet.com on HTTPS. Modern browsers upgrade HTTP navigations,
    // so redirecting HTTPS back to HTTP creates an upgrade/downgrade loop.
    // Proxy through Cloudflare instead; subrequests to the HTTP origin skip
    // this route and reach nginx directly.
    if (url.hostname === "dl.dtweet.com") {
      if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
        return json(appleAppSiteAssociation());
      }
      if (path === "/.well-known/assetlinks.json") {
        return json(assetLinks());
      }
      if (isHtmlNavigation(request)) {
        return env.ASSETS.fetch(request);
      }
      const originUrl = ORIGIN + path + url.search;
      return fetch(originUrl, new Request(originUrl, request));
    }

    if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
      return json(appleAppSiteAssociation());
    }
    if (path === "/.well-known/assetlinks.json") {
      return json(assetLinks());
    }

    return proxyToTweetWeb(request, url);
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
            { "/": "/", "#": "tweet/*" },
            { "/": "/", "#": "author/*" },
            { "/": "/tweet/*" },
            { "/": "/author/*" },
          ],
        },
      ],
    },
  };
}

function assetLinks() {
  return ANDROID_APPS.map((app) => ({
    relation: [
      "delegate_permission/common.handle_all_urls",
      "delegate_permission/common.get_login_creds",
    ],
    target: {
      namespace: "android_app",
      package_name: app.package,
      sha256_cert_fingerprints: app.sha256,
    },
  }));
}

function isHtmlNavigation(request) {
  return request.method === "GET" &&
    (request.headers.get("accept") || "").includes("text/html");
}

async function proxyToTweetWeb(request, url) {
  const path = url.pathname;

  // App users never get here: iOS and Android claim supported dtweet.com links
  // before browser navigation. Browser fallback uses a separate HTTP host so
  // TweetWeb can contact HTTP/ws:// Leither providers without mixed content.
  if (isHtmlNavigation(request)) {
    const externalRoute = path.match(/^\/(tweet|author)(\/.*)$/);
    if (externalRoute) {
      return Response.redirect(
        `${BROWSER_FALLBACK_ORIGIN}/#${externalRoute[1]}${externalRoute[2]}${url.search}`,
        302,
      );
    }
    return Response.redirect(BROWSER_FALLBACK_ORIGIN + path + url.search, 302);
  }

  // Non-navigation requests (e.g. stray /webapi/ RPC posts): proxy to Leither.
  const originUrl = ORIGIN + path + url.search;
  return fetch(originUrl, new Request(originUrl, request));
}
