# Video Normalization and Processing Improvements for Android

Apply the following video processing improvements to the Android version, mirroring the iOS implementation:

## Core Requirements

### 1. Video Normalization Algorithm (OPTIMIZED)

**Optimization: Skip normalization for videos ≤ 720p**

**Initial Processing:**
- **If video resolution ≤ 720p**: Skip normalization entirely, use original file and original file size for routing
- **If video resolution > 720p**: Normalize to 720p with 1000k bitrate, use normalized file and normalized file size for routing

**Rationale:** Since videos ≤ 720p would keep their original resolution anyway, there's no need to re-encode them. This saves processing time and maintains original quality.

**Resolution Detection:**
- Video resolution is defined by:
  - **Landscape** (width ≥ height): Resolution = **HEIGHT** (e.g., 1280×720 = 720p)
  - **Portrait** (height > width): Resolution = **WIDTH** (e.g., 720×1280 = 720p)
- Do NOT use max(width, height) - this is incorrect

### 2. Routing After Normalization

**Size-based routing:**
- If normalized video ≤ 32MB: Upload as **progressive video** (no HLS conversion)
- If normalized video > 32MB: Convert to HLS based on resolution

**Resolution-based HLS routing:**
- If resolution > 480p: Create HLS with **720p + 480p** variants (dual variant)
- If resolution ≤ 480p: Create HLS with **480p variant only** (single variant)

**Important:** When creating HLS variants, **never upscale**:
- If source resolution < target resolution, keep original resolution
- Example: 360p source → "480p" HLS variant should remain 360p (not upscaled)

### 3. Bitrate Handling

**Always use calculated bitrate:**
- Do NOT try to detect original bitrate - it's unreliable
- Always calculate proportional bitrate based on resolution
- For HLS variants:
  - 720p variant: Always use 1000k bitrate
  - 480p variant: Always use 600k bitrate

### 4. Video Metadata Detection

**Replace unreliable ffprobe with native Android APIs:**
- Use `MediaMetadataRetriever` or `MediaExtractor` instead of ffprobe
- Extract: width, height, rotation, display dimensions
- Handle rotation correctly (swap dimensions for 90°/270° rotation)

### 5. Performance & Priority

- Run normalization task with **high priority** to ensure foreground processing
- Ensure task runs in foreground, not background

### 6. Logging Improvements

- Log actual output resolution, not hardcoded values
- Example: "Normalized to 640×360 (360p) with 500k bitrate" instead of "Normalized to 720p"

## Implementation Notes

1. **Avoid upscaling**: Always check if source resolution < target before scaling
2. **Preserve resolution**: When source is ≤ 720p, keep original resolution with calculated bitrate
3. **Memory efficiency**: Use streaming approach for HLS directory compression (if applicable)
4. **Error handling**: Fallback gracefully if metadata extraction fails

## Example Flow for 640×360 (360p) Video:

1. **Detection**: 640×360 landscape → 360p resolution
2. **Normalization**: Keep 640×360, use 500k bitrate (1000k × 360/720)
3. **Size check**: If > 32MB → HLS conversion
4. **Routing**: 360p ≤ 480p → Single variant (480p target)
5. **HLS conversion**: Create 480p variant, but keep 360p (no upscaling)

## Example Flow for 1280×720 (720p) Video:

1. **Detection**: 1280×720 landscape → 720p resolution
2. **Normalization**: Already 720p, use 1000k bitrate
3. **Size check**: If > 32MB → HLS conversion
4. **Routing**: 720p > 480p → Dual variant (720p + 480p)
5. **HLS conversion**: Create both variants (720p @ 1000k, 480p @ 600k)

## Example Flow for 1920×1080 (1080p) Video:

1. **Detection**: 1920×1080 landscape → 1080p resolution
2. **Normalization**: Scale to 720p, use 1000k bitrate
3. **Size check**: If > 32MB → HLS conversion
4. **Routing**: Normalized is 720p > 480p → Dual variant (720p + 480p)
5. **HLS conversion**: Create both variants from normalized 720p source
