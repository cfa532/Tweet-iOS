# Video Conversion Service

This document describes the comprehensive video conversion system implemented in the Tweet-iOS app using `VideoConversionService.swift`.

## Overview

The `VideoConversionService` is a sophisticated video processing system that converts videos to HLS (HTTP Live Streaming) format with adaptive bitrate streaming. It provides background processing, memory management, and progress tracking for optimal user experience.

## Key Features

### 1. **HLS Conversion with Adaptive Bitrate**
- Converts videos to HLS format with multiple quality levels
- Creates 720p and 480p variants for adaptive streaming
- Generates master playlist for automatic quality selection
- Supports both portrait and landscape orientations

### 2. **Background Processing**
- Uses `UIApplication` background tasks for long-running conversions
- Implements Swift concurrency with `async/await` patterns
- Non-blocking conversion that doesn't freeze the UI
- Automatic background task management and cleanup

### 3. **Memory Management**
- Comprehensive memory usage monitoring
- Force garbage collection between conversion stages
- Memory cleanup after each conversion phase
- Detailed memory logging for debugging

### 4. **Intelligent Processing**
- Smart preset selection based on video resolution
- Aspect ratio-aware scaling for optimal quality
- FFmpeg integration with optimized parameters
- Progress tracking with stage-based updates

## Architecture

### Core Components

#### 1. **VideoConversionService** (Singleton)
```swift
class VideoConversionService {
    static let shared = VideoConversionService()
    
    private var currentConversion: Task<Void, Never>?
    private var progressCallback: ((ConversionProgress) -> Void)?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
}
```

#### 2. **Data Structures**
```swift
struct HLSConversionResult {
    let success: Bool
    let hlsDirectoryURL: URL?
    let errorMessage: String?
}

struct ConversionProgress {
    let stage: String
    let progress: Int // 0-100
    let estimatedTimeRemaining: TimeInterval?
}

struct VideoInfo {
    let width: Int
    let height: Int
    let duration: Double?
}
```

## Implementation Details

### Conversion Process

#### 1. **Initialization**
```swift
func convertVideoToHLS(
    inputURL: URL,
    outputDirectory: URL,
    aspectRatio: Float? = nil,
    progressCallback: @escaping (ConversionProgress) -> Void,
    completion: @escaping (HLSConversionResult) -> Void
)
```

**Process:**
1. Cancel any existing conversion
2. Start background task
3. Create HLS directory structure
4. Log initial memory usage
5. Begin async conversion process

#### 2. **Directory Structure**
```
outputDirectory/
└── hls/
    ├── master.m3u8          # Master playlist
    ├── 720p/
    │   └── playlist.m3u8    # 720p variant
    └── 480p/
        └── playlist.m3u8    # 480p variant
```

#### 3. **Conversion Stages**

**Stage 1: 720p Conversion (10-60% progress)**
- Converts input video to 720p HLS
- Uses intelligent preset selection
- Memory monitoring and cleanup

**Stage 2: 480p Conversion (60-90% progress)**
- Converts input video to 480p HLS
- Force memory cleanup between stages
- Error handling and validation

**Stage 3: Master Playlist Creation (90-100% progress)**
- Generates adaptive bitrate master playlist
- Calculates actual resolutions based on aspect ratio
- Final memory cleanup and completion

### Intelligent Preset Selection

The service automatically selects the optimal FFmpeg preset:

```swift
private func shouldUseCopyPreset(inputURL: URL, aspectRatio: Float?) async -> Bool {
    // Get video dimensions using FFmpeg
    if let videoInfo = await HLSVideoProcessor.shared.getVideoInfoWithFFmpeg(filePath: inputURL.path) {
        let maxDimension = aspectRatio < 1.0 ? videoInfo.displayHeight : videoInfo.displayWidth
        return maxDimension <= 720 // Use "copy" preset for videos ≤720p
    }
    return false // Use "veryfast" preset for larger videos
}
```

**Preset Selection Logic:**
- **"copy" preset**: For videos with max dimension ≤720p (no re-encoding)
- **"veryfast" preset**: For larger videos (fast re-encoding)

### Aspect Ratio Handling

The service intelligently handles different video orientations:

```swift
private func calculateActualResolution(targetResolution: Int, aspectRatio: Float?) -> String {
    guard let aspectRatio = aspectRatio else {
        return targetResolution == 720 ? "1280x720" : "854x480"
    }
    
    if aspectRatio < 1.0 {
        // Portrait: scale to target width, calculate height
        let width = targetResolution
        let height = Int(Float(targetResolution) / aspectRatio)
        let evenHeight = height % 2 == 0 ? height : height - 1
        return "\(width)x\(evenHeight)"
    } else {
        // Landscape: scale to target height, calculate width
        let height = targetResolution
        let width = Int(Float(targetResolution) * aspectRatio)
        let evenWidth = width % 2 == 0 ? width : width - 1
        return "\(evenWidth)x\(height)"
    }
}
```

### FFmpeg Command Generation

The service generates optimized FFmpeg commands:

```swift
let command = """
    -i "\(inputURL.path)" \
    -c:v libx264 \
    -c:a aac \
    -vf "\(scaleFilter)" \
    -b:v \(bitrate) \
    -b:a 128k \
    -preset \(preset) \
    -tune zerolatency \
    -threads 2 \
    -max_muxing_queue_size 512 \
    -fflags +genpts+igndts \
    -avoid_negative_ts make_zero \
    -max_interleave_delta 0 \
    -bufsize \(bitrate) \
    -maxrate \(bitrate) \
    -metadata:s:v:0 rotate=0 \
    -f hls \
    -hls_time 10 \
    -hls_list_size 0 \
    -hls_segment_filename "\(outputURL.deletingPathExtension().path)_%03d.ts" \
    -hls_flags delete_segments+independent_segments \
    "\(outputURL.path)"
    """
```

**Key Parameters:**
- **Codec**: H.264 video, AAC audio
- **Bitrate**: 2000k for 720p, 1000k for 480p
- **Segments**: 10-second segments with independent playback
- **Threading**: 2 threads for optimal performance
- **Latency**: Zero-latency tuning for streaming

## Memory Management

### Memory Monitoring
```swift
private func getMemoryUsage() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
    
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_,
                      task_flavor_t(MACH_TASK_BASIC_INFO),
                      $0,
                      &count)
        }
    }
    
    if kerr == KERN_SUCCESS {
        return Double(info.resident_size) / 1024.0 / 1024.0 // Convert to MB
    } else {
        return 0.0
    }
}
```

### Memory Cleanup
```swift
private func forceMemoryCleanup() {
    autoreleasepool {
        // Force garbage collection
    }
    logMemoryUsage("after cleanup")
}
```

**Memory Management Strategy:**
1. **Pre-conversion**: Log initial memory usage
2. **Between stages**: Force garbage collection
3. **Post-conversion**: Final cleanup and logging
4. **Background task**: Automatic cleanup on completion

## Background Task Management

### Task Lifecycle
```swift
private func startBackgroundTask() {
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoConversion") { [weak self] in
        self?.endBackgroundTask()
    }
}

private func endBackgroundTask() {
    if backgroundTaskID != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
```

**Background Task Features:**
- **Automatic cleanup**: Ends background task on completion
- **Timeout handling**: Graceful handling of background time expiration
- **Task cancellation**: Proper cleanup when conversion is cancelled
- **Memory safety**: Weak references to prevent retain cycles

## Progress Tracking

### Progress Updates
```swift
private func updateProgress(stage: String, progress: Int) async {
    await MainActor.run {
        self.progressCallback?(ConversionProgress(
            stage: stage,
            progress: progress,
            estimatedTimeRemaining: nil
        ))
    }
}
```

**Progress Stages:**
- **10%**: "Converting to 720p HLS..."
- **60%**: "Converting to 480p HLS..."
- **90%**: "Creating master playlist..."
- **100%**: "Conversion completed!"

## Master Playlist Generation

### Playlist Content
```swift
let masterPlaylistContent = """
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=\(actual720pResolution)
720p/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=\(actual480pResolution)
480p/playlist.m3u8
"""
```

**Playlist Features:**
- **Adaptive bitrate**: Automatic quality selection
- **Bandwidth indication**: 2Mbps for 720p, 1Mbps for 480p
- **Resolution metadata**: Actual calculated resolutions
- **HLS compatibility**: Standard HLS v3 format

## Usage Examples

### Basic Conversion
```swift
VideoConversionService.shared.convertVideoToHLS(
    inputURL: videoURL,
    outputDirectory: documentsDirectory,
    aspectRatio: 0.75, // Portrait video
    progressCallback: { progress in
        print("Progress: \(progress.progress)% - \(progress.stage)")
    },
    completion: { result in
        if result.success {
            print("Conversion successful: \(result.hlsDirectoryURL)")
        } else {
            print("Conversion failed: \(result.errorMessage)")
        }
    }
)
```

### Video Information Retrieval
```swift
VideoConversionService.shared.getVideoInfo(inputURL: videoURL) { videoInfo in
    if let info = videoInfo {
        print("Video: \(info.width)x\(info.height), Duration: \(info.duration)s")
    }
}
```

### Conversion Cancellation
```swift
VideoConversionService.shared.cancelCurrentConversion()
```

## Error Handling

### Conversion Errors
- **720p conversion failure**: Returns error with specific message
- **480p conversion failure**: Returns error with specific message
- **Master playlist failure**: Returns error with specific message
- **File system errors**: Handles directory creation failures
- **FFmpeg errors**: Parses and reports FFmpeg return codes

### Error Recovery
- **Automatic cleanup**: Background tasks and resources
- **Memory cleanup**: Force garbage collection on failure
- **Task cancellation**: Proper cleanup of async tasks
- **File cleanup**: Removes partial conversion files

## Performance Optimizations

### 1. **Intelligent Preset Selection**
- Uses "copy" preset for videos ≤720p (no re-encoding)
- Uses "veryfast" preset for larger videos (fast re-encoding)
- Reduces processing time and CPU usage

### 2. **Memory Management**
- Comprehensive memory monitoring
- Force garbage collection between stages
- Prevents memory leaks and crashes

### 3. **Background Processing**
- Non-blocking conversion using background tasks
- UI remains responsive during conversion
- Automatic cleanup on app backgrounding

### 4. **Async Processing**
- Swift concurrency for modern async/await patterns
- Proper task cancellation and cleanup
- Efficient resource utilization

## Debug Information

### Debug Logging
The service provides comprehensive debug logging:

```
DEBUG: [VIDEO CONVERSION] Starting background conversion for video.mp4
DEBUG: [VIDEO CONVERSION] Memory usage before conversion: 45.2 MB
DEBUG: [VIDEO CONVERSION] Using preset: copy for resolution: 720
DEBUG: [VIDEO CONVERSION] Memory usage after 720p conversion: 52.1 MB
DEBUG: [VIDEO CONVERSION] Memory usage after cleanup: 46.8 MB
DEBUG: [MASTER PLAYLIST] Calculated 720p resolution: 720x1280
DEBUG: [MASTER PLAYLIST] Calculated 480p resolution: 480x854
DEBUG: [VIDEO CONVERSION] Master playlist created at: /path/to/master.m3u8
DEBUG: [VIDEO CONVERSION] Memory usage final: 47.1 MB
```

### FFmpeg Logging
```
DEBUG: [FFMPEG LOG] Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'input.mp4':
DEBUG: [FFMPEG LOG] Stream #0:0(und): Video: h264 (avc1 / 0x31637661), yuv420p, 1080x1920, 5000 kb/s
DEBUG: [FFMPEG LOG] Stream #0:1(und): Audio: aac (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
```

## Configuration

### Current Settings
- **720p bitrate**: 2000k
- **480p bitrate**: 1000k
- **Audio bitrate**: 128k
- **Segment duration**: 10 seconds
- **Threads**: 2
- **Preset threshold**: 720p

### Customization
To modify conversion parameters, update the relevant constants in `VideoConversionService.swift`:

```swift
// Bitrate settings
let hls720pBitrate = "2000k"
let hls480pBitrate = "1000k"
let audioBitrate = "128k"

// FFmpeg settings
let segmentDuration = 10
let threadCount = 2
let presetThreshold = 720
```

## Integration with Other Systems

### HLSVideoProcessor
- Uses `HLSVideoProcessor.shared.getVideoInfoWithFFmpeg()` for video analysis
- Integrates with existing video processing infrastructure

### SharedAssetCache
- Converted HLS videos can be cached using `SharedAssetCache`
- Provides seamless integration with video playback system

### SimpleVideoPlayer
- HLS videos work directly with `SimpleVideoPlayer`
- Supports adaptive bitrate streaming
- Automatic quality selection based on network conditions

## Best Practices

### 1. **Memory Management**
- Monitor memory usage during conversion
- Use appropriate preset selection
- Implement proper cleanup procedures

### 2. **Error Handling**
- Always check conversion results
- Implement proper error recovery
- Provide user feedback for failures

### 3. **Performance**
- Use background tasks for long conversions
- Implement progress tracking
- Cancel unnecessary conversions

### 4. **User Experience**
- Provide progress feedback
- Handle conversion failures gracefully
- Optimize for device capabilities

## Troubleshooting

### Common Issues

#### 1. **Memory Issues**
- **Symptom**: App crashes during conversion
- **Solution**: Check memory usage, reduce bitrate, use "copy" preset

#### 2. **Conversion Failures**
- **Symptom**: FFmpeg returns error codes
- **Solution**: Check input file format, verify file permissions

#### 3. **Background Task Issues**
- **Symptom**: Conversion stops when app backgrounds
- **Solution**: Ensure proper background task management

#### 4. **Progress Not Updating**
- **Symptom**: UI doesn't show conversion progress
- **Solution**: Verify progress callback is set, check MainActor usage

### Debug Commands
```swift
// Check current conversion status
if VideoConversionService.shared.currentConversion != nil {
    print("Conversion in progress")
}

// Get memory usage
let memory = VideoConversionService.shared.getMemoryUsage()
print("Memory usage: \(memory) MB")
```

## Future Enhancements

### Potential Improvements
1. **Additional Quality Levels**: Support for 1080p, 360p variants
2. **Custom Bitrates**: User-configurable bitrate settings
3. **Batch Conversion**: Convert multiple videos simultaneously
4. **Cloud Processing**: Server-side conversion for large files
5. **Quality Metrics**: Automatic quality assessment and optimization

### Performance Optimizations
1. **Hardware Acceleration**: Use device GPU for encoding
2. **Parallel Processing**: Convert multiple variants simultaneously
3. **Smart Caching**: Cache conversion results for repeated files
4. **Adaptive Quality**: Adjust quality based on device capabilities

## Conclusion

The `VideoConversionService` provides a comprehensive, production-ready solution for video conversion to HLS format. With its advanced memory management, background processing, and intelligent optimization features, it ensures optimal performance and user experience while maintaining high video quality.

The service is designed to be robust, efficient, and easily maintainable, making it suitable for production use in the Tweet-iOS app.
