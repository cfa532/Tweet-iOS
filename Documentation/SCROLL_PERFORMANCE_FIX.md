# Scroll Performance Fix

## Problem
During initial tweet loading from the server, the scroll felt shaky and unstable. The rendering of tweets with media (images/videos) was impacting the general layout, causing the scroll to shake by itself, resulting in very poor UX.

## Root Causes

1. **Dynamic Layout Calculation**: `MediaGridView` used `GeometryReader` which calculates dimensions **after** initial layout, causing layout shifts
2. **No Fixed Height Reservation**: Images and videos loaded asynchronously without reserving their space upfront
3. **LazyVStack Behavior**: Tweet items were rendered on-demand, but their heights weren't predetermined, leading to content jumps

## Solution

### 1. Fixed Height Pre-calculation in MediaGridView
**File**: `Sources/Features/MediaViews/MediaGridView.swift`

- **Before**: Used `GeometryReader` to calculate grid dimensions dynamically
- **After**: Pre-calculate grid dimensions based on screen width before layout
  ```swift
  let screenWidth = UIScreen.main.bounds.width
  let gridWidth: CGFloat = max(10, screenWidth - 32)
  let gridAspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
  let gridHeight = max(10, gridWidth / gridAspectRatio)
  ```
- Applied fixed `.frame(height: gridHeight)` to prevent layout shifts
- GeometryReader still used internally for actual rendering, but height is fixed externally

### 2. Fixed Height Reservation in TweetItemBodyView
**File**: `Sources/Tweet/TweetItemBodyView.swift`

- **Before**: Used `.aspectRatio(aspect, contentMode: .fit)` without fixed height
- **After**: Pre-calculate and apply fixed height to media grid
  ```swift
  let screenWidth = UIScreen.main.bounds.width
  let gridWidth: CGFloat = max(10, screenWidth - 32)
  let aspect = MediaGridViewModel.aspectRatio(for: attachments)
  let gridHeight = max(10, gridWidth / aspect)
  
  MediaGridView(parentTweet: tweet, attachments: attachments)
      .frame(maxWidth: .infinity)
      .frame(height: gridHeight) // Fixed height to prevent shifts
  ```

### 3. Maintained Existing Placeholder System
**File**: `Sources/Features/MediaViews/MediaCell.swift`

- No changes needed - existing placeholder system (gray backgrounds, progress indicators) now work correctly with fixed heights
- Placeholders inherit fixed dimensions from parent frames

## Benefits

1. **Stable Scroll Experience**: Tweet heights are known before content loads, eliminating jumps
2. **Predictable Layout**: All media grids reserve their space immediately
3. **Smooth Loading**: Content loads within pre-allocated space without affecting scroll position
4. **No Breaking Changes**: Existing video loading, caching, and playback systems remain unchanged

## Technical Details

The fix leverages the fact that:
- Screen width is known immediately
- Aspect ratios are provided with tweet data from the server
- `MediaGridViewModel.aspectRatio(for:)` calculates optimal display ratio
- Pre-calculating `height = width / aspectRatio` provides exact dimensions before rendering

This approach is similar to skeleton loading but uses actual dimensions rather than arbitrary placeholders.

## Testing Recommendations

1. Test initial feed load with mixed content (text-only tweets, single images, multiple images, videos)
2. Scroll rapidly during initial load to verify no jumps
3. Test on different device sizes to ensure calculations work correctly
4. Verify video loading and playback still works as expected
5. Check that cached content still loads smoothly

## Related Files

- `Sources/Features/MediaViews/MediaGridView.swift` - Main media grid rendering
- `Sources/Tweet/TweetItemBodyView.swift` - Tweet body with media integration
- `Sources/Features/MediaViews/MediaCell.swift` - Individual media cell (unchanged)
- `Sources/Core/VideoLoadingManager.swift` - Video loading logic (unchanged)

## Date
October 10, 2025

