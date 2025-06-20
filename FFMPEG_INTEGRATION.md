# FFmpeg-iOS Integration Guide

This guide explains how to integrate the [FFmpeg-iOS Swift Package](https://github.com/kewlbear/FFmpeg-iOS) into your Tweet-iOS project.

## Overview

The FFmpeg-iOS Swift Package provides a Swift-native interface for FFmpeg functionality, enabling video processing, format conversion, compression, and more directly in your iOS app. The integration includes automatic video conversion to HLS format with 720p resolution for optimal streaming.

## Integration Steps

### 1. Add FFmpeg-iOS Swift Package to Xcode Project

1. Open your project in Xcode (`Tweet.xcworkspace`)
2. Go to **File** → **Add Package Dependencies...**
3. Enter the package URL: `https://github.com/kewlbear/FFmpeg-iOS.git`
4. Click **Add Package**
5. Select your target (`Tweet`) and click **Add Package**

### 2. Using the FFmpegWrapper

The `FFmpegWrapper.swift` file provides a Swift-native interface for FFmpeg functionality.

#### Basic Usage

```swift
import Foundation

// Get the shared instance
let ffmpeg = FFmpegWrapper.shared

// Check if FFmpeg-iOS Swift Package is available
if ffmpeg.isFFmpegIOSAvailable {
    print("FFmpeg-iOS Swift Package is available")
} else {
    print("FFmpeg-iOS Swift Package not available")
}

// Convert video format
let success = ffmpeg.convertVideo(
    inputPath: "/path/to/input.mov",
    outputPath: "/path/to/output.mp4",
    format: "mp4"
)

// Compress video
let compressed = ffmpeg.compressVideo(
    inputPath: "/path/to/large_video.mp4",
    outputPath: "/path/to/compressed_video.mp4",
    quality: 28  // Lower = better quality, higher = smaller file
)

// Create thumbnail
let thumbnail = ffmpeg.createThumbnail(
    inputPath: "/path/to/video.mp4",
    outputPath: "/path/to/thumbnail.jpg",
    time: 1.0  // Extract frame at 1 second
)
```

### 3. Automatic Video Processing

The `HproseInstance.uploadToIPFS` method now automatically processes videos:

- **Video Detection**: Automatically detects video files during upload
- **HLS Conversion**: Converts videos to HLS format with 720p resolution
- **Zip Packaging**: Packages HLS files into a zip archive
- **Backend Upload**: Uploads the zip package to the backend

#### Video Processing Flow

```swift
// When uploading a video file, the system automatically:
// 1. Detects it's a video file
// 2. Converts to HLS format with 720p resolution
// 3. Creates a zip package containing:
//    - playlist.m3u8 (HLS manifest)
//    - segment_001.ts, segment_002.ts, etc. (video segments)
// 4. Uploads the zip package to the backend
// 5. Returns a MimeiFileType with type .zip

let uploadedFile = try await hproseInstance.uploadToIPFS(
    data: videoData,
    typeIdentifier: "public.movie",
    fileName: "my_video.mp4"
)
// uploadedFile.type will be "zip" for video files
```

## Features Available

### Video Processing
- **Automatic HLS Conversion**: Videos are automatically converted to HLS format
- **720p Resolution**: All videos are scaled to 720p for optimal streaming
- **Format Conversion**: Convert between video formats (MP4, MOV, AVI, etc.)
- **Compression**: Reduce file size while maintaining quality
- **Thumbnail Generation**: Extract frames from videos
- **Audio Extraction**: Extract audio from video files

### Supported Formats
- **Video**: MP4, MOV, AVI, MKV, WMV, FLV, WebM, M4V, 3GP
- **Audio**: MP3, AAC, WAV, FLAC, OGG
- **Output**: HLS (.m3u8 + .ts segments) packaged in ZIP

## Configuration

### Build Settings

Ensure your project has the following build settings:

1. **Other Linker Flags**: Add `-lc++` if not already present
2. **Enable Bitcode**: Set to No (FFmpeg doesn't support bitcode)

### Info.plist Permissions

Add the following permissions to your `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs access to photo library to process videos.</string>

<key>NSCameraUsageDescription</key>
<string>This app needs access to camera to record videos.</string>

<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to microphone to record audio.</string>
```

## Troubleshooting

### Common Issues

1. **"FFmpeg-iOS Swift Package not available"**
   - Ensure the package is properly added to your project
   - Check that the target is selected in package dependencies
   - Verify the package is resolved in Xcode

2. **Build errors**
   - Make sure you're using a compatible iOS deployment target (iOS 12.0+)
   - Check that all required permissions are set in Info.plist
   - Ensure the package is properly linked to your target

3. **Video conversion failures**
   - Check that the input video format is supported
   - Ensure sufficient disk space for temporary processing
   - Verify FFmpeg-iOS package is properly integrated

4. **Permission errors**
   - Ensure proper permissions are set in Info.plist
   - Check file access permissions for iOS 14+

### Performance Considerations

- Video processing is CPU-intensive and should be done on background threads
- Large files may take significant time to process
- Consider showing progress indicators for long operations
- Use appropriate quality settings to balance file size and quality
- HLS conversion creates multiple files, ensure sufficient storage

## Testing the Integration

The integration is automatically tested when uploading video files through the `HproseInstance.uploadToIPFS` method.

### Manual Testing

```swift
// Test FFmpeg availability
let ffmpeg = FFmpegWrapper.shared
if ffmpeg.isFFmpegIOSAvailable {
    print("✅ FFmpeg integration working")
} else {
    print("❌ FFmpeg integration failed")
}

// Test video upload (will trigger HLS conversion)
let videoData = // ... video data
let result = try await hproseInstance.uploadToIPFS(
    data: videoData,
    typeIdentifier: "public.movie",
    fileName: "test_video.mp4"
)
```

## Next Steps

1. Add the FFmpeg-iOS Swift Package to your Xcode project
2. Test video uploads to verify HLS conversion works
3. Monitor the backend to ensure zip packages are received correctly
4. Implement HLS playback in your video player components

## Resources

- [FFmpeg-iOS GitHub Repository](https://github.com/kewlbear/FFmpeg-iOS)
- [FFmpeg Documentation](https://ffmpeg.org/documentation.html)
- [HLS Streaming Documentation](https://developer.apple.com/documentation/http_live_streaming)
- [iOS Video Processing Best Practices](https://developer.apple.com/documentation/avfoundation/media_assets_playback_and_editing) 