# LocalHTTPServer Comprehensive Algorithm

## Purpose
Transparent caching proxy between AVPlayer and IPFS backend. Its sole job is to persist HLS/progressive video data to disk, because AVPlayer does not cache HLS segments natively.

## Architecture
- **NWListener** on localhost (dynamic port 8080-65535, saved via PreferenceHelper)
- **One request per NWConnection** (`Connection: close` in every response)
- **TCP FIN** (`connection.send(content: nil, isComplete: true)`) signals end-of-body
- **State flags**: `_isStarting`, `_isRunning`, `_isStopping` (protected by `stateLock`)

## Request Flow
```
AVPlayer HTTP request
  → NWListener.handleConnection(NWConnection)
  → receiveNextRequest(connection) [async, withCheckedContinuation]
    → connection.receive(min:1, max:65536)
    → Parse first line: "GET /ipfs/{mediaID}/path HTTP/1.1"
    → handleRequest() → handleGetRequest()
      ├─ /health → 200 OK
      ├─ BlackList check → 404 if blacklisted
      ├─ /ipfs/{mediaID} (no filename) → handleProgressiveVideoRequest()
      ├─ Cache hit (disk file exists) → serveFile() or rewrite+serve playlist
      └─ Cache miss → getRealURL() → route by extension:
          ├─ .m3u8 → handlePlaylistRequest()
          ├─ .ts   → handleSegmentRequest() [async, deduped]
          └─ other → handleProgressiveVideoRequest()
    → completion callback is NO-OP (handlers manage connection lifecycle)
    → continuation.resume()
```

## HLS Flow

### Playlist Handling
1. **Master playlist** (master.m3u8): Fetch from IPFS, rewrite URLs to localhost, cache to disk
2. **Variant playlist** (480p/playlist.m3u8): Same fetch+rewrite+cache flow
3. **URL rewriting** (`rewritePlaylistURLs`): Regex replaces relative/absolute .m3u8/.ts URLs with `http://127.0.0.1:PORT/ipfs/mediaID/path`
4. **Disk cache stripping** (`stripPlaylistToRelativePaths`): Removes scheme://host:port for port-independent caching
5. **Critical injections**:
   - `#EXT-X-PLAYLIST-TYPE:VOD` after #EXTM3U (marks as VOD, not live)
   - `#EXT-X-ENDLIST` at EOF (without it, AVPlayer polls forever, `isPlaybackBufferFull` stays false)

### Segment Streaming (SegmentStreamDelegate)
**Design principle**: Stream bytes to AVPlayer as they arrive from IPFS. AVPlayer needs ~100-300KB (first keyframe) to transition to `.readyToPlay`, not the full 4-5MB segment.

```
IPFS URLSession dataTask
  → didReceive response:
    ├─ Send HTTP headers immediately to AVPlayer
    ├─ Include Content-Length if IPFS provides it
    ├─ If no Content-Length: omit it (Connection: close → AVPlayer uses TCP FIN for end-of-body)
    └─ headersSent = true
  → didReceive data: (multiple chunks)
    ├─ ALWAYS append to diskBuffer (cache-first design)
    ├─ If connection alive: connection.send(data) → forward to AVPlayer
    └─ If connectionDead: skip send, keep buffering for disk
  → didCompleteWithError:
    ├─ Success: write diskBuffer to disk, send TCP FIN (if connection alive)
    ├─ Error + no headers sent: sendFallbackError (500)
    ├─ Error + headers sent: send TCP FIN (AVPlayer detects incomplete)
    └─ connectionDead: write to disk only, no FIN needed
```

**Connection death detection**: `connection.send()` completion handler fires with error → set `connectionDead = true`, continue IPFS download to disk cache. This is normal — AVPlayer closes connections during adaptive bitrate switching (720p→480p).

### Segment Deduplication
- **activeDownloadsActor** (Swift actor): Tracks in-flight segment downloads by cache path
- **Flow**: Check `hasDownload(key)` → if YES, poll 0.5s intervals for 120s until file appears on disk → serve from cache
- **streamingSessions** dictionary: Tracks URLSessions by sessionKey (`mediaID/stream/relativePath`) — duplicates get `connection.cancel()` (NOT `completion()`)

## Progressive Video Proxy
- **Range request parsing**: `Range: bytes=start-end` → serve from cache if within contiguous range
- **Cache structure**: `~/mediaID/video.mp4` + `video.meta` (total size) + `video.contiguous` (contiguous bytes)
- **Concurrent limit**: Max 2 different videos downloading (primary exempt)
- **StreamingDownloadDelegate**: Fixes Content-Type to video/mp4, streams data, writes to disk contiguously
- **Parallel connections**: AVPlayer opens 3-6 simultaneous connections for same byte range — `progressiveReservations` fans out data to all from one download delegate

## Caching Strategy
- **Disk cache location**: `~/Library/Caches/{mediaID}/{path}` (HLS) or `~/Library/Caches/{mediaID}/video.mp4` (progressive)
- **Cache-first**: Always check disk before network. Cached segments served via `serveFile()` (Content-Length + FIN)
- **Corrupt playlist recovery**: If cached playlist unreadable, delete and refetch fresh
- **Background caching**: When AVPlayer closes connection mid-stream (adaptive bitrate switch), IPFS download continues to disk. Next request served from cache.

## Connection Lifecycle (Critical)
1. **Connection: close**: Every response. One request per NWConnection.
2. **TCP FIN**: Sent by response handler (sendResponse, serveFile, SegmentStreamDelegate)
3. **receiveNextRequest completion**: NO-OP. Never cancels connection. Handlers own their lifecycle.
4. **Why no cancel**: `connection.cancel()` in completion killed streaming connections mid-flight — SegmentStreamDelegate was still actively streaming when the completion fired (because `handleSegmentRequest` returns immediately, async download just started).

## Error Handling
- **BlackList**: Records failures per mediaID. Blacklisted IDs get instant 404 (no network).
- **Network failure counter**: 3 consecutive non-benign errors → emergency cleanup
- **Benign errors** (no counter): NWError 54 (connection reset), 89 (cancelled), NSURLErrorCancelled (-999)
- **Segment retry**: Up to 3 attempts with 1s/2s backoff
- **Cancellation (-999)**: Not counted as failure, no blacklist, cache preserved

## URL Resolution
- **getRealURL(mediaID)**: Thread-safe lookup in `mediaRealURLs` dictionary
- **registerAndGetURL(mediaID, realURL)**: Stores real URL, returns localhost proxy URL
- **resolveHLSURL()**: Parallel HEAD requests for master.m3u8 and playlist.m3u8 (8s worst case vs 16s sequential)
- **Initialization gating**: `canBypassInitialization()` blocks network requests until app initialized (cached content still served)
