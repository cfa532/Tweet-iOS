# Upload System - Complete Documentation

**Last Updated:** October 14, 2025  
**Status:** ✅ Production Ready

---

## Overview

Comprehensive upload system supporting tweets, comments, and chat messages with multiple attachments (videos and images). Features progress tracking, background processing, auto-lock prevention, and persistent retry mechanism.

---

## Key Features

✅ **Visual Progress Dialog** - Clean UI with real-time progress  
✅ **Immediate Dialog Display** - Shows instantly when user taps Publish  
✅ **Multi-Attachment Support** - Sequential upload with per-item progress  
✅ **Simplified Messages** - "Processing video 1/3" / "Uploading image 2/3"  
✅ **Early Dialog Dismissal** - Closes after foreground work completes  
✅ **Background Polling** - Monitors server-side video processing  
✅ **Auto-Lock Prevention** - Screen stays on during active uploads  
✅ **Persistent Retry** - Recovers interrupted uploads on app relaunch  
✅ **Full Metadata** - Preserves CID, size, aspectRatio, fileName, mediaType  
✅ **Complete Localization** - English, Japanese, Simplified Chinese

---

## Architecture

### Components

**Core:**
- `UploadProgressManager.swift` - Progress state, UI updates, background detection
- `TweetUploadManager.swift` - Upload orchestration, polling, persistence
- `HproseInstance.swift` - Media processing, server communication
- `VideoConversionService.swift` - FFmpeg HLS/MP4 conversion

**UI:**
- `UploadProgressOverlay.swift` - Progress dialog
- `PendingUploadDialog.swift` - Recovery dialog for interrupted uploads
- `ContentView.swift` - Overlay integration, foreground detection

---

## Upload Flow

### New Upload (with Video)

```
1. User taps "Publish"
   └─ UploadProgressManager.startUpload() ← Dialog appears IMMEDIATELY
   └─ Composer closes
   
2. FOREGROUND PHASE (Dialog Visible)
   └─ Prepare attachments (load video data from PhotosPicker)
       ├─ Dialog: "Preparing attachments..." (10%)
   
   └─ For each attachment (sequential):
       ├─ Video:
       │   ├─ Dialog: "Processing video 1/2" (20%-50%)
       │   ├─ Check cloud drive service availability
       │   ├─ FFmpeg convert to HLS (720p + 480p)
       │   ├─ Compress HLS directory to ZIP
       │   ├─ Upload ZIP to server → Get job ID
       │   └─ Store: itemData.videoJobId = jobId
       │
       └─ Image:
           ├─ Dialog: "Uploading image 2/2" (50%-80%)
           ├─ Upload to IPFS
           ├─ Server returns CID
           └─ Store: itemData.cid = CID
   
   └─ All attachments uploaded (80%)
       ├─ Dialog: "Processing on server..." (100%)
       ├─ Remove pending upload file
       └─ Dialog CLOSES ← User can use app now!

3. BACKGROUND PHASE (Silent)
   └─ Poll video job status every 5s
       ├─ Check all job IDs: GET /process-zip/status/:jobId
       ├─ Wait for ALL jobs to complete
       └─ If ANY job fails → Entire upload fails
   
   └─ All jobs complete
       ├─ Build final attachments with actual CIDs
       ├─ Submit tweet (retry up to 2× if fails)
       └─ Toast: "Tweet posted successfully" ✅
```

### Image-Only Upload

```
1. User taps "Publish" → Dialog appears
2. Upload images (sequential) → Dialog: "Uploading image 1/2"
3. Dialog closes (10 seconds)
4. Submit tweet in background
5. Toast: "Tweet posted successfully"
```

### Retry After Interruption

```
1. App launch/foreground → Detect pendingTweetUpload.json
2. Show PendingUploadDialog
   ├─ Type, Date, Attachments, Content
   └─ [Retry Upload] [Discard]
   
3. User clicks "Retry"
   └─ IF items have job IDs:
       ├─ Check server status for ALL jobs
       ├─ IF all completed → Submit tweet immediately
       ├─ IF some processing → Continue polling in background
       └─ IF any failed → Show error
   └─ ELSE:
       ├─ Re-upload all attachments (foreground with dialog)
```

---

## Video Processing

### Cloud Drive Service Check

```swift
// Health check before video processing
GET http://{HOST}:{cloudDrivePort}/health

Response:
{
  "status": "ok",
  "message": "Server is running",
  "timestamp": "2025-10-14T..."
}
```

**If available:** Use HLS conversion  
**If unavailable:** Fall back to MP4 + IPFS

### HLS Conversion (Primary Path)

**Quality Tiers:**
- **720p** - For videos ≤720p: Uses `-c:v copy` (no re-encoding)
- **720p** - For videos >720p: Uses `libx264` with scaling
- **480p** - Always included as fallback tier

**FFmpeg Command (COPY codec for ≤720p):**
```bash
-i input.mp4 \
-c:v copy \
-c:a aac -b:a 128k \
-f hls -hls_time 4 -hls_list_size 0 \
-hls_segment_filename segment%03d.ts \
-hls_playlist_type vod \
-start_number 0 \
playlist.m3u8
```

**FFmpeg Command (libx264 for >720p or scaling):**
```bash
-i input.mp4 \
-c:v libx264 -profile:v main -level 4.0 -pix_fmt yuv420p \
-c:a aac -ar 44100 \
-vf "scale=720:-2" \
-b:v 2000k -b:a 128k \
-preset fast -g 48 -keyint_min 48 -sc_threshold 0 \
-threads 0 \
-f hls -hls_time 4 -hls_list_size 0 \
-hls_segment_filename segment%03d.ts \
-hls_playlist_type vod \
-start_number 0 \
playlist.m3u8
```

**Master Playlist:**
```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=720x1280
720p/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=480x854
480p/playlist.m3u8
```

**Upload:**
```
POST http://{HOST}:{cloudDrivePort}/process-zip
Content-Type: multipart/form-data
Body: {hls_directory}.zip

Response:
{
  "success": true,
  "message": "ZIP upload started",
  "jobId": "p1tffh27c"
}
```

### MP4 Fallback (No Cloud Drive)

```bash
-i input.mp4 \
-vf "scale='min(720,iw)':'min(720,ih)':force_original_aspect_ratio=decrease" \
-c:v libx264 -profile:v main -level 4.0 \
-pix_fmt yuv420p \
-movflags +faststart \
-b:v 2000k \
-c:a aac -b:a 128k \
output.mp4
```

Upload to IPFS via regular route.

---

## Job Polling

### Status Check

```
GET http://{HOST}:{cloudDrivePort}/process-zip/status/:jobId

Response (Processing):
{
  "status": "processing",
  "progress": 50,
  "message": "Converting video..."
}

Response (Completed):
{
  "status": "completed",
  "cid": "QmQ1VjquznaDE2bnAAJcWMPuxpDd3AHaZ2iRHjxz3U3w7c"
}

Response (Failed):
{
  "status": "failed",
  "error": "FFmpeg conversion failed"
}
```

**Polling Logic:**
- Interval: 5 seconds
- Max duration: 10 minutes (120 attempts)
- Checks ALL jobs in parallel
- Stops if ANY job fails
- Continues until ALL complete

---

## Data Structures

### PendingTweetUpload

```swift
struct PendingTweetUpload: Codable {
    let tweet: Tweet
    let itemData: [ItemData]
    let timestamp: Date
    let retryCount: Int
    let videoJobId: String? // Legacy field
}

struct ItemData: Codable {
    let identifier: String           // UUID
    let typeIdentifier: String       // UTType
    let data: Data                   // Media data
    let fileName: String             // File name
    let noResample: Bool            // Skip resampling
    let videoJobId: String?         // Server job ID (videos)
    let cid: String?                // Actual CID (all items)
    let aspectRatio: Float?         // Aspect ratio
    let fileSize: Int64?            // File size
    let mediaType: String?          // "Image", "hls_video", etc.
}
```

### MimeiFileType

```swift
struct MimeiFileType: Codable {
    let mid: String              // CID or job ID
    let type: MediaType          // .Image, .hls_video, .Audio
    let size: Int64?             // File size
    let fileName: String?        // File name
    let timestamp: Date?         // Upload time
    let aspectRatio: Float?      // Aspect ratio
    let url: String?             // Optional URL
}
```

---

## Progress Messages

**English:**
- "Preparing attachments..."
- "Processing video 1/3"
- "Uploading image 2/3"
- "Processing on server..."
- "Your tweet will be posted when ready"
- "Tweet posted successfully"

**Japanese:**
- "添付ファイルを準備中..."
- "動画を処理中 1/3"
- "画像をアップロード中 2/3"
- "サーバー処理中..."
- "準備ができ次第ツイートが投稿されます"
- "ツイートが正常に投稿されました"

**Simplified Chinese:**
- "正在准备附件..."
- "正在处理视频 1/3"
- "正在上传图片 2/3"
- "服务器处理中..."
- "准备好后将发布推文"
- "推文发布成功"

---

## Error Handling

### Preparation Errors
- **Cause:** Failed to load media data from PhotosPicker
- **Action:** Show error toast, cancel upload

### Upload Errors
- **Cause:** Network failure, server error
- **Action:** Persist to disk, show retry dialog on next app launch

### Video Processing Errors
- **Cause:** FFmpeg failure, server processing failure
- **Action:** Show error toast, mark upload as failed

### Tweet Submission Errors
- **Cause:** Network failure, invalid data
- **Action:** Retry up to 2 times with exponential backoff (2s, 4s)

---

## Configuration

### Constants

```swift
MAX_FILE_SIZE = 240 MB  // Maximum upload size
MAX_ASSET_CACHE_SIZE = 50  // Shared asset cache limit
MAX_PLAYER_CACHE_SIZE = 20  // Shared player cache limit
CACHE_EXPIRATION_SECONDS = 3600  // 1 hour
```

### FFmpeg Log Level

```swift
// In AppDelegate
FFmpegKitConfig.setLogLevel(16)  // AV_LOG_ERROR only
```

---

## Testing Checklist

- [ ] Upload single video
- [ ] Upload multiple videos
- [ ] Upload images only
- [ ] Upload video + images
- [ ] Background during FFmpeg
- [ ] Background during polling
- [ ] Retry from pending upload
- [ ] Check all metadata preserved
- [ ] Test all 3 languages
- [ ] Verify dialog appears immediately
- [ ] Verify dialog closes after foreground work

---

## Files

**Core Logic:**
- `Sources/Core/UploadProgressManager.swift`
- `Sources/Core/TweetUploadManager.swift`
- `Sources/Core/HproseInstance.swift`
- `Sources/Core/VideoConversionService.swift`

**UI:**
- `Sources/Features/MediaViews/UploadProgressOverlay.swift`
- `Sources/Features/MediaViews/PendingUploadDialog.swift`
- `Sources/App/ContentView.swift`

**Localization:**
- `Tweet/en.lproj/Localizable.strings`
- `Tweet/ja.lproj/Localizable.strings`
- `Tweet/zh-Hans.lproj/Localizable.strings`

---

## Known Limitations

1. **Foreground-only FFmpeg** - Video conversion stops if app backgrounds
2. **No partial upload** - All attachments must upload before submission
3. **No cancel button** - User cannot cancel active upload
4. **No progress persistence** - Progress resets if app crashes during upload

---

## Future Enhancements

- [ ] Background video conversion (requires Background Modes capability)
- [ ] Partial upload support (submit tweet with completed attachments)
- [ ] Cancel/pause functionality
- [ ] Progress persistence across app crashes
- [ ] Thumbnail generation optimization

