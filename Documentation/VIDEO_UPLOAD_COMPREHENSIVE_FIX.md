# Video Upload - Comprehensive Fixes

## Date: 2025-10-13

## All Issues Fixed

### 1. ✅ FFmpeg Output File Extension Fixed
**Problem**: FFmpeg couldn't recognize `.file` extension
```
ERROR: Unable to find a suitable output format for '...resampled_xxx.file'
```

**Solution**: Force `.mp4` extension for both input and output:
```swift
let tempFileName = (originalFileName as NSString).deletingPathExtension + ".mp4"
let outputVideoName = "resampled_" + (originalFileName as NSString).deletingPathExtension + ".mp4"
```

### 2. ✅ CloudDrivePort Check Moved to Beginning
**Problem**: Service check happened after video data was loaded

**Solution**: Check `cloudDrivePort` configuration **first**:
```swift
let cloudPort = appUser.cloudDrivePort ?? 0
if cloudPort <= 0 {
    // Skip service check entirely
    return try await uploadVideoWithMp4Fallback(...)
}
```

### 3. ✅ Removed Default CloudDrivePort
**Problem**: All users had default port 8082/8010, causing failed connection attempts

**Solution**: Set default to `nil`:
- `User.swift`: `cloudDrivePort: Int? = nil`
- `Registration.swift`: No default assignment
- `ProfileEditView.swift`: Default display = `""`

### 4. ✅ Skip Unnecessary Conversion
**Problem**: Videos already at acceptable resolution were being re-encoded

**Solution**: Check resolution before converting:
```swift
if minDimension <= targetResolution {
    // Upload original - no conversion
    convertedData = data
} else {
    // Downsample
    convertedData = try Data(contentsOf: outputVideoURL)
}
```

### 5. ✅ Comprehensive IPFS Upload Debugging
**Added extensive logging to diagnose upload failures**:
```swift
// Chunk upload logging
print("DEBUG: [uploadRegularFile] Uploading chunk \(chunkCount), size: \(chunkData.count)")
print("DEBUG: [uploadRegularFile] Chunk \(chunkCount) response: \(response)")

// Final response logging
print("DEBUG: [uploadRegularFile] Final response type: \(type(of: finalResponse))")
print("DEBUG: [uploadRegularFile] Final response: \(finalResponse)")
```

## Current Status

### Working ✅
- FFmpeg conversion with proper file extensions
- Service availability check logic
- Resolution detection (via AVFoundation fallback)
- 4K → 720p downsampling works

### Not Working ❌
- FFmpeg probe failing (return code 1)
- IPFS chunk upload failing with "文件上传失败"

## Next Test - What to Look For

### Step 1: Clear CloudDrivePort (Your Account)
1. Go to Settings → Edit Profile
2. Clear "Cloud Drive Port" field (make it empty)  
3. Save

This will make your account behave like a new user (no cloudDrivePort configured).

### Step 2: Upload a Video
Upload any video and monitor console for these debug logs:

#### Expected Flow (No CloudDrivePort):
```
Processing video file (size: X.XMB)
Cloud drive port not configured - using MP4 resampling and IPFS upload
```
✅ No service check = No 3-second delay!

#### For 720p or smaller videos:
```
DEBUG: [MP4 FALLBACK] Video already at acceptable resolution (405p <= 720p), uploading original
Uploading video via IPFS... (50%)
Uploading regular file: type=Video, size=XXXX bytes
DEBUG: [uploadRegularFile] Uploading chunk 1, size: 1048576 bytes, offset: 0
DEBUG: [uploadRegularFile] Chunk 1 response type: ...
DEBUG: [uploadRegularFile] Chunk 1 response: ...
```

#### For 4K videos:
```
DEBUG: [MP4 FALLBACK] Video needs downsampling from 2160p to 720p
Resampling video to 720p MP4... (30%)
DEBUG: [MP4 FALLBACK] Successfully converted to 720p MP4
DEBUG: [MP4 FALLBACK] Converted video size: X.XMB
Uploading video via IPFS... (70%)
```

### Step 3: Analyze the Error
When upload fails, look for:
```
DEBUG: [uploadRegularFile] Uploading chunk X, size: XXXX bytes
DEBUG: [uploadRegularFile] Chunk X response: <-- THIS WILL TELL US WHAT'S WRONG
```

The response might be:
- `nil` → Server not responding
- Dictionary with error → Server rejecting upload
- Something else → Protocol mismatch

## Known Issues to Investigate

### Issue 1: FFmpeg Probe Failing
```
DEBUG: [FFMPEG PROBE] Command failed with return code: Optional(1)
```

**Impact**: Forces "convert to be safe" path even when not needed
**Workaround**: AVFoundation fallback works fine
**Priority**: Low (fallback works)

### Issue 2: IPFS Upload Failing  
```
Error uploading item ... 文件上传失败
```

**Impact**: Videos cannot be uploaded at all
**Needs**: Debug logs from next test
**Priority**: HIGH

## Summary of Changes

### Files Modified
1. **`HproseInstance.swift`**:
   - Added cloudDrivePort check before service availability check
   - Fixed FFmpeg file extension handling (`.mp4`)
   - Optimized to skip conversion when not needed
   - Added comprehensive upload debugging

2. **`User.swift`**:
   - `cloudDrivePort: Int? = nil` (was 8010)

3. **`Registration.swift`**:
   - Removed default port assignment
   - Updated change detection

4. **`ProfileEditView.swift`**:
   - Changed default display to empty string

### All Builds: ✅ SUCCESSFUL

## Next Actions Required

1. **Clear cloudDrivePort** in your test account settings
2. **Upload a video** and watch for the new debug logs
3. **Share the console output** showing the chunk upload responses

This will help us identify exactly why IPFS upload is failing!

