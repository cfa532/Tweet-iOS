# Upload Progress System

## Overview
A comprehensive upload progress tracking system with foreground/background detection, auto-lock prevention, and pending upload recovery.

## Implementation Date
October 14, 2025

## Features

### 1. **Visual Progress Tracking** ✅
- Semi-transparent overlay during uploads
- Progress bar with percentage
- Stage-specific messages:
  - "Preparing upload..."
  - "Converting video..."
  - "Uploading attachments..."
  - "Submitting tweet..."
- Warning message: "Please keep the app open until upload completes"
- Can't be dismissed (blocks interaction during upload)

### 2. **Auto-Lock Prevention** ✅
- Automatically disables idle timer during uploads
- Screen won't auto-lock while uploading
- Re-enables auto-lock on completion or failure
- Prevents accidental upload interruption

### 3. **Background Detection** ✅
- Monitors app state changes
- Detects when app goes to background
- Detects when app returns to foreground
- Saves pending uploads to disk

### 4. **Pending Upload Recovery** ✅
- Shows recovery dialog on app launch if pending upload exists
- Shows recovery dialog when app returns to foreground
- User options:
  - **Retry Upload** - Resumes from where it left off
  - **Discard** - Removes the pending upload
- Displays upload details:
  - Type (Tweet/Comment)
  - Timestamp (relative time)
  - Number of attachments
  - Content preview

### 5. **Full Localization** ✅
- English
- Japanese (日本語)
- Chinese Simplified (简体中文)
- 23 new localized strings

## Migration from Old System

### What Changed
**Old Behavior (Automatic):**
- Pending uploads automatically retried on app launch
- No user interaction required
- Could cause unexpected background uploads

**New Behavior (User-Controlled):**
- Pending uploads show a dialog on app launch/foreground
- User chooses to **Retry** or **Discard**
- More transparent and gives user control
- Same underlying retry mechanism with video job status checking

### Backward Compatibility
✅ **Fully Compatible** - The old pending upload file format is unchanged
- Existing pending uploads will show in the new dialog
- Video job IDs are preserved and checked correctly
- All retry logic and HLS status polling still works
- Only difference: requires user confirmation instead of auto-retry

### Code Changes
- `HproseInstance.swift` - **Removed** automatic recovery functions (~150 lines)
  - Removed: `recoverPendingUploads()`, `cleanupProblematicPendingUploads()`, `recoverPendingUploads_old()`
  - Disabled automatic recovery call on app launch
- `TweetUploadManager.swift` - **Removed** auto-retry functions (~150 lines)
  - Removed: `recoverPendingUploads()`, `cleanupProblematicPendingUploads()`
  - **Kept**: All core retry logic in `uploadTweetWithPersistenceAndRetry()`
  - **Kept**: Video job status checking and polling
  - **Kept**: HLS upload resume capability
- `ContentView.swift` - **Added** new dialog-based recovery system
  - Checks for pending uploads on launch and foreground
  - Shows user-friendly recovery dialog
  - Directly calls `uploadTweetWithPersistenceAndRetry()` on retry

### What Was Removed (Dead Code)
Total: ~300 lines of automatic recovery code

**TweetUploadManager.swift:**
- `recoverPendingUploads()` - Auto-retry function (115 lines)
- `cleanupProblematicPendingUploads()` - Auto-cleanup (24 lines)

**HproseInstance.swift:**
- `recoverPendingUploads()` - Wrapper (3 lines)
- `cleanupProblematicPendingUploads()` - Wrapper (3 lines)
- `recoverPendingUploads_old()` - Old implementation (125 lines)
- Removed call to `cleanupProblematicPendingUploads()` on launch

### What Was Preserved (Still Works)
✅ **Core retry mechanism** - `uploadTweetWithPersistenceAndRetry()` intact
✅ **Video job checking** - `checkVideoJobStatus()` and related functions
✅ **HLS polling** - `resumeVideoJobPolling()` and `handleCompletedVideoJob()`
✅ **Persistence** - `savePendingUpload()` and file format unchanged
✅ **Exponential backoff** - Retry delays still work
✅ **24-hour expiration** - Still enforced by dialog system

## Architecture

### Files Created

#### Core Logic
- **`Sources/Core/UploadProgressManager.swift`**
  - Singleton manager for tracking upload state
  - Handles auto-lock prevention
  - Monitors background/foreground transitions
  - Published properties for SwiftUI binding

#### UI Components
- **`Sources/Features/MediaViews/UploadProgressOverlay.swift`**
  - Visual progress overlay
  - Shows progress bar, stage message, warnings
  - Adapts icon based on current stage

- **`Sources/Features/MediaViews/PendingUploadDialog.swift`**
  - Recovery dialog UI
  - Displays upload details
  - Retry/Discard actions

#### Integration Points
- **`Sources/Core/TweetUploadManager.swift`** (modified)
  - Integrated progress tracking calls
  - Progress updates at each stage
  - Handles completion/failure states

- **`Sources/App/ContentView.swift`** (modified)
  - Added upload progress overlay
  - Added pending upload dialog
  - Checks for pending uploads on launch and foreground

## Usage

### For Users
1. **During Upload:**
   - Visual overlay appears automatically
   - Warning message reminds to keep app open
   - Screen won't auto-lock

2. **If Upload Interrupted:**
   - Next time app launches or returns to foreground
   - Dialog appears with upload details
   - Choose to retry or discard

### For Developers
```swift
// Start tracking
await MainActor.run {
    UploadProgressManager.shared.startUpload(type: "tweet")
}

// Update progress
await MainActor.run {
    UploadProgressManager.shared.updateProgress(
        stage: .convertingVideo,
        message: NSLocalizedString("Converting video...", comment: ""),
        progress: 0.3,
        detail: "30%"
    )
}

// Complete or fail
await MainActor.run {
    UploadProgressManager.shared.completeUpload()
    // or
    UploadProgressManager.shared.failUpload(message: "Error message")
}
```

## iOS Background Limitations

### What Works
- **Final tweet submission** - Fast (<1s), completes in background
- **Small file uploads** - Usually completes within iOS background time
- **Auto-lock prevention** - Keeps screen on during uploads

### What Doesn't Work
- **FFmpeg video conversion** - Too slow (5-30 minutes)
- **Large video uploads** - May fail on slow networks
- **Background processing** - Limited to ~30 seconds - 3 minutes

### Solution
The system saves upload state to disk. If upload fails:
1. User sees recovery dialog on next launch/foreground
2. Can retry the upload
3. Or discard if no longer needed

## Localized Strings

### Upload Progress (11 strings)
- Preparing upload...
- Converting video...
- Uploading attachments...
- Submitting tweet...
- Retrying upload...
- Upload completed
- Posting Tweet
- Posting Comment
- Sending Message
- Uploading
- Please keep the app open until upload completes

### Pending Upload Dialog (12 strings)
- Upload Interrupted
- Your upload was interrupted, possibly because the app was closed. Would you like to retry the upload or discard it?
- Your upload was interrupted and %d retry attempts have failed. Would you like to try again or discard it?
- Type:
- Date:
- Attachments:
- Content:
- Comment
- Tweet
- Retry Upload
- Discard
- Upload discarded

## Testing

### Manual Testing Checklist
- [ ] Upload tweet with video - verify progress overlay appears
- [ ] During upload, verify screen doesn't auto-lock
- [ ] Background app during video conversion
- [ ] Return to foreground - verify pending upload dialog
- [ ] Test "Retry Upload" - verify upload resumes
- [ ] Test "Discard" - verify upload is cancelled
- [ ] Test all three languages (EN/JA/ZH)
- [ ] Upload with images only (no video)
- [ ] Upload comment with attachments
- [ ] Send chat message with attachment

### Known Limitations
1. **FFmpeg conversion must stay in foreground** - iOS limitation
2. **Background time is limited** - ~30 seconds to 3 minutes
3. **Pending uploads expire after 24 hours** - Prevents stale data

## Future Enhancements (Optional)
- [ ] Server-side video conversion (best solution)
- [ ] Show estimated time remaining
- [ ] Pause/resume capability
- [ ] Multiple concurrent upload tracking
- [ ] Upload queue management
- [ ] Bandwidth monitoring and adaptive quality

## Related Documentation
- `PROGRESSIVE_VIDEO_IMPLEMENTATION.md` - Video streaming system
- `VIDEO_CONVERSION_SERVICE.md` - FFmpeg integration
- `FEATURES.md` - App features overview

