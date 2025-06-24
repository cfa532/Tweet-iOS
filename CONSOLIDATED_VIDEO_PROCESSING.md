# Consolidated Video Processing System

This document explains the consolidated video processing system implemented in the Tweet iOS app, which handles video uploads, backend conversion to HLS, and multi-resolution adaptive streaming playback.

## Overview

The consolidated video processing system provides:
- **Backend-based video conversion**: Videos are uploaded to the server and converted to HLS using FFmpeg
- **Multi-resolution HLS support**: Server generates adaptive bitrate streams (480p, 720p) with master playlists
- **Automatic quality selection**: Client-side players automatically select the best quality based on network conditions
- **Backward compatibility**: Fallback support for single-resolution HLS streams
- **Wide format support**: Handles various video formats through server-side conversion

## Architecture

### Core Components

1. **VideoProcessor** (`Sources/Core/VideoProcessor.swift`)
   - Main video processing coordinator
   - Detects media types and handles video uploads to backend
   - Extracts video metadata (aspect ratio, dimensions)

2. **HLSVideoProcessor** (`Sources/Core/HLSVideoProcessor.swift`)
   - Video metadata extraction for backend-based processing
   - Aspect ratio detection with multiple fallback approaches
   - Format compatibility checking

3. **Updated HproseInstance** (`Sources/Core/HproseInstance.swift`)
   - Modified video upload pipeline to use backend conversion
   - Automatic video upload to `/convert-video` endpoint
   - Returns CID for converted HLS streams

4. **Multi-Resolution HLS Players**
   - **SimpleVideoPlayer**: Basic HLS player with custom controls
   - **AdaptiveVideoPlayer**: Advanced player with quality selection UI
   - **HLSVideoPlayerWithControls**: Specialized HLS player with enhanced controls

## Multi-Resolution HLS Support

### Server-Side HLS Generation

The backend server generates multi-resolution HLS streams with the following structure:
```
480p/
720p/
master.m3u8
```

- **480p/**: Contains 480p quality segments and playlist
- **720p/**: Contains 720p quality segments and playlist  
- **master.m3u8**: Master playlist that references both quality levels

### Client-Side Adaptive Streaming

The video players automatically handle multi-resolution HLS:

1. **Master Playlist Detection**: Players first try to load `master.m3u8`
2. **Automatic Quality Selection**: AVPlayer automatically selects the best quality based on:
   - Available bandwidth
   - Device capabilities
   - Network conditions
   - User preferences
3. **Fallback Support**: If `master.m3u8` doesn't exist, falls back to `playlist.m3u8` for single-resolution streams

### Quality Levels

The system supports multiple quality levels for adaptive streaming:
- **720p High Quality**: 2 Mbps video, 192 Kbps audio
- **480p Medium Quality**: 1 Mbps video, 128 Kbps audio
- **Auto Selection**: Player automatically switches between qualities

## Key Features

### 1. Backend-Based Video Conversion

Videos are uploaded to the server and converted using FFmpeg:
- **Server Endpoint**: `/convert-video`
- **Input**: Multipart form data with video file
- **Output**: Multi-resolution HLS streams stored via Leither service
- **Response**: CID for the converted video

### 2. Multi-Resolution HLS Playback

The video players support adaptive bitrate streaming:
- **Master Playlist Support**: Automatically detects and uses `master.m3u8`
- **Quality Switching**: Seamlessly switches between quality levels
- **Fallback Handling**: Gracefully falls back to single-resolution streams
- **Error Recovery**: Handles network issues and quality switching errors

### 3. Wide Format Support

The server handles various video formats:
- **Common Formats**: MP4, MOV, M4V, 3GP
- **Windows Formats**: AVI, WMV, ASF
- **Web Formats**: FLV, F4V, WebM
- **Linux/Open Formats**: MKV, OGV, OGG
- **Other Formats**: TS, MTS, M2TS, VOB, DAT

### 4. Smart Format Detection

The system includes intelligent format detection:
- **File Extension Check**: Quick check based on file extension
- **AVFoundation Compatibility**: Deep check using AVFoundation's capabilities
- **Server-Side Validation**: Backend validates and processes supported formats

## Usage

### Basic Video Upload (Automatic Multi-Resolution HLS)

```swift
// The system automatically uploads videos to backend for HLS conversion
let videoData = // ... video data from camera or photo picker
let mimeiFile = try await HproseInstance.shared.uploadToIPFS(
    data: videoData,
    typeIdentifier: "public.movie",
    fileName: "my_video.mp4"
)
// Returns CID pointing to multi-resolution HLS stream
```

### Playing Multi-Resolution HLS Streams

```swift
// SimpleVideoPlayer automatically handles multi-resolution HLS
SimpleVideoPlayer(
    url: URL(string: "https://example.com/cid/")!, // Points to directory with master.m3u8
    autoPlay: true,
    isVisible: true
)

// AdaptiveVideoPlayer with quality selection UI
AdaptiveVideoPlayer(
    videoURL: URL(string: "https://example.com/cid/")!
)

// HLSVideoPlayerWithControls for enhanced playback
HLSVideoPlayerWithControls(
    videoURL: URL(string: "https://example.com/cid/")!,
    aspectRatio: 16.0/9.0
)
```

### Video Metadata Extraction

```swift
let videoProcessor = VideoProcessor.shared

// Get video aspect ratio
let aspectRatio = try await videoProcessor.getVideoAspectRatio(url: videoURL)

// Get video dimensions
let dimensions = await videoProcessor.getVideoDimensions(url: videoURL)

// Check format compatibility
let isSupported = videoProcessor.isSupportedVideoFormat("video.avi")
```

### Handling Different Video Formats

```swift
// The system automatically handles various formats through backend conversion
let formats = ["video.mp4", "video.avi", "video.mkv", "video.flv", "video.webm"]

for format in formats {
    let videoData = // ... get video data for format
    
    // Upload to backend for conversion
    let mimeiFile = try await HproseInstance.shared.uploadToIPFS(
        data: videoData,
        typeIdentifier: "public.movie",
        fileName: format
    )
    
    // The returned CID points to multi-resolution HLS stream
    print("Successfully converted \(format) to multi-resolution HLS")
}
```

## Server Integration

### Upload Request Format

The client sends multipart form data to `/convert-video`:

```swift
// Multipart form data structure
let formData = [
    "videoFile": videoData,
    "filename": fileName,
    "referenceId": referenceId
]
```

### Server Response

The server returns a JSON response with the CID:

```json
{
    "success": true,
    "cid": "QmX...",
    "message": "Video converted successfully"
}
```

### Error Handling

The system handles various error scenarios:
- **HTTP Status Codes**: 400 (Bad Request), 413 (Payload Too Large), 500 (Internal Server Error)
- **Network Errors**: Connection timeouts, DNS failures
- **Format Errors**: Unsupported video formats
- **Conversion Errors**: FFmpeg processing failures

## Configuration

### Video Upload Settings

```swift
// Configure video upload parameters
let uploadConfig = VideoUploadConfig(
    maxFileSize: 100 * 1024 * 1024, // 100MB
    supportedFormats: ["mp4", "mov", "avi", "mkv", "flv", "webm"],
    timeout: 300 // 5 minutes
)
```

### HLS Playback Settings

```swift
// Configure HLS playback parameters
let playbackConfig = HLSPlaybackConfig(
    preferredForwardBufferDuration: 10.0,
    maxBufferDuration: 30.0,
    autoQualitySelection: true
)
```

## Migration from Client-Side FFmpeg

### Removed Components

1. **FFmpeg Dependencies**
   - Removed FFmpeg-iOS pod
   - Removed FFmpegWrapper.c/h
   - Removed client-side HLS conversion

2. **Legacy Methods**
   - Removed `uploadHLSArchive`
   - Removed `convertToHLS`
   - Removed `createAdaptiveHLS`

### Updated Components

1. **Video Upload Pipeline**
   - Updated to use backend conversion
   - Added multipart form data handling
   - Enhanced error handling

2. **Video Players**
   - Added multi-resolution HLS support
   - Implemented fallback mechanisms
   - Enhanced adaptive streaming

3. **Metadata Extraction**
   - Improved aspect ratio detection
   - Added timeout handling
   - Enhanced error recovery

## Benefits

### 1. **Reduced App Size**
- No FFmpeg dependency
- Smaller binary size
- Faster app downloads

### 2. **Better Performance**
- Server-side processing
- Reduced device resource usage
- Improved battery life

### 3. **Enhanced Compatibility**
- Multi-resolution adaptive streaming
- Better quality selection
- Improved playback experience

### 4. **Scalability**
- Server-side processing
- CDN integration
- Global video distribution

### 5. **Maintenance**
- Centralized video processing
- Easier updates and fixes
- Better error handling

## Troubleshooting

### Common Issues

1. **Video Won't Play**
   - Check if HLS stream is properly generated
   - Verify `master.m3u8` or `playlist.m3u8` exists
   - Check network connectivity for streaming

2. **Upload Fails**
   - Verify video format is supported
   - Check file size limits
   - Ensure network connectivity

3. **Quality Issues**
   - Check network bandwidth
   - Verify server-side conversion settings
   - Monitor adaptive streaming behavior

### Debug Information

Enable debug logging:
```swift
// Add to your app's logging configuration
print("Video Processing Debug: \(debugInfo)")
```

## Future Enhancements

### Planned Features

1. **Advanced Adaptive Streaming**
   - More quality levels (1080p, 360p, 240p)
   - Bandwidth prediction
   - Quality preference settings

2. **Live Streaming Support**
   - Real-time HLS generation
   - Live video broadcasting
   - Multi-user streaming

3. **Advanced Codec Support**
   - HEVC/H.265 encoding
   - VP9 support
   - AV1 support (when available)

4. **Enhanced Analytics**
   - Quality switching metrics
   - Bandwidth usage tracking
   - User experience monitoring

## Conclusion

The consolidated video processing system provides a robust, scalable solution for video handling in the Tweet iOS app. By moving video conversion to the backend and implementing multi-resolution HLS support, the system offers better performance, smaller app size, and improved user experience compared to the previous client-side FFmpeg approach.

The adaptive streaming capabilities ensure optimal video quality across different network conditions, while the fallback mechanisms maintain backward compatibility with existing single-resolution streams.