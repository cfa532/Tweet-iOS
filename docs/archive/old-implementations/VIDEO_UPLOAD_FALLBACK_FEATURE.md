# Video Upload Fallback Feature

## Overview
When uploading videos as tweet attachments, the system now intelligently chooses between two upload strategies based on service availability.

## Feature Description

### Upload Strategy Selection
The system checks if the cloud drive service (at `clouddriveport`) is available before deciding how to process and upload videos.

#### Strategy 1: HLS Conversion (Preferred)
**When**: Cloud drive service is available at `clouddriveport`
**Process**:
1. Convert video to HLS format (720p + 480p variants)
2. Compress HLS directory to ZIP file
3. Upload ZIP to cloud drive service via `/process-zip` endpoint
4. Poll for processing completion
5. Return CID from processed HLS video

#### Strategy 2: MP4 Fallback (Automatic)
**When**: Cloud drive service is NOT available
**Process**:
1. Detect original video resolution using FFmpeg
2. Resample video to MP4 format with intelligent resolution:
   - Original > 720p → Resample to 720p
   - Original 480p-720p → Resample to 480p  
   - Original ≤ 480p → Keep original resolution
3. Upload MP4 via regular IPFS route
4. Return CID from uploaded MP4 video

## Implementation Details

### Service Availability Check
```swift
// Location: HproseInstance.swift (MediaProcessor class)
func checkCloudDriveServiceAvailability(appUser: User) async -> Bool
```

**Method**:
- Makes GET request to `http://{host}:{cloudDrivePort}/health`
- Timeout: 3 seconds
- Success if status code is 200 or 404
- Failure on timeout or other errors

### MP4 Resampling
```swift
// Location: HproseInstance.swift (MediaProcessor class)
func uploadVideoWithMp4Fallback(...) async throws -> (MimeiFileType?, String?)
func convertVideoToMp4(...) async -> Bool
```

**FFmpeg Command**:
```bash
-i {input} \
-c:v libx264 \
-c:a aac \
-vf "scale={filter}" \
-preset fast \
-crf 23 \
-b:a 128k \
-movflags +faststart \
-metadata:s:v:0 rotate=0 \
{output}
```

**Scale Filter**:
- Portrait (aspect < 1.0): `scale={resolution}:-2` (fixed width)
- Landscape (aspect ≥ 1.0): `scale=-2:{resolution}` (fixed height)
- Maintains aspect ratio and ensures even dimensions

### Resolution Selection Logic
```swift
let maxDimension = max(videoInfo.displayWidth, videoInfo.displayHeight)
if maxDimension > 720 {
    targetResolution = 720
} else if maxDimension > 480 {
    targetResolution = 480
} else {
    targetResolution = maxDimension
}
```

## Testing Instructions

### Test Scenario 1: Cloud Drive Service Available
**Setup**: Ensure cloud drive service is running at configured `clouddriveport`

**Steps**:
1. Launch the app
2. Create a new tweet
3. Attach a video (any format/resolution)
4. Send the tweet

**Expected Behavior**:
- Console logs: `"Cloud drive service available - using HLS conversion and upload"`
- Video converts to HLS format
- ZIP file uploaded to cloud drive service
- Final tweet contains HLS video attachment

**Console Output to Look For**:
```
DEBUG: Checking cloud drive service availability at: http://{host}:{port}/health
DEBUG: Cloud drive service availability check - status code: 200, available: true
Processing video file (size: X.XMB)
Cloud drive service available - using HLS conversion and upload
Starting local HLS conversion with FFmpeg
...
DEBUG: Process-zip completed with CID: {cid}
```

### Test Scenario 2: Cloud Drive Service Unavailable
**Setup**: Stop cloud drive service OR disconnect from network where service is hosted

**Steps**:
1. Launch the app
2. Create a new tweet
3. Attach a video (preferably 1080p or higher to see resampling)
4. Send the tweet

**Expected Behavior**:
- Console logs: `"Cloud drive service not available - using MP4 resampling and IPFS upload"`
- Video resamples to 720p or 480p MP4
- MP4 uploaded via regular IPFS route
- Final tweet contains standard video attachment

**Console Output to Look For**:
```
DEBUG: Cloud drive service not available - error: {error}
Processing video file (size: X.XMB)
Cloud drive service not available - using MP4 resampling and IPFS upload
Starting MP4 fallback conversion
DEBUG: [MP4 FALLBACK] FFmpeg detected: {width}x{height}, target resolution: {resolution}p
DEBUG: [MP4 FALLBACK] Successfully converted to {resolution}p MP4
DEBUG: [MP4 FALLBACK] Video uploaded successfully via IPFS with CID: {cid}
```

### Test Scenario 3: Different Video Resolutions
Test the resolution selection logic with various input videos:

| Original Resolution | Expected Output |
|-------------------|----------------|
| 4K (3840×2160) | 720p (1280×720) |
| 1080p (1920×1080) | 720p (1280×720) |
| 720p (1280×720) | 480p (854×480) |
| 480p (854×480) | 480p (no change) |
| 360p (640×360) | 360p (no change) |

**Portrait Videos**:
| Original | Expected |
|---------|---------|
| 1080×1920 | 720×1280 |
| 720×1280 | 480×854 |

### Test Scenario 4: Progress Callbacks
**Steps**:
1. Attach a large video file (>50MB)
2. Observe progress indicators in UI

**Expected Progress Messages** (Fallback Mode):
- "Checking video service availability..." (5%)
- "Converting video to MP4..." (10%)
- "Resampling video to {resolution}p MP4..." (30%)
- "Uploading video via IPFS..." (70%)
- "Video upload completed" (100%)

## Monitoring & Debugging

### Key Log Prefixes
- `DEBUG: [MP4 FALLBACK]` - MP4 fallback conversion logs
- `DEBUG: [HLS CONVERSION]` - HLS conversion logs
- `DEBUG: [FFMPEG ERROR]` - FFmpeg error messages

### Common Issues & Solutions

#### Issue: Service check always fails
**Cause**: Incorrect cloudDrivePort configuration or service not running
**Solution**: Verify `user.cloudDrivePort` is set correctly and service is accessible

#### Issue: MP4 conversion fails
**Cause**: Unsupported video codec or corrupted file
**Solution**: Check FFmpeg logs for codec issues, ensure FFmpegKit is properly installed

#### Issue: Video quality too low
**Cause**: Resolution downsampling is working as designed
**Solution**: If HLS quality is preferred, ensure cloud drive service is available

## Benefits

1. **Resilience**: App continues to work even if cloud drive service is down
2. **Flexibility**: Automatically adapts to network conditions
3. **User Experience**: Seamless - users don't notice the fallback
4. **Quality Options**: HLS when available (better streaming), MP4 as fallback (reliable)

## Performance Considerations

- Service availability check: 3-second timeout (minimal delay)
- MP4 resampling: Depends on video length and device performance
- IPFS upload: May be slower than HLS service upload due to chunking

## Future Enhancements

Potential improvements for future versions:
- [ ] Cache service availability for 5 minutes to reduce checks
- [ ] Allow user preference for upload method
- [ ] Provide quality selection UI (720p vs 480p)
- [ ] Support for more video formats in MP4 conversion
- [ ] Background conversion for large videos

## Code Locations

**Main Implementation**:
- `Sources/Core/HproseInstance.swift`:
  - `MediaProcessor.processVideo()` - Main entry point
  - `MediaProcessor.checkCloudDriveServiceAvailability()` - Service check
  - `MediaProcessor.uploadVideoWithLocalHLSConversion()` - HLS path
  - `MediaProcessor.uploadVideoWithMp4Fallback()` - MP4 fallback path
  - `MediaProcessor.convertVideoToMp4()` - FFmpeg conversion

**Related Components**:
- `Sources/Core/VideoConversionService.swift` - HLS conversion service
- `Sources/Core/HLSVideoProcessor.swift` - Video metadata extraction
- `Sources/Features/Compose/ComposeTweetView.swift` - UI that triggers upload

## Version Information

- **Feature Added**: 2025-10-13
- **iOS Version**: 18.0+
- **Dependencies**: FFmpegKit, AVFoundation

