# Thumbnail Size Check Optimization

**Date:** October 21, 2025  
**Component:** `ThumbnailView.swift`  
**Issue:** Thumbnail generation (especially for videos) was happening before size validation, wasting time on files that would be rejected.

## Problem

When uploading attachments with tweets or comments:

1. **Thumbnail generation happened FIRST** (can take several seconds for video files)
2. **Size check happened LATER** in multiple places
3. Result: Users waited for thumbnail generation, only to see a "file too large" error afterward

### Timeline (Before Fix)
```
User selects 300MB video
  ↓
ThumbnailView generates thumbnail (5-10 seconds, wastes time)
  ↓
Upload preparation checks size
  ↓
Error: "File too large (300MB). Max: 240MB"
```

## Solution

Added **early size check** in `ThumbnailView.generateThumbnail()` BEFORE thumbnail generation and **removed all other duplicate size checks** for simplicity.

```swift
// CRITICAL: Check file size BEFORE generating thumbnail
// Thumbnail generation (especially for videos) can take a long time
do {
    if let data = try? await item.loadTransferable(type: Data.self) {
        if data.count > Constants.MAX_FILE_SIZE {
            let fileSizeMB = Double(data.count) / (1024 * 1024)
            let maxSizeMB = Double(Constants.MAX_FILE_SIZE) / (1024 * 1024)
            
            print("DEBUG: File too large, skipping thumbnail generation")
            
            // Set error state - thumbnail will show error icon
            await MainActor.run {
                self.error = ThumbnailError.fileTooLarge(
                    size: fileSizeMB,
                    maxSize: maxSizeMB
                )
                self.isLoading = false
            }
            return
        }
    }
}
```

### Timeline (After Fix)
```
User selects 300MB video
  ↓
ThumbnailView checks size (< 1 second)
  ↓
Error icon appears in thumbnail with message: "File too large (300.0MB). Max: 240MB"
  ↓
✅ No wasted time on thumbnail generation!
  ↓
User knows immediately and can select a different file
```

## Changes Made

### 1. `ThumbnailView.swift`

**Added early size check:**
- Loads file data at the beginning of `generateThumbnail()`
- Checks against `Constants.MAX_FILE_SIZE` (240MB)
- Sets error state and returns early if file is too large
- Skips expensive thumbnail generation for oversized files

**Extended `ThumbnailError` enum:**
```swift
enum ThumbnailError: Error, LocalizedError {
    case dataLoadingFailed
    case thumbnailGenerationFailed
    case fileTooLarge(size: Double, maxSize: Double)  // NEW
    
    var errorDescription: String? {
        switch self {
        // ...
        case .fileTooLarge(let size, let maxSize):
            return String(format: NSLocalizedString("File too large (%.1fMB). Max: %.0fMB", comment: "File size error"), size, maxSize)
        }
    }
}
```

### 2. `MediaPicker.swift`

**Removed duplicate size checks:**
- ❌ Removed `filterOversizedFiles()` method (was checking size after selection)
- ❌ Removed size check from `MediaUploadHelper.prepareItemData()` (was checking before upload)
- ✅ Simpler code, single point of validation

### 3. `ChatScreen.swift`

**Removed duplicate size check:**
- ❌ Removed size validation from `handlePhotoSelection()` (was checking in chat attachment flow)
- ✅ Size now validated consistently in ThumbnailView across all flows

## Benefits

1. **⚡️ Faster feedback**: Users see error immediately instead of waiting for thumbnail generation
2. **💾 Reduced memory usage**: No thumbnail generation for oversized files
3. **🔋 Battery savings**: Avoids expensive video decoding for files that will be rejected
4. **✨ Better UX**: Thumbnail shows error icon with clear message about file size
5. **🎯 Single point of validation**: No duplicate checks, simpler codebase
6. **📱 Visual feedback**: Error appears in the attachment preview itself, not as a separate toast

## Single Point of Validation

**All size checking is now done in `ThumbnailView.generateThumbnail()`** - the only place where it matters for UX:

```
User selects large file
  ↓
ThumbnailView checks size FIRST (< 1 second)
  ↓
If too large:
  ├─ Shows error icon immediately in thumbnail
  ├─ Skips expensive thumbnail generation
  └─ User sees clear error message in the preview
  ↓
If size OK:
  └─ Proceeds with thumbnail generation
```

**Why only one check?**
- ✅ **Faster feedback** - User sees error immediately in the thumbnail
- ✅ **Simpler code** - No duplicate validation logic across multiple files
- ✅ **Better UX** - Visual feedback in the attachment preview itself
- ✅ **Prevents wasted work** - Stops expensive thumbnail generation before it starts

The thumbnail will show an error icon and the user can see the file is too large before attempting to upload.

## Testing

1. **Test oversized video (> 240MB):**
   - Select video in compose view
   - Should immediately show error icon in thumbnail
   - Should display "File too large (XXX.XMB). Max: 240MB"
   - Should NOT take 5-10 seconds to generate thumbnail

2. **Test valid video (< 240MB):**
   - Select video in compose view
   - Should proceed with normal thumbnail generation
   - Should show thumbnail preview

3. **Test oversized image (> 240MB):**
   - Select large image in compose view
   - Should immediately show error icon
   - Should NOT process the image

4. **Test in chat:**
   - Select oversized file in chat
   - Should show error in thumbnail preview
   - Consistent behavior with tweet compose

## Constants

```swift
// In Constants.swift
MAX_FILE_SIZE = 240 * 1024 * 1024  // 240MB in bytes - applies to all file types
```

## Related Files

- `Sources/Features/Compose/ThumbnailView.swift` - **Size validation happens here**
- `Sources/DataModels/Constants.swift` - Size limit constant
- `Sources/Utils/MediaPicker.swift` - Size checks removed
- `Sources/Features/Chat/ChatScreen.swift` - Size check removed
