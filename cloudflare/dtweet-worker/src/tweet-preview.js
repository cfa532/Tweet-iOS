// Preview crawlers need HTML before TweetWeb's JavaScript runs. Keep this
// separate from browser navigation, which must still redirect to the HTTP app.
import { connect } from "cloudflare:sockets";

const PREVIEW_CRAWLER = /Linespider|facebookexternalhit|Facebot|Twitterbot|LinkedInBot|Slackbot|Discordbot|WhatsApp|TelegramBot/i;
const MIMEI_ID = /^[A-Za-z0-9_-]{27}$/;
const GUEST_ID = "000000000000000000000000000";

export async function tweetPreview(request, url, env, origin) {
  const route = url.pathname.match(/^\/tweet\/([A-Za-z0-9_-]{27})\/([A-Za-z0-9_-]{27})(\/preview-image)?\/?$/);
  if (!route) return null;
  const isImage = route[3] === "/preview-image";
  // Image loaders need not use the page crawler's user agent. This endpoint
  // resolves only the public tweet's selected attachment, never an input URL.
  if (isImage ? !["GET", "HEAD"].includes(request.method)
    : request.method !== "GET" || !PREVIEW_CRAWLER.test(request.headers.get("user-agent") || "")) {
    return null;
  }

  // One deadline covers discovery and all node reads, including losing races.
  const signal = AbortSignal.timeout(8000);
  const appId = env.PREVIEW_APP_ID;
  const [, tweetId, authorId] = route;
  const browserURL = `${origin}/#tweet/${tweetId}/${authorId}${url.search}`;
  const canonicalURL = `https://dtweet.com/tweet/${tweetId}/${authorId}${url.search}`;
  const headers = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "vary": "User-Agent, Accept",
    "x-content-type-options": "nosniff",
  };

  try {
    if (!MIMEI_ID.test(appId || "")) throw new Error("PREVIEW_APP_ID is not configured");
    const parentAuthorId = url.searchParams.get("parentAuthorId");
    const storageOwnerId = url.searchParams.get("fromComment") === "true" && MIMEI_ID.test(parentAuthorId || "")
      ? parentAuthorId : authorId;
    const source = await readTweet(tweetId, authorId, storageOwnerId, origin, appId, signal);
    if (source.tweet.isPrivate) {
      return new Response("Private tweet", { status: 403, headers });
    }

    let mediaSource = source;
    // Match native sharing: a quote with no attachments uses the original's
    // image. Read only one quoted level and never expose private quoted data.
    if (!source.tweet.attachments?.length && MIMEI_ID.test(source.tweet.originalTweetId || "") && MIMEI_ID.test(source.tweet.originalAuthorId || "")) {
      const original = await readTweet(
        source.tweet.originalTweetId, source.tweet.originalAuthorId,
        source.tweet.originalAuthorId, origin, appId, signal,
      );
      if (!original.tweet.isPrivate) mediaSource = original;
    }

    const title = excerpt(source.tweet.title || "", 100) || excerpt(source.tweet.content || "", 100) || "Tweet";
    const description = excerpt(source.tweet.content || "", 240) || "View this tweet on Tweet.";
    // The first file owns the card. Never scan later files for an image when
    // the first is a video without a poster, audio, or a document.
    const attachment = mediaSource.tweet.attachments?.[0];
    const attachmentType = attachment?.type?.toLowerCase();
    const mid = attachmentType === "image" ? attachment.previewMid || attachment.mid
      : ["video", "hls_video"].includes(attachmentType) ? attachment.previewMid : null;
    let imageURL = "https://dtweet.com/ic_splash.png";
    if (mid) {
      if (!/^[A-Za-z0-9_-]+$/.test(mid || "")) throw new Error("Invalid image reference");
      if (isImage) {
        const upstream = await providerData(new URL(`${mediaSource.route}/${mid.length > 27 ? "ipfs" : "mm"}/${mid}`), signal, 8 * 1024 * 1024);
        const type = upstream.contentType.split(";")[0].trim().toLowerCase();
        // This response lives on our public domain; serve raster image bytes
        // only, so a provider cannot turn an image URL into active HTML/SVG.
        if (!["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif"].includes(type)) {
          throw new Error(`Provider returned unsupported image type: ${type}`);
        }
        return new Response(request.method === "HEAD" ? null : upstream.body, {
          headers: {
            "content-type": type,
            "content-length": String(upstream.body.byteLength),
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
          },
        });
      }
      imageURL = `https://dtweet.com/tweet/${tweetId}/${authorId}/preview-image${url.search}`;
    } else if (isImage) {
      return new Response("No preview image", { status: 404, headers });
    }

    return new Response(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>${escapeHTML(title)}</title>
<meta property="og:type" content="article">
<meta property="og:site_name" content="Tweet">
<meta property="og:url" content="${escapeHTML(canonicalURL)}">
<meta property="og:title" content="${escapeHTML(title)}">
<meta property="og:description" content="${escapeHTML(description)}">
<meta property="og:image" content="${escapeHTML(imageURL)}">
<meta name="twitter:card" content="summary_large_image">
</head><body><a href="${escapeHTML(browserURL)}">Open tweet</a></body></html>`, { headers });
  } catch (error) {
    console.error(isImage ? "Tweet preview image failed" : "Tweet preview failed", tweetId, String(error));
    // Report failure instead of caching an invented card for unavailable data.
    return new Response(`<a href="${escapeHTML(browserURL)}">Open tweet</a>`, { status: 503, headers });
  }
}

async function entry(route, appId, name, params, signal) {
  const url = new URL("/entry", route);
  url.search = new URLSearchParams({ aid: appId, ver: "last", version: "v2", entry: name, ...params });
  const response = await providerData(url, signal);
  const envelope = JSON.parse(new TextDecoder().decode(response.body));
  if (envelope?.success !== true || envelope.data == null) {
    throw new Error(`${name}: ${envelope?.message || "No data"}`);
  }
  return envelope.data;
}

async function providers(origin, mid, signal) {
  const url = new URL("/getvar", origin);
  url.search = new URLSearchParams({ name: "mmprovs", arg0: mid });
  const response = await fetch(url, { signal, redirect: "manual", headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`Provider discovery: HTTP ${response.status}`);
  const nodes = await response.json();
  if (!Array.isArray(nodes) || nodes.length === 0) throw new Error("No providers");
  // Use one public IPv4 endpoint per node. Private announcements are valid
  // Leither routes, but cannot serve a public chat preview.
  const routes = nodes.map((node) => node.Addrs.map((address) => {
    const match = address.match(/^\/ip4\/([0-9.]+)\/tcp\/(\d+)$/);
    return match ? publicIPv4Origin(`${match[1]}:${match[2]}`) : null;
  }).find(Boolean)).filter(Boolean);
  if (routes.length === 0) throw new Error("No public preview providers");
  return routes.slice(0, 3);
}

async function readTweet(tweetId, authorId, storageOwnerId, origin, appId, signal) {
  const read = async (route, readSignal) => {
    const tweet = await entry(route, appId, "get_tweet", { tweetid: tweetId, appuserid: GUEST_ID }, readSignal);
    if (tweet?.mid !== tweetId || tweet.authorId !== authorId) throw new Error("Tweet identity mismatch");
    return { tweet, route };
  };
  // Ordinary reads only: previewing a link must not force synchronization.
  // A new tweet can be absent on an author provider; discover the tweet itself
  // once in that case, preserving the shared clients' author-first policy.
  try {
    const authorRoutes = await providers(origin, storageOwnerId, signal);
    const authorRoute = await firstProviderRead(authorRoutes, async (route, readSignal) => {
      const user = await entry(route, appId, "get_user", { userid: storageOwnerId }, readSignal);
      if (user?.mid !== storageOwnerId) throw new Error("Provider cannot serve the author");
      return route;
    }, signal);
    return await read(authorRoute, signal);
  } catch {
    const tweetRoutes = await providers(origin, tweetId, signal);
    return firstProviderRead(tweetRoutes, read, signal);
  }
}

async function firstProviderRead(routes, read, signal) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal.reason);
  signal.addEventListener("abort", abort, { once: true });
  try {
    signal.throwIfAborted();
    return await Promise.any(routes.map((route) => read(route, controller.signal)));
  } finally {
    // Close losing sockets before another read starts; Workers limit the
    // number of open connections per request.
    controller.abort();
    signal.removeEventListener("abort", abort);
  }
}

async function providerData(url, signal, maxBytes = 1024 * 1024) {
  // Worker fetch rejects bare IPs. Leither's nid forwarding requires a system
  // session, so use its normal anonymous HTTP entry on the announced node.
  // HTTP/1.0 + Connection: close gives an uncompressed, EOF-delimited response
  // without implementing a general HTTP client or following redirects.
  signal.throwIfAborted();
  const socket = connect({ hostname: url.hostname, port: Number(url.port || 80) });
  const abort = () => { void socket.close().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  try {
    const writer = socket.writable.getWriter();
    try {
      await writer.write(new TextEncoder().encode(
        `GET ${url.pathname}${url.search} HTTP/1.0\r\nHost: ${url.host}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n`,
      ));
    } finally {
      writer.releaseLock();
    }
    const reader = socket.readable.getReader();
    const chunks = [];
    let bytes = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > maxBytes) throw new Error(`Preview response exceeds ${maxBytes} bytes`);
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    signal.throwIfAborted();
    // Keep binary media intact. Only headers and JSON entry callers are
    // decoded as text; JPEG/PNG data must never pass through TextDecoder.
    const response = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) {
      response.set(chunk, offset);
      offset += chunk.byteLength;
    }
    let boundary = -1;
    for (let i = 0; i + 3 < bytes; i++) {
      if (response[i] === 13 && response[i + 1] === 10 && response[i + 2] === 13 && response[i + 3] === 10) {
        boundary = i;
        break;
      }
    }
    if (boundary === -1) throw new Error("Invalid provider HTTP response");
    const headers = new TextDecoder().decode(response.subarray(0, boundary));
    if (!/^HTTP\/1\.[01] 2\d\d(?: |\r\n)/.test(headers)) {
      throw new Error(`Provider ${headers.split("\r\n")[0]}`);
    }
    const contentType = headers.match(/^content-type:\s*([^\r\n]+)/im)?.[1] || "";
    return { body: response.subarray(boundary + 4), contentType };
  } finally {
    signal.removeEventListener("abort", abort);
    await socket.close().catch(() => {});
  }
}

function publicIPv4Origin(address) {
  // Node discovery intentionally returns private routes when none are public.
  // A chat service must be able to fetch its preview image from the internet.
  const match = typeof address === "string" && address.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d+)$/);
  if (!match) return null;
  const [a, b, c, d, port] = match.slice(1).map(Number);
  if ([a, b, c, d].some((part) => part > 255) || port < 1 || port > 65535 ||
      a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
      (a === 192 && b === 0 && (c === 0 || c === 2)) || (a === 192 && b === 88 && c === 99) ||
      (a === 198 && b >= 18 && b <= 19) || (a === 198 && b === 51 && c === 100) ||
      (a === 203 && b === 0 && c === 113)) return null;
  return `http://${a}.${b}.${c}.${d}:${port}`;
}

function excerpt(value, limit) {
  const text = value.replace(/\s+/g, " ").trim();
  const characters = Array.from(text);
  return characters.length > limit ? characters.slice(0, limit).join("") + "…" : text;
}

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]));
}
