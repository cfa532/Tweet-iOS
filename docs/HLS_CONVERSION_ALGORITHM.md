# HLS Video Conversion Algorithm

**Last Updated:** December 21, 2025  
**Status:** ✅ Production  
**File:** `Sources/Core/VideoConversionService.swift`

---

## Overview

The HLS (HTTP Live Streaming) conversion algorithm processes video uploads through a multi-stage pipeline: normalization, routing, and HLS conversion with adaptive bitrate variants. The system optimizes for file size, resolution, and playback quality while maintaining memory efficiency.

---

## Algorithm Flow

```
┌─────────────────┐
│  Original Video │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│ 1. Resolution Detection │
│    - Detect width/height │
│    - Calculate aspect    │
│    - Determine resolution│
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ 2. Normalization        │
│    - ≤720p: Keep orig    │
│    - >720p: Scale to 720p│
│    - Apply bitrate       │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ 3. Size Check           │
│    - ≤32MB: Progressive │
│    - >32MB: HLS Route    │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ 4. Resolution Routing   │
│    - >480p: Dual variant │
│    - ≤480p: Single variant│
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ 5. HLS Conversion       │
│    - Create variants    │
│    - Generate playlists │
│    - Master playlist    │
└─────────────────────────┘
```

---

## Stage 1: Resolution Detection

### Purpose
Determine the video's resolution to make routing decisions.

### Implementation
```swift
let videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
let aspectRatio = Float(width) / Float(height)

// Resolution calculation:
// - Landscape (aspectRatio ≥ 1.0): Resolution = HEIGHT
// - Portrait (aspectRatio < 1.0): Resolution = WIDTH
let resolution = aspectRatio < 1.0 ? width : height
```

### Examples
- `1280×720` landscape → **720p**
- `720×1280` portrait → **720p**
- `1920×1080` landscape → **1080p**
- `640×360` landscape → **360p**

**Important:** Never use `max(width, height)` - this is incorrect for portrait videos.

---

## Stage 2: Video Normalization

### Purpose
Standardize video resolution and bitrate before routing decisions.

### Algorithm

#### For Videos ≤ 720p:
- **Action:** Keep original resolution
- **Bitrate:** Calculate proportional bitrate **based on pixel count**
  ```swift
  pixelCount = width × height
  bitrate = max(500k, (pixelCount / 921600) × 1000k)
  ```
- **Example:** 360p video (640×360 = 230,400 pixels) → 250k → 500k (capped at minimum)

#### For Videos > 720p:
- **Action:** Scale down to 720p
- **Bitrate:** 1500k (higher bitrate for downscaled content)
- **Example:** 1080p video → 720p @ 1500k

### Bitrate Calculation Reference (Pixel-Based)

| Resolution | Dimensions | Pixels | Pixel-Based Calculation | Final Bitrate |
|------------|------------|--------|-------------------------|---------------|
| **>720p** | 1920×1080 | 2,073,600 | 1500k (fixed for downscale) | **1500k** |
| **720p** | 1280×720 | 921,600 | 1000k (base reference) | **1000k** |
| **480p** | 854×480 | 409,920 | (409920/921600) × 1000k = 445k | **500k** (min) |
| **360p** | 640×360 | 230,400 | (230400/921600) × 1000k = 250k | **500k** (min) |
| **240p** | 426×240 | 102,240 | (102240/921600) × 1000k = 111k | **500k** (min) |

**Formula:**
```swift
pixelCount = width × height
REFERENCE_720P_PIXELS = 921,600  // 1280 × 720
calculatedBitrate = (pixelCount / REFERENCE_720P_PIXELS) × 1000k
finalBitrate = max(500k, calculatedBitrate)
```

**Why Pixel-Based?**
- Bitrate scales with **data amount** (pixels), not just one dimension
- 480p has ~44% of 720p pixels → should get ~44% bitrate (445k)
- More accurate than linear scaling (which would give 667k)
- Matches video encoding theory: bitrate ∝ resolution × frame rate × bit depth

**Minimum Bitrate:** 500kbps (industry standard to prevent compression artifacts)

**Why 500kbps minimum?**
- Industry standard (Red5: 500kbps for 480p, BoxCast: 700kbps for 480p)
- Prevents excessive compression artifacts in low-resolution videos
- Pixel-based calculation gives very low bitrates for small resolutions
- Ensures acceptable quality even for very low resolutions (240p-480p range)

### Code Reference
```swift
// Sources/Core/VideoConversionService.swift & HproseInstance.swift
let REFERENCE_720P_PIXELS = 921600  // 1280 × 720
let pixelCount = width × height
let calculatedBitrate = Int((Double(pixelCount) / Double(REFERENCE_720P_PIXELS)) * 1000.0)
let finalBitrate = max(500, calculatedBitrate)
```

---

## Stage 3: Size-Based Routing

### Purpose
Determine if video should use progressive (MP4) or HLS format.

### Threshold
- **≤ 32MB:** Progressive video (direct MP4 upload)
- **> 32MB:** HLS conversion required

### Rationale
- Small videos (<32MB) can be streamed directly as MP4
- Large videos benefit from HLS adaptive streaming
- Reduces server load for small files

### Code Reference
```swift
// Sources/Core/HproseInstance.swift:3109
if videoSize <= Constants.PROGRESSIVE_VIDEO_THRESHOLD_BYTES {
    // Progressive route
} else {
    // HLS route
}
```

---

## Stage 4: Resolution-Based HLS Routing

### Purpose
Determine HLS variant configuration based on normalized video resolution.

### Algorithm

#### Resolution > 480p:
- **Variant Mode:** Dual variant
- **High-Quality Variant:** Actual resolution (capped at 720p)
- **Lower Variant:** 480p
- **Example:** 720p video → 720p + 480p variants

#### Resolution ≤ 480p:
- **Variant Mode:** Single variant
- **Single Variant:** 480p target (but preserves original if lower)
- **Example:** 360p video → Single 480p variant (actual: 360p, no upscaling)

### Important: No Upscaling
- If source resolution < target resolution, **keep original resolution**
- Example: 360p source → "480p" variant remains 360p (not upscaled)
- Master playlist reflects actual resolution, not target

### Code Reference
```swift
// Sources/Core/HproseInstance.swift:3169-3193
if videoResolution > 480 {
    singleVariant480p = false  // Dual variant
} else {
    singleVariant480p = true   // Single variant
}
```

---

## Stage 5: HLS Conversion Process

### Step 5.1: Directory Structure Creation

#### Single Variant Structure:
```
hls/
├── master.m3u8      (points to playlist.m3u8)
└── playlist.m3u8    (actual HLS playlist)
```

#### Dual Variant Structure:
```
hls/
├── master.m3u8      (points to both variants)
├── 720p/
│   ├── playlist.m3u8
│   └── segment000.ts, segment001.ts, ...
└── 480p/
    ├── playlist.m3u8
    └── segment000.ts, segment001.ts, ...
```

### Step 5.2: Resolution Calculation

For each variant, calculate actual output resolution:

```swift
// Preserve original if source < target
if sourceMaxDimension < targetResolution {
    finalWidth = sourceWidth
    finalHeight = sourceHeight
} else {
    // Calculate scaled resolution based on aspect ratio
    if aspectRatio < 1.0 {
        // Portrait: scale to target width
        scaleFilter = "scale=\(targetResolution):-2"
    } else {
        // Landscape: scale to target height
        scaleFilter = "scale=-2:\(targetResolution)"
    }
}
```

**Key Principle:** Never upscale. If source is smaller than target, preserve original dimensions.

### Step 5.3: Bitrate Calculation

#### High-Quality Variant (Dual Mode Only):
```swift
if sourceVideoResolution > 720 {
    bitrate = 1500k  // Downscaled from >720p
} else if sourceVideoResolution == 720 {
    bitrate = 1000k  // Base reference
} else {
    // Pixel-based calculation
    pixelCount = width × height
    calculatedBitrate = (pixelCount / 921600) × 1000k
    bitrate = max(500, calculatedBitrate)  // Min 500k for quality
}
```

#### Lower Variant (Always 480p):
```swift
// Calculate 480p equivalent dimensions based on aspect ratio
if portrait {
    lowerWidth = min(sourceWidth, 480)
    lowerHeight = lowerWidth / aspectRatio
} else {
    lowerHeight = min(sourceHeight, 480)
    lowerWidth = lowerHeight × aspectRatio
}

lowerPixelCount = lowerWidth × lowerHeight
calculatedBitrate = (lowerPixelCount / 921600) × 1000k
bitrate = max(500, calculatedBitrate)  // = 445k → 500k (min applied)
```

**Note:** The 500kbps minimum affects all resolutions ≤480p when using pixel-based calculation:
- 480p: 445k → 500k (min applied)
- 360p: 250k → 500k (min applied)
- 240p: 111k → 500k (min applied)

### Step 5.4: Variant Conversion

#### Dual Variant Mode:
1. **Convert High-Quality Variant** (10% progress)
   - Resolution: Actual source (capped at 720p)
   - Bitrate: Calculated based on source resolution
   - Output: `hls/720p/playlist.m3u8`

2. **Memory Cleanup** (between conversions)
   - Force garbage collection
   - 0.5 second pause for memory reclamation

3. **Convert Lower Variant** (60% progress)
   - Resolution: 480p (or original if <480p)
   - Bitrate: 667k (proportional)
   - Output: `hls/480p/playlist.m3u8`

#### Single Variant Mode:
1. **Convert Single Variant** (10% progress)
   - Resolution: 480p target (preserves original if <480p)
   - Bitrate: 667k (proportional)
   - Output: `hls/playlist.m3u8`

### Step 5.5: Codec Selection

#### COPY Codec (Fast Path)
Used when:
- Video is already normalized
- Normalized resolution matches variant target
- Avoids unnecessary re-encoding

**720p Variant:**
```swift
if normalizedResolution > 480 && normalizedResolution <= 720 {
    use COPY  // No re-encoding needed
}
```

**480p Variant:**
```swift
if normalizedResolution <= 480 {
    use COPY  // No re-encoding needed
}
```

#### libx264 Codec (Standard Path)
Used for:
- Non-normalized videos
- Resolution scaling required
- Compatibility and proper normalization

**Configuration:**
- Profile: `main`
- Level: `4.0`
- Preset: `veryfast` (speed/memory balance)
- Pixel format: `yuv420p`
- Threads: Limited to 4 (memory optimization)
- Buffer size: Half of bitrate (memory optimization)

### Step 5.6: Master Playlist Generation

#### Single Variant Master Playlist:
```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=667000,RESOLUTION=854x480
playlist.m3u8
```

#### Dual Variant Master Playlist:
```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720
720p/playlist.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=667000,RESOLUTION=854x480
480p/playlist.m3u8
```

**Key Points:**
- Bandwidth is in bits per second (kbps × 1000)
- Resolution reflects actual output (may differ from target)
- Single variant master points to root `playlist.m3u8`
- Dual variant master points to subdirectory playlists

---

## Memory Optimizations

### Pre-Conversion Cleanup
```swift
forceMemoryCleanup()  // Release autoreleased objects
logMemoryUsage("before conversion")
```

### Between Variant Conversions
```swift
forceMemoryCleanup()
await Task.yield()
try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s pause
```

### FFmpeg Configuration
- **Thread Limit:** 4 threads (reduces memory footprint)
- **Buffer Size:** Half of bitrate (reduces buffer requirements)
- **Preset:** `veryfast` (speed/memory balance)

### Memory Monitoring
- Logs memory usage at each stage
- Warns if memory > 200MB
- Critical warning if memory > 300MB

---

## Complete Example Flows

### Example 1: 1920×1080 (1080p) Video

1. **Resolution Detection:** 1080p (landscape)
2. **Normalization:** Scale to 720p @ 1500k bitrate
3. **Size Check:** Assume >32MB → HLS route
4. **Resolution Routing:** 720p > 480p → Dual variant
5. **HLS Conversion:**
   - High-quality: 720p @ 1500k → `hls/720p/playlist.m3u8`
   - Lower: 480p @ 667k → `hls/480p/playlist.m3u8`
   - Master: Points to both variants

### Example 2: 640×360 (360p) Video

1. **Resolution Detection:** 360p (landscape)
2. **Normalization:** Keep 360p @ 500k bitrate (proportional)
3. **Size Check:** Assume >32MB → HLS route
4. **Resolution Routing:** 360p ≤ 480p → Single variant
5. **HLS Conversion:**
   - Single: 360p @ 667k → `hls/playlist.m3u8` (no upscaling, actual: 360p)
   - Master: Points to `playlist.m3u8` with actual resolution (640×360)

### Example 3: 1280×720 (720p) Video

1. **Resolution Detection:** 720p (landscape)
2. **Normalization:** Keep 720p @ 1000k bitrate
3. **Size Check:** Assume >32MB → HLS route
4. **Resolution Routing:** 720p > 480p → Dual variant
5. **HLS Conversion:**
   - High-quality: 720p @ 1000k → `hls/720p/playlist.m3u8`
   - Lower: 480p @ 667k → `hls/480p/playlist.m3u8`
   - Master: Points to both variants

### Example 4: 720×1280 (720p Portrait) Video

1. **Resolution Detection:** 720p (portrait, width-based)
2. **Normalization:** Keep 720p @ 1000k bitrate
3. **Size Check:** Assume >32MB → HLS route
4. **Resolution Routing:** 720p > 480p → Dual variant
5. **HLS Conversion:**
   - High-quality: 720p @ 1000k → `hls/720p/playlist.m3u8` (actual: 720×1280)
   - Lower: 480p @ 667k → `hls/480p/playlist.m3u8` (scaled: 480×853)
   - Master: Points to both variants with actual resolutions

---

## Key Design Principles

### 1. Never Upscale
- Always preserve original resolution if source < target
- Master playlist reflects actual resolution, not target
- Prevents quality degradation from upscaling

### 2. Proportional Bitrate
- Bitrate scales with resolution
- Base reference: 1000k for 720p
- Minimum: 500k (prevents quality degradation)

### 3. Memory Efficiency
- Cleanup between conversions
- Limited thread count
- Optimized buffer sizes
- Progress monitoring

### 4. Codec Optimization
- Use COPY when possible (no re-encoding)
- libx264 for compatibility and scaling
- Fast preset for speed/memory balance

### 5. Consistent Structure
- Always create `master.m3u8` (single and dual variant)
- Single variant: master points to root playlist
- Dual variant: master points to subdirectory playlists

---

## Error Handling

### Normalization Failure
- Falls back to original video upload
- Logs error and continues with original file

### HLS Conversion Failure
- Returns error result
- No fallback (user must retry)

### Memory Pressure
- Logs warnings at 200MB
- Critical warnings at 300MB
- Continues conversion (may be slower)

---

## Performance Characteristics

### Conversion Time
- Single variant: ~30-60 seconds (depends on video length)
- Dual variant: ~60-120 seconds (two conversions)

### Memory Usage
- Pre-conversion: ~150MB
- During conversion: 200-300MB
- Peak: <400MB
- Cleanup between variants reduces memory

### File Size Reduction
- Normalization: 20-50% reduction (depends on source)
- HLS: Additional 10-20% reduction (segmentation overhead)

---

## Related Documentation

- [HLS Video Implementation](./HLS_VIDEO_IMPLEMENTATION.md) - Playback and caching system
- [Video System](./VIDEO_SYSTEM.md) - Overall video architecture
- [Upload System](./UPLOAD_SYSTEM.md) - Upload pipeline

---

## Code References

- **Main Conversion:** `Sources/Core/VideoConversionService.swift`
- **Normalization:** `Sources/Core/HproseInstance.swift:3622-3813`
- **Routing Logic:** `Sources/Core/HproseInstance.swift:2985-3193`
- **Resolution Detection:** `Sources/Core/HLSVideoProcessor.swift`

---

**Status:** ✅ Production Ready

All stages tested and optimized for production use.

