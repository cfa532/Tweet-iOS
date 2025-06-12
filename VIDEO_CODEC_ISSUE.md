# Video Codec Compatibility Issue

## Problem
The second video uses a codec that iOS doesn't support natively. The error code `-11828` (`AVErrorDecoderNotFound`) indicates "This media format is not supported."

## Why This Happens
- **iOS supports**: H.264, HEVC/H.265, and a few other codecs
- **iOS doesn't support**: VP8, VP9, AV1, and many other codecs
- **Android supports**: A wider range of codecs, which is why the Kotlin app plays both videos

## Current Status
- First video: Works (uses a supported codec)
- Second video: Fails with "Cannot Open" error (uses an unsupported codec)

## Solutions

### 1. Server-Side Transcoding (Recommended)
The best solution is to transcode videos on the server to H.264, which is universally supported:
```bash
ffmpeg -i input.mp4 -c:v libx264 -preset medium -crf 23 -c:a aac output.mp4
```

### 2. Use VLCKit (Client-Side)
Integrate VLCKit which supports many more codecs:
```swift
// In your Podfile:
pod 'MobileVLCKit'
```

### 3. Detect and Show Warning
The current implementation now shows a user-friendly message when a video codec is unsupported.

### 4. Web-Based Player Fallback
For unsupported videos, you could open them in a WKWebView which might have broader codec support.

## Checking Video Codec
To check what codec a video uses:
```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 video.mp4
```

## Temporary Workaround
Users can:
1. Download the video file
2. Convert it using a tool like HandBrake or FFmpeg
3. Re-upload the H.264 version 