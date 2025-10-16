# Complete Multi-Attachment Upload Algorithm

## Overview
Final implementation supporting multiple attachments (videos + images) with individual job tracking, sequential uploads with progress display, and background processing.

Implementation Date: October 14, 2025

---

## Core Principle

**Attachments are uploaded SEQUENTIALLY, ONE BY ONE, showing progress for each item.**

---

## Example Scenarios

### Scenario 1: Tweet with 2 Videos + 1 Image

```
Dialog appears: "Uploading attachments..."
├─ "Uploading video 1/3..." (0-33%)
│  ├─ FFmpeg converts to HLS
│  ├─ Compresses zip
│  ├─ Uploads to server
│  └─ Gets job ID #1
│
├─ "Uploading video 2/3..." (33-66%)
│  ├─ FFmpeg converts to HLS
│  ├─ Compresses zip
│  ├─ Uploads to server
│  └─ Gets job ID #2
│
├─ "Uploading image 3/3..." (66-100%)
│  ├─ Uploads to IPFS
│  └─ Gets CID (no job ID)
│
├─ All attachments uploaded!
├─ Save pending upload with:
│   - itemData[0].videoJobId = job ID #1
│   - itemData[1].videoJobId = job ID #2
│   - itemData[2].videoJobId = nil (image)
│
├─ Dialog shows: "Processing on server..."
│              "Your tweet will be posted when ready"
│
└─ Dialog closes after 1.5 seconds
   User can now use the app freely!

BACKGROUND POLLING STARTS:
├─ Poll job #1 every 5 seconds
├─ Poll job #2 every 5 seconds
├─ Wait for BOTH to complete
│
├─ Job #1: "processing" → Keep waiting
├─ Job #2: "processing" → Keep waiting
├─ Job #1: "completed" → Got CID #1
├─ Job #2: "processing" → Keep waiting
├─ Job #2: "completed" → Got CID #2
│
├─ ALL jobs complete!
├─ Build final attachments:
│   - Attachment 1: CID #1 (video)
│   - Attachment 2: CID #2 (video)
│   - Attachment 3: CID (image - already had it)
│
├─ Submit tweet with all 3 attachments
├─ Retry up to 2 times if submission fails
│
└─ Toast: "Tweet posted successfully" ✅
```

### Scenario 2: Tweet with 1 Video + 3 Images

```
Dialog shows:
├─ "Uploading image 1/4..." (0-25%)
├─ "Uploading image 2/4..." (25-50%)
├─ "Uploading image 3/4..." (50-75%)
├─ "Uploading video 4/4..." (75-100%)
│   └─ Gets job ID
│
├─ Dialog: "Processing on server..."
├─ Dialog closes
│
BACKGROUND:
├─ Poll video job
├─ Job complete → Got CID
├─ Submit tweet with all 4 attachments
└─ Toast: "Tweet posted successfully" ✅
```

### Scenario 3: Retry from Pending Upload

**User sees dialog:**
```
Upload Interrupted
Type: Tweet
Date: 5 minutes ago
Attachments: 3
Content: "Check out these videos..."

[Retry Upload]  [Discard]
```

**User clicks "Retry Upload":**

```
Dialog appears: "Checking video status..."
├─ Check job #1: "completed" → CID #1 ✅
├─ Check job #2: "processing" → Still waiting ⏳
│
├─ Result: 1/2 complete, 1 still processing
│
├─ Dialog: "Processing on server..."
├─ Dialog closes
│
BACKGROUND:
├─ Poll job #2 every 5 seconds
├─ Job #2: "completed" → CID #2
│
├─ ALL jobs complete!
├─ Submit tweet with all attachments
└─ Toast: "Tweet posted successfully" ✅
```

### Scenario 4: Job Failed on Server

**Retry flow:**
```
Dialog: "Checking video status..."
├─ Check job #1: "failed"
│
├─ ANY job failed → ENTIRE upload fails
├─ Dialog: "Video processing failed"
└─ Remove pending upload ❌
```

---

## Data Structures

### PendingTweetUpload
```swift
struct PendingTweetUpload {
    let tweet: Tweet
    let itemData: [ItemData]  // Each item can have its own job ID
    let timestamp: Date
    let retryCount: Int
    let videoJobId: String?  // Legacy - kept for backward compatibility
}
```

### ItemData
```swift
struct ItemData {
    let identifier: String        // Unique ID for this attachment
    let typeIdentifier: String    // "video", "image", etc.
    let data: Data               // Raw file data
    let fileName: String
    let noResample: Bool
    let videoJobId: String?      // Job ID if this item is a video
}
```

---

## Detailed Flow

### STEP 1: Upload Attachments Sequentially

```swift
for (index, item) in itemData.enumerated() {
    itemNumber = index + 1
    
    // Update progress
    "Uploading video 1/3..." (or "image")
    Progress: 20% + (index/total * 60%)
    Detail: filename
    
    // Upload item
    (result, jobId) = uploadToIPFS(item)
    
    // Store job ID if video
    if jobId != nil {
        jobIdMap[item.identifier] = jobId
    }
    
    uploadedAttachments.append(result)
}
```

### STEP 2: Check Results

**If ANY job IDs received:**
```swift
// Update itemData with job IDs
for (identifier, jobId) in jobIdMap {
    itemData[index].videoJobId = jobId
}

// Save to disk
savePendingUpload(tweet, updatedItemData, ...)

// Show message
Dialog: "Processing on server..."
        "Your tweet will be posted when ready"

// Wait 1.5 seconds
await Task.sleep(1_500_000_000)

// Close dialog
UploadProgressManager.completeUpload()

// Start background polling
pollAllJobsAndSubmitTweet(tweet, itemData, attachments)
```

**If NO job IDs (all images):**
```swift
// Submit tweet immediately
tweet.attachments = uploadedAttachments
uploadTweet(tweet)

// Close dialog
UploadProgressManager.completeUpload()
```

### STEP 3: Background Polling

```swift
// Extract all job IDs from itemData
jobItems = itemData.filter { $0.videoJobId != nil }
totalJobs = jobItems.count

completedCIDs = [:]  // jobId -> CID mapping
completedCount = 0

while pollAttempts < 120 && completedCount < totalJobs {
    
    // Check each job
    for jobItem in jobItems {
        jobId = jobItem.videoJobId
        
        // Skip already completed
        if completedCIDs[jobId] exists: continue
        
        status = checkVideoJobStatus(jobId)
        
        switch status:
            case "completed":
                completedCIDs[jobId] = cid
                completedCount++
                print("Job X/N complete!")
                
            case "failed":
                Show error toast
                Remove pending upload
                STOP ❌
                
            case "processing":
                continue polling
    }
    
    // Check if all complete
    if completedCount == totalJobs {
        submitTweetWithCompletedJobs(tweet, itemData, completedCIDs, attachments)
        DONE ✅
    }
    
    sleep(5 seconds)
}

// Timeout after 10 minutes
Show error: "Video processing timed out"
Remove pending upload
```

### STEP 4: Submit Tweet

```swift
submitTweetWithCompletedJobs(tweet, itemData, completedCIDs, attachments, retryCount=0) {
    
    // Build final attachments by replacing job IDs with CIDs
    for (index, attachment) in attachments {
        if itemData[index].videoJobId exists {
            jobId = itemData[index].videoJobId
            cid = completedCIDs[jobId]
            attachment.mid = cid  // Replace placeholder with actual CID
        }
    }
    
    tweet.attachments = finalAttachments
    
    // Submit
    try {
        uploadedTweet = uploadTweet(tweet)
        
        // Success
        Remove pending upload
        Increment tweet count
        Post .newTweetCreated notification
        
    } catch {
        // Retry up to 2 times
        if retryCount < 2 {
            sleep(2s or 4s)
            submitTweetWithCompletedJobs(..., retryCount++)
        } else {
            Show error: "Failed to post tweet"
            Remove pending upload
        }
    }
}
```

---

## Retry Flow (From Pending Upload Dialog)

```
User clicks "Retry Upload"
↓
Show progress dialog
↓
itemsWithJobIds = itemData.filter { $0.videoJobId != nil }
↓
IF itemsWithJobIds.isEmpty:
    → NO job IDs → Re-upload all attachments (Flow 1)
ELSE:
    → Check status of ALL jobs:
    
    FOR EACH item with jobId:
        status = checkVideoJobStatus(jobId)
        
        IF "completed":
            completedCIDs[jobId] = cid
            
        ELSE IF "processing":
            allCompleted = false
            
        ELSE IF "failed":
            anyFailed = true
            BREAK
    
    IF anyFailed:
        Show error: "Video processing failed"
        Remove pending upload
        STOP ❌
        
    ELSE IF allCompleted:
        ALL jobs done!
        submitTweetWithCompletedJobs(...)
        DONE ✅
        
    ELSE:
        Some still processing
        Close dialog: "Processing on server..."
        Start background polling
```

---

## Failure Modes

### ANY Job Fails → ENTIRE Upload Fails

```
3 videos uploading:
├─ Video 1: Complete (CID #1) ✅
├─ Video 2: Failed ❌
└─ Video 3: Processing...

Result: Upload FAILS
Action: Show error toast, remove pending upload
User must: Start over completely
```

**Rationale:** Partial uploads create inconsistent state

---

## Progress Messages

### Sequential Upload Progress
- "Uploading video 1/3..." → "Uploading video 2/3..." → "Uploading image 3/3..."
- Sub-progress for each item: "Converting video... (45%)"
- Overall progress bar: 20% → 80%

### Completion Message
- "Processing on server..."
- "Your tweet will be posted when ready"
- Shown for 1.5 seconds before dialog closes

### Background Polling (Silent)
- No UI shown
- Logs: "⏳ 1/2 jobs complete, polling..."
- Toast only on final success/failure

---

## Key Guarantees

✅ **One-by-one upload** - User sees each item being processed  
✅ **Dialog closes early** - As soon as uploads to server complete  
✅ **All jobs must complete** - Wait for ALL videos to process  
✅ **Any failure stops all** - Consistent state  
✅ **Tweet submission retries** - Up to 2 times  
✅ **No re-upload on retry** - Check server status only  
✅ **Foreground for uploads** - Background for polling  
✅ **Screen stays on** - During foreground operations

---

## Code Summary

```swift
// Main entry point
uploadTweetWithPersistenceAndRetry(tweet, itemData, retryCount, videoJobId)
  |
  ├─ Has job IDs? → Retry logic (check server only)
  └─ No job IDs? → Upload attachments sequentially
      |
      ├─ For each item: Show "Uploading X/N..."
      ├─ Collect all job IDs
      ├─ Save to disk with job IDs
      ├─ Show "Processing on server..."
      ├─ Close dialog
      └─ pollAllJobsAndSubmitTweet() in background
          |
          ├─ Check all jobs every 5s
          ├─ If any fails → Show error, stop
          ├─ If all complete → submitTweetWithCompletedJobs()
          └─ Retry tweet submission 2× if needed
```

This algorithm handles any combination of attachments while keeping the user informed and allowing the app to remain usable!

