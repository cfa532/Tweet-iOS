# Complete Upload Algorithm

## Overview
This document describes the complete flow for uploading tweets/comments with attachments, including video processing, background polling, and retry logic.

---

## Flow 1: New Upload (HLS Video)

### User Action
User composes tweet with video attachment and clicks "Publish"

### Step-by-Step Process

```
1. USER CLICKS PUBLISH
   ↓
2. ComposeTweetView dismisses immediately
   ↓
3. Toast: "Tweet submitted"
   ↓
4. scheduleTweetUpload() called in background
   ↓
5. UploadProgressManager.startUpload(type: "tweet")
   - Shows progress overlay dialog
   - Disables auto-lock (screen stays on)
   - User sees: "Uploading attachments..." with progress bar
   - Warning: "Please keep the app open until upload completes"
   ↓
6. Save pending upload to disk
   - File: pendingTweetUpload.json
   - Contains: tweet data, attachment data, retry count, videoJobId
   ↓
7. CHECK CLOUD DRIVE SERVICE AVAILABILITY
   - Health check to http://HOST:cloudDrivePort/health
   - If unavailable → Use MP4 fallback (see Flow 3)
   ↓
8. CONVERT VIDEO TO HLS (FFmpeg)
   - Convert to 720p and 480p HLS variants
   - Create master playlist
   - Progress: 10-30%
   - Takes: 1-5 minutes (REQUIRES FOREGROUND)
   ↓
9. COMPRESS HLS DIRECTORY
   - Zip all HLS files
   - Progress: 40%
   ↓
10. UPLOAD ZIP TO SERVER
    - POST to http://HOST:cloudDrivePort/api/process-zip
    - Server returns: { "jobId": "xxx-xxx-xxx" }
    - Progress: 60-100%
    ↓
11. GOT JOB ID → CLOSE DIALOG
    - Save job ID to pending upload
    - UploadProgressManager.completeUpload()
    - Re-enable auto-lock
    - Dialog closes
    - User can now use app freely
    ↓
12. START BACKGROUND POLLING (pollAndSubmitTweet)
    - Runs in background Task.detached
    - Poll: GET http://HOST:cloudDrivePort/api/job-status/:jobId
    - Poll every 5 seconds
    - Max attempts: 120 (10 minutes total)
    ↓
13. SERVER PROCESSING
    - Status: "uploading" → Keep polling
    - Status: "processing" → Keep polling
    - Status: "completed" → Extract CID, go to step 14
    - Status: "failed" → Show error toast, remove pending upload
    ↓
14. VIDEO PROCESSED → SUBMIT TWEET
    - Create MimeiFileType with CID
    - Call hproseInstance.uploadTweet(tweet)
    - Retry up to 2 times if submission fails
    - Delay: 2s, 4s between retries
    ↓
15. TWEET SUBMITTED
    - Remove pending upload file
    - Increment user tweet count
    - Post .newTweetCreated notification
    - Toast: "Tweet posted successfully"
    - DONE ✅
```

---

## Flow 2: New Upload (Images/No Video)

```
1. USER CLICKS PUBLISH
   ↓
2. Dialog dismisses
   ↓
3. UploadProgressManager.startUpload(type: "tweet")
   - Shows progress dialog
   - Disables auto-lock
   ↓
4. UPLOAD IMAGES
   - Upload to IPFS
   - Get back MimeiFileType with CID
   - No job ID returned
   - Progress: 20-90%
   ↓
5. SUBMIT TWEET IMMEDIATELY
   - Tweet attachments = uploaded images
   - Call hproseInstance.uploadTweet(tweet)
   - Progress: 90-100%
   ↓
6. SUCCESS
   - Close dialog
   - Remove pending upload
   - Post .newTweetCreated notification
   - DONE ✅
```

---

## Flow 3: New Upload (MP4 Fallback)

Used when cloud drive service is unavailable

```
1. Health check fails → Use MP4 fallback
   ↓
2. CONVERT VIDEO TO MP4 (FFmpeg)
   - Resample to 720p or 480p (based on original resolution)
   - H.264 codec, MP4 container
   - Takes: 1-5 minutes (REQUIRES FOREGROUND)
   ↓
3. UPLOAD MP4 TO IPFS
   - Regular IPFS upload
   - Get back MimeiFileType with CID
   - No job ID
   ↓
4. SUBMIT TWEET
   - Same as Flow 2
   - DONE ✅
```

---

## Flow 4: Retry from Pending Upload Dialog

### When Triggered
- App returns to foreground
- OR app launches
- AND pending upload file exists (< 24 hours old)

### User Sees Dialog
- "Upload Interrupted"
- Shows: Type, Date, Attachments count, Content preview
- Options: **Retry Upload** or **Discard**

### User Clicks "Retry Upload"

```
1. START PROGRESS DIALOG
   - UploadProgressManager.startUpload(type: "tweet")
   ↓
2. CHECK IF VIDEO JOB ID EXISTS
   ↓
   YES → RETRY LOGIC (check server only, NO re-upload)
   |
   ├─→ GET JOB STATUS
   |    - Call checkVideoJobStatus(jobId, baseURL)
   |    ↓
   ├─→ STATUS: "completed"
   |    - Extract CID
   |    - Go to submitTweetWithCompletedVideo()
   |    - Retry tweet submission up to 2 times
   |    - DONE ✅
   |    ↓
   ├─→ STATUS: "uploading" or "processing"
   |    - Close dialog
   |    - Start background polling
   |    - Same as Flow 1 step 12
   |    ↓
   ├─→ STATUS: "failed"
   |    - Show error toast with server message
   |    - Remove pending upload
   |    - DONE ❌
   |    ↓
   └─→ NO STATUS (job expired or network error)
        - Show error toast: "Failed to check video status"
        - Remove pending upload
        - DONE ❌
   ↓
   NO → NEW UPLOAD (re-upload attachments)
   |
   └─→ Follow Flow 1 from step 7
       (Upload attachments in foreground with dialog)
```

---

## Flow 5: User Clicks "Discard"

```
1. Remove pendingTweetUpload.json
   ↓
2. Toast: "Upload discarded"
   ↓
3. DONE
```

---

## Flow 6: App Backgrounded During Upload

### Scenario A: During FFmpeg Conversion (Steps 8-9)

```
1. User switches to background
   ↓
2. UploadProgressManager detects (wasBackgrounded = true)
   ↓
3. iOS gives ~30s-3min background time (beginBackgroundTask)
   ↓
4. FFmpeg likely fails (too slow)
   ↓
5. Pending upload saved to disk (already done in step 6)
   ↓
6. Upload fails
   ↓
7. User returns to foreground
   ↓
8. Pending upload dialog appears
   ↓
9. User can retry or discard
```

### Scenario B: During Background Polling (Step 12)

```
1. User switches to background
   ↓
2. Dialog already closed (user free to use app)
   ↓
3. Background polling continues
   - Lightweight HTTP requests every 5s
   - Runs for ~10 minutes or until complete
   ↓
4. Video completes → Tweet submitted automatically
   ↓
5. Toast appears when user returns to foreground
   ↓
6. DONE ✅
```

### Scenario C: During Upload to Server (Step 10)

```
1. User switches to background
   ↓
2. iOS gives ~30s-3min for network operations
   ↓
3. If upload completes → Got job ID → Proceed to step 11
4. If upload times out → Error, pending upload remains
   ↓
5. User returns → Retry dialog appears
```

---

## Key Decision Points

### Decision 1: Use HLS or MP4?
```
IF cloudDrivePort configured AND service health check succeeds
  → Use HLS conversion
ELSE
  → Use MP4 fallback
```

### Decision 2: Close Dialog or Keep Open?
```
IF got video job ID back
  → Close dialog, poll in background
ELSE (images only or MP4 upload)
  → Keep dialog open until tweet submitted
```

### Decision 3: Retry Logic
```
IF videoJobId exists (retry from pending upload)
  → Check server status only (NO re-upload)
  → IF completed → Submit tweet
  → IF processing → Poll in background
  → IF failed → Show error, stop
ELSE (new upload or re-upload needed)
  → Upload attachments in foreground
  → Continue normal flow
```

### Decision 4: Tweet Submission Retry
```
IF tweet submission fails
  → Retry up to 2 times (total 3 attempts)
  → Delay: 2s, 4s between attempts
  → After 2 retries → Show error, give up
```

---

## Data Persistence

### Pending Upload File
**Location:** `FileManager.default.temporaryDirectory/pendingTweetUpload.json`

**Contains:**
```json
{
  "tweet": { ... },
  "itemData": [ ... ],
  "timestamp": 1697234567.89,
  "retryCount": 0,
  "videoJobId": "xxx-xxx-xxx" // Present if video uploaded
}
```

**Lifecycle:**
- Created: Before attachment upload starts
- Updated: When job ID received
- Removed: On successful tweet submission
- Expires: After 24 hours
- Checked: On app launch and foreground

---

## Auto-Lock Prevention

**Disabled When:**
- Upload dialog is visible
- FFmpeg converting video
- Uploading attachments

**Re-enabled When:**
- Dialog closes (upload complete or failed)
- Job ID received (switching to background polling)

**Why:**
- Prevents screen lock during foreground-only operations
- Once in background polling mode, screen can lock safely

---

## Background Limitations

### What REQUIRES Foreground
❌ FFmpeg video conversion (1-5 minutes)
❌ Large file uploads (if slow network)

### What WORKS in Background
✅ Job status polling (lightweight HTTP GET)
✅ Tweet submission (tiny JSON POST)
✅ Small network requests

### Maximum Background Time
- ~30 seconds to 3 minutes (iOS limitation)
- Polling continues as long as app is running

---

## Error Handling

### Server Job Failed
- Show toast: "Video processing failed"
- Remove pending upload
- User must start over

### Network Error During Polling
- Retry polling (up to 120 attempts)
- If all fail: Show toast, remove pending upload

### Tweet Submission Failed
- Retry up to 2 times (exponential backoff)
- If all fail: Show toast, remove pending upload

### Job Timeout (10 minutes)
- Show toast: "Video processing timed out"
- Remove pending upload

---

## User Experience Summary

### New Upload with Video
1. User uploads video → **Waits 1-5 min** (FFmpeg conversion + upload)
2. Dialog shows progress with warning message
3. Screen won't auto-lock
4. Once uploaded → **Dialog closes** → User free to use app
5. Video processes on server (invisible to user)
6. When done → Toast: "Tweet posted successfully"

### Retry from Dialog
1. User sees dialog on foreground
2. Clicks "Retry Upload"
3. App checks server job status (fast)
4. If processing → Dialog closes, continues in background
5. If completed → Submits tweet immediately
6. If failed → Shows error, stops

### If App Backgrounded
1. During conversion → Upload fails, can retry later
2. During polling → Continues in background, auto-posts when done

---

## Code Flow Summary

```swift
// NEW UPLOAD
uploadTweetWithPersistenceAndRetry(tweet, itemData, retryCount=0, videoJobId=nil)
  ├─→ Save pending upload
  ├─→ Upload attachments (foreground, dialog visible)
  │   ├─→ If video: Convert → Upload → Get jobId
  │   └─→ If images: Upload → Get CID
  ├─→ If got jobId:
  │   ├─→ Close dialog
  │   └─→ pollAndSubmitTweet(tweet, jobId) in background
  └─→ Else (no jobId):
      └─→ Submit tweet immediately (foreground, dialog visible)

// RETRY FROM DIALOG  
uploadTweetWithPersistenceAndRetry(tweet, itemData, retryCount=N, videoJobId=XXX)
  ├─→ Check job status with server
  ├─→ If "completed": submitTweetWithCompletedVideo(cid)
  ├─→ If "processing": Close dialog → pollAndSubmitTweet() in background
  └─→ If "failed": Show error toast, remove pending upload

// BACKGROUND POLLING
pollAndSubmitTweet(tweet, jobId)
  ├─→ Poll every 5s for up to 10 minutes
  ├─→ When "completed": submitTweetWithCompletedVideo(cid)
  ├─→ If "failed": Show error toast
  └─→ If timeout: Show error toast

// TWEET SUBMISSION
submitTweetWithCompletedVideo(tweet, cid, retryCount=0)
  ├─→ Create MimeiFileType with CID
  ├─→ Call hproseInstance.uploadTweet(tweet)
  ├─→ If fails: Retry up to 2 times (delay 2s, 4s)
  ├─→ If success: Remove pending upload, post notification
  └─→ If max retries: Show error toast, remove pending upload
```

---

## Key Points We Agreed On

✅ **Foreground Only:**
- FFmpeg video conversion
- Uploading attachments to server

✅ **Background Safe:**
- Polling job status (lightweight HTTP GET)
- Submitting final tweet (tiny JSON POST)

✅ **Dialog Closes Early:**
- As soon as video is uploaded and job ID received
- User doesn't wait for server processing

✅ **Retry Logic:**
- Check server job status with job ID
- Never re-upload attachments
- Only retry tweet submission if it has all necessary data
- Tweet submission retries up to 2 times

✅ **Auto-Lock Prevention:**
- Disabled during foreground operations
- Re-enabled when dialog closes or fails

✅ **Persistence:**
- Upload state saved before attachment upload
- Updated when job ID received
- Removed on success
- Expires after 24 hours

✅ **User Control:**
- Pending uploads show dialog (not auto-retry)
- User chooses: Retry or Discard

---

## Timeline Example

### Successful HLS Upload
```
00:00 - User clicks publish → Dialog appears
00:01 - FFmpeg starts converting (screen stays on)
02:30 - Conversion done, compressing...
02:35 - Uploading zip to server...
03:00 - Got job ID → DIALOG CLOSES
        User can now browse app, screen can lock
03:00 - Background polling starts (invisible)
03:05 - Poll 1: "processing"
03:10 - Poll 2: "processing"
03:15 - Poll 3: "processing"
03:20 - Poll 4: "completed", CID received
03:20 - Submit tweet
03:21 - Tweet submission success!
03:21 - Toast: "Tweet posted successfully"
        DONE ✅
```

### Failed During Conversion (App Backgrounded)
```
00:00 - User clicks publish → Dialog appears
00:30 - FFmpeg converting... user backgrounds app
00:32 - iOS suspends app, FFmpeg fails
------ App in background ------
05:00 - User returns to foreground
05:00 - Pending upload dialog appears
        "Your upload was interrupted..."
        [Retry Upload] [Discard]
```

### Retry with Existing Job
```
00:00 - User clicks "Retry Upload"
00:00 - Dialog shows "Checking video status..."
00:01 - Status check: "processing"
00:01 - Dialog closes, background polling starts
00:15 - Status: "completed", CID received
00:15 - Submit tweet (retry 1/3)
00:15 - Success! Toast appears
        DONE ✅
```

---

## Questions Answered

**Q: What happens if app goes to background during upload?**
A: Depends on stage:
- During FFmpeg: Fails, can retry later
- During polling: Continues in background

**Q: Can retry re-upload attachments?**
A: No, retry only checks server job status

**Q: How many times do we retry tweet submission?**
A: Up to 2 times (total 3 attempts) with exponential backoff

**Q: When does screen auto-lock?**
A: Never during foreground upload. Re-enabled when dialog closes.

**Q: How long does background polling last?**
A: Up to 10 minutes (120 attempts × 5 seconds)

---

## Summary

**The algorithm is optimized for:**
1. ✅ Minimal user wait time (dialog closes as soon as heavy work is uploaded)
2. ✅ Background-safe operations (polling and submission)
3. ✅ Robust retry logic (check server status, retry submission)
4. ✅ No data loss (everything persisted to disk)
5. ✅ User control (dialog for interruptions, not auto-retry)
6. ✅ Screen stays on during critical operations
7. ✅ Graceful failure handling with clear error messages

