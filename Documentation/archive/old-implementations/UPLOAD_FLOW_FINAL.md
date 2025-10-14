# Final Upload Flow - Multiple Attachments with Progress Display

## Implementation Date
October 14, 2025

---

## Core Principles - We're Aligned ✅

1. **Attachments upload sequentially, ONE BY ONE** (not parallel)
2. **Dialog shows progress for EACH item** with filename and sub-progress
3. **FFmpeg conversion happens in FOREGROUND** (dialog visible, auto-lock disabled)
4. **Dialog closes as soon as all uploads to server complete** (before server processing)
5. **Background polling waits for ALL job IDs** to complete
6. **If ANY job fails, ENTIRE upload fails**
7. **Tweet submission retries up to 2 times**
8. **Retry from dialog checks server status only** (NO re-upload)

---

## Complete Flow Example: 2 Videos + 1 Image

### Phase 1: Foreground Upload (User Sees Dialog)

```
USER CLICKS "PUBLISH"
↓
Dialog appears:
┌────────────────────────────────────────┐
│  📤 Posting Tweet                      │
│                                        │
│  Uploading video 1/3...                │
│  ▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░ 25%    │
│  Converting 720p... (50%)              │ ← FFmpeg sub-progress
│                                        │
│  ⚠️ Keep the app open                 │
└────────────────────────────────────────┘

TIME: 00:00 - Start
      00:05 - FFmpeg converting 720p (0-50%)
      00:10 - FFmpeg converting 720p (50-100%)
      00:15 - FFmpeg converting 480p (0-50%)
      00:20 - FFmpeg converting 480p (50-100%)
      00:25 - Compressing HLS files
      00:30 - Uploading zip to server...
      01:00 - Server returns job ID #1 ✅

Dialog updates:
┌────────────────────────────────────────┐
│  📤 Posting Tweet                      │
│                                        │
│  Uploading video 2/3...                │
│  ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░ 50%     │
│  Converting 720p... (30%)              │ ← FFmpeg for video 2
│                                        │
│  ⚠️ Keep the app open                 │
└────────────────────────────────────────┘

TIME: 01:00 - Start video 2
      01:05 - FFmpeg converting...
      01:30 - Uploading zip...
      02:00 - Server returns job ID #2 ✅

Dialog updates:
┌────────────────────────────────────────┐
│  📤 Posting Tweet                      │
│                                        │
│  Uploading image 3/3...                │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ 75%     │
│  Uploading to IPFS... (100%)           │
│                                        │
│  ⚠️ Keep the app open                 │
└────────────────────────────────────────┘

TIME: 02:00 - Start image
      02:05 - Image uploaded, got CID ✅

ALL UPLOADS COMPLETE!

Dialog shows final message:
┌────────────────────────────────────────┐
│  ✅ Posting Tweet                      │
│                                        │
│  Processing on server...               │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 100%    │
│  Your tweet will be posted when ready  │
│                                        │
└────────────────────────────────────────┘

TIME: 02:05 - Show message for 1.5 seconds
      02:06 - DIALOG CLOSES
              Auto-lock re-enabled
              USER CAN NOW USE APP FREELY! 🎉
```

### Phase 2: Background Polling (Silent)

```
TIME: 02:06 - Background polling starts
              (No UI shown, user using app)

Console logs:
🔄 [Background Poll] Starting background polling for 2 job(s)
⏳ [Background Poll] 0/2 jobs complete, polling... (1/120)
⏳ [Background Poll] 0/2 jobs complete, polling... (2/120)
⏳ [Background Poll] 0/2 jobs complete, polling... (3/120)
✅ [Background Poll] Job 1/2 complete! Job: xxx, CID: yyy
⏳ [Background Poll] 1/2 jobs complete, polling... (4/120)
⏳ [Background Poll] 1/2 jobs complete, polling... (5/120)
✅ [Background Poll] Job 2/2 complete! Job: zzz, CID: www
✅ [Background Poll] ALL 2 jobs completed!

TIME: 02:36 - Both videos processed (30 seconds on server)

📝 [Submit] Submitting tweet with 2 completed job(s)
📝 [Submit] Replaced job ID with CID for attachment 1
📝 [Submit] Replaced job ID with CID for attachment 2
✅ [Submit] Tweet posted successfully with 3 attachments!

Toast appears: "Tweet posted successfully" ✅
```

---

## What User Sees - Timeline

```
00:00 ┌─────────────────────────────────┐
      │ Dialog: Uploading video 1/3     │  ← FOREGROUND (required)
      │ Converting 720p... (25%)        │  ← FFmpeg sub-progress
      │ Progress: 8%                    │
      │ ⚠️ Keep app open                │
00:05 │ Converting 720p... (75%)        │
      │ Progress: 15%                   │
01:00 │ Uploading video 2/3             │  ← Still FOREGROUND
      │ Converting 480p... (40%)        │  ← FFmpeg for video 2
      │ Progress: 45%                   │
02:00 │ Uploading image 3/3             │
      │ Progress: 85%                   │
02:05 │ Processing on server...         │  ← All uploads done!
      │ Progress: 100%                  │
02:06 └─────────────────────────────────┘  ← DIALOG CLOSES
      
      User now using app, browsing feed
      (Background polling happening silently)
      
02:36 Toast: "Tweet posted successfully" ✅
```

---

## Progress Breakdown Per Item

### For Each Video Item:

```
Progress Range: 0-100% (within item's slot)

Sub-stages shown in detail field:
├─ "Converting 720p... (0-100%)"      ← FFmpeg progress
├─ "Converting 480p... (0-100%)"      ← FFmpeg progress
├─ "Compressing HLS files... (40%)"   ← Compression
├─ "Uploading HLS zip... (60%)"       ← Network upload
└─ "Video uploaded to server (100%)"  ← Complete

Overall progress bar:
- Item 1/3: Contributes 0-33% to overall
- Item 2/3: Contributes 33-66% to overall
- Item 3/3: Contributes 66-100% to overall

Calculation:
overallProgress = 0.2 + (itemIndex / totalItems * 0.6) + (itemProgress / 100 * 0.6 / totalItems)
```

### For Each Image Item:

```
Sub-stages shown in detail:
├─ "Uploading to IPFS... (X%)"
└─ Complete (gets CID immediately)

Much faster than video (no FFmpeg)
```

---

## Code Flow with Progress Updates

```swift
uploadAttachments(itemData: [ItemData]) {
    for (index, item) in itemData.enumerated() {
        itemNumber = index + 1
        itemType = isVideo ? "video" : "image"
        
        // MAIN DIALOG UPDATE
        UploadProgressManager.updateProgress(
            stage: .uploadingAttachments,
            message: "Uploading \(itemType) \(itemNumber)/\(totalItems)...",
            progress: baseProgress,
            detail: item.fileName
        )
        
        // UPLOAD with sub-progress callback
        uploadToIPFS(item, progressCallback: { subMessage, subProgress in
            // DETAILED PROGRESS UPDATE
            UploadProgressManager.updateProgress(
                stage: .uploadingAttachments,
                message: "Uploading \(itemType) \(itemNumber)/\(totalItems)...",
                progress: calculatedProgress,
                detail: "\(subMessage) (\(subProgress)%)"
                //      ↑ Shows: "Converting 720p... (45%)"
                //      ↑ Or: "Uploading zip... (75%)"
            )
        })
        
        // Collect job ID if video
        if jobId {
            jobIdMap[item.identifier] = jobId
        }
    }
    
    return (attachments, jobIdMap)
}
```

---

## What Happens in Foreground vs Background

### FOREGROUND (Dialog Visible, Auto-Lock Disabled)

**ALL of these happen with dialog visible:**
1. ✅ FFmpeg video conversion (1-5 minutes per video)
2. ✅ Compressing HLS directory
3. ✅ Uploading zip file to server (network operation)
4. ✅ Uploading images to IPFS
5. ✅ Getting job IDs back from server

**Progress shown for EACH:**
- Main message: "Uploading video 2/4..."
- Detail: "Converting 720p... (67%)" ← Real-time FFmpeg progress
- Progress bar: Combined progress for all items

### BACKGROUND (Dialog Closed, Silent)

**Only these happen in background:**
1. ✅ Polling job status (lightweight HTTP GET every 5s)
2. ✅ Submitting final tweet (tiny JSON POST)
3. ✅ Retry tweet submission if needed

**No progress shown:**
- User doesn't see polling
- Toast only on final success/failure

---

## Retry Flow - Detailed

### User Clicks "Retry Upload" on Pending Upload

```
Dialog appears: "Checking video status..."

Check ALL items with job IDs:
┌─────────────────────────────────────────────┐
│ ItemData[0].videoJobId = "job-1"            │
│ ItemData[1].videoJobId = "job-2"            │
│ ItemData[2].videoJobId = null (image)       │
└─────────────────────────────────────────────┘

Query server:
├─ checkVideoJobStatus("job-1") → "completed", CID: "cid-1" ✅
├─ checkVideoJobStatus("job-2") → "processing" ⏳
│
Results analysis:
├─ allCompleted = false (job-2 still processing)
├─ anyFailed = false (no failures)
│
Action:
├─ Close dialog: "Processing on server..."
└─ Start background polling for remaining jobs

BACKGROUND:
├─ Poll job-2 every 5s
├─ job-2: "completed" → CID: "cid-2" ✅
├─ ALL 2 jobs complete!
│
Submit tweet:
├─ Attachment 1: mid = "cid-1" (video)
├─ Attachment 2: mid = "cid-2" (video)
├─ Attachment 3: mid = "cid-3" (image - already had it)
└─ Upload tweet with all 3 attachments
```

**NO RE-UPLOAD:** Attachments never uploaded again, only server status checked

---

## Failure Scenarios

### Scenario 1: FFmpeg Fails (Foreground)

```
Dialog: "Uploading video 1/2..."
├─ FFmpeg conversion fails
├─ Error thrown
├─ Dialog: "Video conversion failed"
├─ Remove pending upload
└─ User must start over ❌
```

### Scenario 2: Server Job Fails (Background)

```
Background polling:
├─ Job 1: "completed" ✅
├─ Job 2: "failed" ❌ ← Server couldn't process
│
Action:
├─ Stop polling immediately
├─ Toast: "Video processing failed"
├─ Remove pending upload
└─ User must start over ❌
```

### Scenario 3: App Backgrounded During FFmpeg

```
Dialog showing: "Uploading video 1/2..."
├─ Detail: "Converting 720p... (45%)"
├─ User switches to background
├─ iOS gives ~30s-3min grace period
├─ FFmpeg fails (too slow)
├─ Upload fails
├─ Pending upload saved to disk
│
User returns to foreground:
├─ Dialog appears: "Upload Interrupted"
├─ User clicks "Retry Upload"
└─ Re-upload from beginning (no job ID saved yet)
```

### Scenario 4: App Backgrounded During Polling

```
Dialog already closed
Background polling running:
├─ User switches to background
├─ Polling continues (lightweight HTTP)
├─ Jobs complete on server
├─ Tweet auto-posts
│
User returns:
└─ Toast: "Tweet posted successfully" ✅
```

---

## Progress Display Details

### Dialog Structure

```
┌──────────────────────────────────────────────┐
│  [Icon] Posting Tweet                        │
│                                              │
│  Main Message (changes per item)             │
│  ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░ 45%              │
│  Detail (sub-progress)                       │
│                                              │
│  ⚠️ Warning (if converting/uploading)       │
└──────────────────────────────────────────────┘
```

### Progress Calculation

```
Overall Progress = 0.2 + (itemIndex / totalItems) * 0.6 + (itemSubProgress / 100) * (0.6 / totalItems)

Example with 3 items:
- Item 1: Range 20% - 40% (20% base + 20% for item 1)
  - Converting 720p 50%: 20% + 0.5 * 20% = 30%
  - Uploading 100%: 20% + 1.0 * 20% = 40%
  
- Item 2: Range 40% - 60%
  - Converting 720p 50%: 40% + 0.5 * 20% = 50%
  
- Item 3: Range 60% - 80%
  - Uploading 100%: 60% + 1.0 * 20% = 80%
  
- Final submission: 80% - 100%
```

### Message Examples

**Main Messages:**
- "Uploading video 1/3..."
- "Uploading video 2/3..."
- "Uploading image 3/3..."
- "Processing on server..."
- "Checking video status..." (retry)

**Detail Messages (Sub-Progress):**
- "Converting 720p... (45%)" ← From FFmpeg
- "Converting 480p... (67%)" ← From FFmpeg
- "Compressing HLS files... (40%)"
- "Uploading HLS zip to server... (75%)"
- "Video uploaded to server (100%)"
- "Uploading to IPFS... (50%)"
- "Your tweet will be posted when ready"
- "video.mp4" ← Filename

---

## Data Tracking

### During Upload - ItemData Gets Updated

```swift
// Before upload
ItemData {
    identifier: "photo-1"
    typeIdentifier: "video"
    data: <video bytes>
    fileName: "video.mp4"
    videoJobId: nil  ← No job ID yet
}

// After upload to server
ItemData {
    identifier: "photo-1"
    typeIdentifier: "video"
    data: <video bytes>
    fileName: "video.mp4"
    videoJobId: "abc-123-def"  ← Got job ID! ✅
}

// Saved to disk: pendingTweetUpload.json
{
    "itemData": [
        { "identifier": "photo-1", "videoJobId": "abc-123-def" },
        { "identifier": "photo-2", "videoJobId": "xyz-789-ghi" },
        { "identifier": "photo-3", "videoJobId": null }
    ],
    "timestamp": 1697234567.89,
    "retryCount": 0
}
```

### During Background Polling - Job ID → CID Mapping

```swift
completedCIDs: [String: String] = [
    "abc-123-def": "QmVideoHash1...",  // Video 1 CID
    "xyz-789-ghi": "QmVideoHash2..."   // Video 2 CID
]

// When submitting tweet:
for (index, attachment) in uploadedAttachments {
    if let jobId = itemData[index].videoJobId {
        if let cid = completedCIDs[jobId] {
            attachment.mid = cid  // Replace job ID with CID
        }
    }
}

Final tweet.attachments = [
    MimeiFileType(mid: "QmVideoHash1..."),  // Video 1
    MimeiFileType(mid: "QmVideoHash2..."),  // Video 2
    MimeiFileType(mid: "QmImageHash...")    // Image (already had CID)
]
```

---

## Timeline Summary

| Time | Stage | Where | User Sees |
|------|-------|-------|-----------|
| 00:00-02:05 | FFmpeg + Upload all items | **FOREGROUND** | Dialog with progress for each item |
| 02:05-02:06 | Show completion message | **FOREGROUND** | "Processing on server..." |
| 02:06+ | Server processing videos | **BACKGROUND** | Nothing (dialog closed) |
| 02:06+ | Polling job status | **BACKGROUND** | Nothing |
| 02:36 | All jobs complete | **BACKGROUND** | Nothing |
| 02:36 | Submit tweet | **BACKGROUND** | Nothing |
| 02:36 | Success! | **BACKGROUND** | Toast: "Tweet posted successfully" |

**Total foreground time:** ~2 minutes (user must keep app open)  
**Total background time:** ~30 seconds (user can do anything)  
**Total time:** ~2.5 minutes for 2 videos + 1 image

---

## Key Guarantees

✅ **Sequential upload** - Items processed one by one  
✅ **Live progress** - FFmpeg conversion % shown in real-time  
✅ **Per-item progress** - "Uploading video 2/4..." with filename  
✅ **Foreground requirement clear** - Warning message displayed  
✅ **Dialog closes early** - As soon as server has all files  
✅ **All jobs must complete** - Waits for every video to process  
✅ **Any failure fails all** - Consistent state  
✅ **No re-upload on retry** - Server status check only  
✅ **Auto-lock prevented** - Screen stays on during foreground work  
✅ **Fully localized** - All messages in EN/JA/ZH  

---

## We Are Aligned ✅

**Foreground (Dialog Visible):**
- FFmpeg conversion ✅
- Compressing HLS ✅
- Uploading zip to server ✅
- Getting job IDs ✅
- Shows combined progress ✅

**Background (Dialog Closed):**
- Polling job status ✅
- Submitting tweet ✅
- Auto-retry submission ✅

The implementation is complete and matches your requirements exactly! 🎯

