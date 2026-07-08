/**
 * dtweet.com deep-link worker
 *
 * - /.well-known/apple-app-site-association  -> iOS Universal Links
 * - /.well-known/assetlinks.json             -> Android App Links
 * - everything else                          -> reverse-proxied to the nginx
 *   origin serving TweetWeb, so users without the app see the real web page.
 *   (/user/* and /profile/* are rewritten to TweetWeb's /author/* route.)
 *
 * Users WITH the app never reach this worker for /tweet/* links: the OS
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
  {
    package: "us.fireshare.tweet.debug",
    sha256: [
      // debug-keystore/debug.keystore
      "90:9D:FF:B9:6B:29:6C:6D:F5:B5:99:FD:22:3C:B5:D8:B9:20:C0:E4:55:22:86:27:F1:31:84:BD:B5:E8:22:D8",
    ],
  },
];

const APP_STORE_ID = "6751131431";

// ksbox via nginx (port 80): dl.dtweet.com is a same-zone DNS record pointing
// at the server; nginx's dtweet.com.conf (*.dtweet.com) proxies to Leither :8080
// preserving the Host header, so Leither domain routing can take over later.
const ORIGIN = "http://dl.dtweet.com";
// "tweet1" app on that node — history-mode router handles /tweet/:tweetId/:authorId?
// and /author/:authorId client-side once the entry HTML is loaded
const ENTRY_PATH = "/entry?aid=heWgeGkeBX2gaENbIBS_Iy1mdTS&ver=last";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.hostname === "www.dtweet.com") {
      url.hostname = "dtweet.com";
      return Response.redirect(url.toString(), 301);
    }

    const path = url.pathname;

    // dl.dtweet.com is the http-only web host. Browsers speculatively upgrade
    // http links to https; redirecting https back to http signals "upgrade
    // failed" and they settle on http silently. Plain http passes through to
    // the origin (same-zone subrequests skip this worker, so no recursion).
    if (url.hostname === "dl.dtweet.com") {
      if (path === "/.well-known/apple-app-site-association" || path === "/apple-app-site-association") {
        return json(appleAppSiteAssociation());
      }
      if (path === "/.well-known/assetlinks.json") {
        return json(assetLinks());
      }
      if (url.protocol === "https:") {
        url.protocol = "http:";
        return Response.redirect(url.toString(), 301);
      }
      return fetch(request);
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

async function proxyToTweetWeb(request, url) {
  // App deep-link paths use /user|/profile; TweetWeb's route is /author
  const path = url.pathname.replace(/^\/(user|profile)(\/|$)/, "/author$2");

  // Leither/TweetWeb is http-only: the app calls http://<host>/webapi/, which
  // an https page cannot do (mixed content). So browser page-loads are sent to
  // the http-only web host, where Leither's domain routing serves everything.
  // App users never get here — the OS opens the app before any HTTP happens.
  const wantsHTML = (request.headers.get("accept") || "").includes("text/html");
  if (request.method === "GET" && wantsHTML) {
    return Response.redirect("http://dl.dtweet.com" + path + url.search, 302);
  }

  // Non-navigation requests (e.g. stray /webapi/ RPC posts): proxy to Leither.
  const originUrl = ORIGIN + path + url.search;
  return fetch(originUrl, new Request(originUrl, request));
}
