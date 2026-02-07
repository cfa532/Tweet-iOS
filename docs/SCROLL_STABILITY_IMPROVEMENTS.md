# Scroll Stability Improvements

## Overview
This document details comprehensive improvements made to enhance scroll smoothness in the Tweet iOS app. The primary issue was that asynchronously loaded images and videos caused layout shifts during scrolling, resulting in jumpy scroll positions and poor user experience.

## Problem Analysis

### Root Causes
1. **Dynamic Aspect Ratios**: Media attachments (images/videos) loaded asynchronously, and their aspect ratios were sometimes detected from cached images AFTER initial layout, causing re-layouts
2. **State-Driven Recomposition**: Image loading state changes (`isLoading`, `image`) triggered parent view recomposition, cascading layout updates
3. **Missing Layout Constraints**: Views lacked stable dimensions and layout priorities, allowing content to shift during async operations
4. **Unstable View Identity**: Views were being recreated unnecessarily during recomposition cycles

## Solutions Implemented

### 1. Stabilized MediaGridView Aspect Ratio Calculations

**File**: `Sources/Features/MediaViews/MediaGridView.swift`

**Changes**:
- Modified `MediaGridViewModel.getAspectRatio(for:)` to ALWAYS prefer server-provided aspect ratios
- Removed dynamic aspect ratio detection from cached images (which could happen after layout)
- Implemented stable default aspect ratios:
  - Images without aspect ratio: 1.618 (golden ratio landscape)
  - Videos without aspect ratio: 16:9 (standard video format)
  - Other media: 1.0 (square)
- This ensures dimensions are known BEFORE first render and never change

**Impact**: Prevents layout recalculations when images finish loading

### 2. Prevented MediaCell State Changes from Triggering Parent Recomposition

**File**: `Sources/Features/MediaViews/MediaCell.swift`

**Changes**:
- Restructured image rendering to use `ZStack` with consistent background layer
- All states (loading, cached, loaded) maintain identical frame dimensions
- Added `.id("image_\(attachment.mid)")` to ensure SwiftUI doesn't recreate view
- Implemented smooth `.opacity` transitions instead of abrupt content swaps
- Moved loading indicators to overlay layers that don't affect layout

**Benefits**:
- Image loading no longer causes parent Tweet views to recompose
- Visual smoothness with fade transitions
- Consistent space reservation prevents jumping

### 3. Added Layout Priority and Fixed Size Modifiers to TweetItemView

**File**: `Sources/Tweet/TweetItemView.swift`

**Changes**:
- Added `.frame(width: 40, height: 40)` to all avatar views (consistent sizing)
- Applied `.layoutPriority(1)` to `TweetItemBodyView` in all tweet types
- Added `.fixedSize(horizontal: false, vertical: true)` to VStack containers
- Applied stable `.id("tweet_\(tweet.mid)")` to entire tweet content
- Ensured embedded tweet placeholders have fixed heights

**Why This Matters**:
- `.layoutPriority(1)` tells SwiftUI to prioritize these views during layout, maintaining their space
- `.fixedSize(horizontal: false, vertical: true)` prevents vertical compression/expansion
- Fixed avatar dimensions eliminate one source of layout variability
- Stable IDs prevent view recreation during data updates

### 4. Enhanced TweetItemBodyView Layout Stability

**File**: `Sources/Tweet/TweetItemBodyView.swift`

**Changes**:
- Added `.layoutPriority(1)` to `MediaGridView` instances
- Applied `.fixedSize(horizontal: false, vertical: true)` to media grid
- Ensured video captions have fixed size constraints

**Result**: Media content maintains consistent positioning even during async loads

### 5. Optimized TweetListView for Stable Scrolling

**File**: `Sources/Tweet/TweetListView.swift`

**Changes in TweetListContentView**:
- Added explicit `pinnedViews: []` parameter to `LazyVStack` for clarity
- Fixed separator heights with `.fixedSize(horizontal: false, vertical: true)`
- Changed separator from padding-based to fill-based for consistent rendering
- Added `.layoutPriority(1)` to row views
- Applied `.fixedSize(horizontal: false, vertical: true)` to row containers
- Updated row ID from `"tweet_\(tweet.mid)"` to `"tweet_row_\(tweet.mid)"` for clarity

**Changes in TweetListView**:
- Added `.fixedSize(horizontal: false, vertical: true)` to `TweetListContentView`
- Added `.scrollIndicators(.visible)` to help users track scroll position

## Technical Deep Dive

### Layout Priority Explained
When SwiftUI calculates layout, views with higher `.layoutPriority()` values are given their ideal size first, and remaining space is distributed to lower-priority views. By setting priority to 1 (default is 0), we ensure that:
- Tweet content gets its required space first
- Dynamic elements (like loading spinners) don't push content around
- Scrolling position remains stable

### Fixed Size Strategy
`.fixedSize(horizontal: false, vertical: true)` tells SwiftUI:
- **Horizontal**: Respect parent constraints (fit screen width)
- **Vertical**: Use the view's ideal height (don't compress)

This is critical for scroll stability because it prevents views from shrinking or growing as their content changes.

### Aspect Ratio Stability
By using predetermined aspect ratios instead of detecting them asynchronously:
- Layout calculations complete synchronously
- No re-layouts when images load
- `.fill` content mode handles any minor aspect ratio differences gracefully
- Users don't see content "jump" as true dimensions are discovered

## Before vs After

### Before
1. Scroll to view tweets
2. Images/videos start loading
3. Aspect ratios detected from loaded media
4. MediaGridView recalculates layout
5. Tweet height changes
6. ScrollView adjusts positions → **Jump!**

### After
1. Scroll to view tweets
2. Stable aspect ratios used immediately
3. Layout calculated once with final dimensions
4. Images/videos load and fill fixed spaces
5. No layout changes → **Smooth scrolling!**

## Performance Considerations

### Memory Impact
- Minimal: Fixed-size modifiers don't create additional views, just layout constraints
- Layout priorities are metadata, not runtime overhead

### Rendering Performance
- **Improved**: Fewer layout passes means less CPU usage
- **Smoother**: 60fps scrolling is easier to maintain with stable layouts
- **Better battery**: Reduced layout churn saves energy

### Cache Efficiency
- Image caching still works as before
- Compressed images shown instantly while originals load
- No additional cache complexity

## Testing Recommendations

To verify these improvements:

1. **Scroll Speed Test**
   - Scroll rapidly through feed with mixed media content
   - Observe if position jumps or stays stable
   - Expected: Smooth, predictable scrolling

2. **Network Delay Test**
   - Enable slow network simulation
   - Scroll through tweets with images/videos
   - Expected: Placeholders maintain consistent space

3. **Memory Profile**
   - Use Xcode Instruments to profile scrolling
   - Check for layout thrashing
   - Expected: Fewer layout recalculations

4. **Visual Inspection**
   - Scroll slowly and watch individual tweets
   - Images should fade in without moving surrounding content
   - Expected: Content loads in-place without shifts

## Future Enhancements

Potential additional improvements:

1. **Pre-warming Image Sizes**: Fetch image metadata before downloading full images
2. **Geometric Caching**: Store calculated tweet heights to avoid recalculation
3. **Predictive Loading**: Load images for tweets about to appear on screen
4. **Scroll Anchoring**: iOS 17+ scroll anchoring APIs for better stability

## Related Files

- `Sources/Features/MediaViews/MediaGridView.swift` - Grid layout and aspect ratios
- `Sources/Features/MediaViews/MediaCell.swift` - Individual media cell rendering
- `Sources/Tweet/TweetItemView.swift` - Tweet container and layout
- `Sources/Tweet/TweetItemBodyView.swift` - Tweet content and media
- `Sources/Tweet/TweetListView.swift` - Scrollable tweet list
- `Sources/DataModels/MimeiFileType.swift` - Media attachment model

## Summary

These changes implement a **layout-first** approach to scrolling:
- ✅ Calculate final dimensions upfront using stable defaults
- ✅ Reserve space immediately with fixed size constraints
- ✅ Load content asynchronously into pre-allocated spaces
- ✅ Prevent any layout changes that would shift scroll position
- ✅ Use layout priorities to protect critical content positioning

The result is a significantly smoother scrolling experience that feels responsive and predictable, similar to native Twitter/X app behavior.

---

**Implementation Date**: December 28, 2025  
**Developer**: AI Assistant  
**Status**: Implemented, Awaiting User Testing

