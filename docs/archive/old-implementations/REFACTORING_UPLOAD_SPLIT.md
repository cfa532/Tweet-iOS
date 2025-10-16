# Refactoring: Splitting Upload Logic from HproseInstance

## Status: In Progress

## Overview
The `HproseInstance.swift` file has become too large (>5000 lines). This document tracks the refactoring to split tweet upload functionality into a separate `TweetUploadManager.swift` file.

## Changes Made

### 1. Created TweetUploadManager.swift
- **Location**: `Sources/Core/TweetUploadManager.swift`
- **Contents**: New file with all tweet and media upload related functionality
- **Includes**:
  - `PendingTweetUpload` struct
  - Upload methods (`uploadToIPFS`, `scheduleTweetUpload`, etc.)
  - Upload retry and persistence logic
  - Video job status management
  - Recovery methods for pending uploads

### 2. TODO: Move MediaProcessor class
- **From**: `HproseInstance.swift` lines 1727-3593
- **To**: Append to `TweetUploadManager.swift`
- **Includes**:
  - FileTypeDetector class
  - Media type detection
  - Video processing (HLS conversion + MP4 fallback)
  - Image/audio/document processing
  - Upload helper methods

### 3. TODO: Update HproseInstance.swift
- **Remove**: Lines 1701-4604 (all upload-related code)
- **Add**: 
  - Property: `lazy var uploadManager = TweetUploadManager(hproseInstance: self)`
  - Delegate method stubs that call `uploadManager`

### 4. TODO: Update Call Sites
Files that call upload methods need to be updated to use the new structure:
- `Sources/Features/Compose/ComposeTweetView.swift`
- `Sources/Features/Chat/ChatScreen.swift`
- `Sources/Features/Compose/CommentComposeView.swift`
- Any other files calling `HproseInstance.shared.uploadToIPFS()` or `scheduleTweetUpload()`

## New API Usage

### Before:
```swift
try await HproseInstance.shared.uploadToIPFS(data: data, typeIdentifier: typeId, fileName: name)
HproseInstance.shared.scheduleTweetUpload(tweet: tweet, itemData: data)
```

### After (Option 1 - Direct):
```swift
try await HproseInstance.shared.uploadManager.uploadToIPFS(data: data, typeIdentifier: typeId, fileName: name)
HproseInstance.shared.uploadManager.scheduleTweetUpload(tweet: tweet, itemData: data)
```

### After (Option 2 - Delegated, Recommended):
```swift
try await HproseInstance.shared.uploadToIPFS(data: data, typeIdentifier: typeId, fileName: name)
HproseInstance.shared.scheduleTweetUpload(tweet: tweet, itemData: data)
```
(HproseInstance methods delegate to uploadManager internally)

## Video Upload Fallback Feature

### New Feature Added
When uploading videos as tweet attachments, the system now:
1. **Checks clouddriveport availability** first (3-second timeout)
2. If available: **Converts to HLS** and uploads zip file to clouddriveport service
3. If not available: **Resamples to MP4** (720p or 480p based on original resolution) and uploads via regular IPFS route

### Implementation Details
- Service check: `GET http://{host}:{cloudDrivePort}/health` with 3s timeout
- MP4 resampling uses FFmpeg with H.264 codec
- Resolution selection:
  - Original > 720p → resample to 720p
  - Original > 480p and ≤ 720p → resample to 480p
  - Original ≤ 480p → keep original resolution
- Maintains aspect ratio (portrait vs landscape aware)

## Benefits of Split
1. **Reduced File Size**: HproseInstance.swift will be ~2000 lines instead of 5000+
2. **Better Organization**: Upload concerns separated from instance management
3. **Easier Maintenance**: Changes to upload logic don't affect other code
4. **Clearer Responsibilities**: Each class has a focused purpose

## Next Steps
1. ✅ Create TweetUploadManager.swift with basic structure
2. ✅ Add video fallback logic (clouddriveport check + MP4 resampling)
3. ⏳ Move MediaProcessor class to TweetUploadManager
4. ⏳ Remove old code from HproseInstance
5. ⏳ Add delegation methods to HproseInstance
6. ⏳ Update all call sites
7. ⏳ Test the refactoring
8. ⏳ Update imports if needed

## Notes
- `TweetUploadManager` holds a weak reference to `HproseInstance` to avoid retain cycles
- All public upload methods remain accessible through HproseInstance for backward compatibility
- No changes needed to external APIs - refactoring is internal only

