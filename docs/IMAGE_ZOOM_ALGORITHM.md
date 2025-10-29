# Image Zoom Algorithm Documentation

## Overview
This document describes the dynamic image zoom algorithm implemented in `MediaBrowserView.swift` for the full-screen image viewer. The algorithm provides intelligent zoom behavior based on image aspect ratios and screen dimensions.

## Algorithm Components

### 1. Aspect Ratio Detection
```swift
private func getActualAspectRatio() -> CGFloat {
    switch imageState {
    case .loaded(let image):
        return image.size.width / image.size.height
    case .placeholder(let image):
        return image.size.width / image.size.height
    default:
        return CGFloat(attachment.aspectRatio ?? 1.0)
    }
}
```

**Purpose**: Uses actual image dimensions instead of potentially incorrect metadata from attachments.

### 2. Dynamic Double-Tap Scale Calculation
```swift
private func calculateDoubleTapScale(for geometry: GeometryProxy) -> CGFloat {
    let screenWidth = geometry.size.width
    let screenHeight = geometry.size.height
    let actualAspectRatio = getActualAspectRatio()
    
    // For images with AR < 0.6: calculate scale to cover full width
    // For other images: use 2.0 as double-tap zoom scale
    if actualAspectRatio < 0.6 {
        // Image is tall, so it's fitted to screen height
        // Current width = screenHeight * actualAspectRatio
        // We want width = screenWidth
        // So scale = screenWidth / (screenHeight * actualAspectRatio)
        return screenWidth / (screenHeight * actualAspectRatio)
    } else {
        // Image is wide or normal, use 2.0 zoom
        return 2.0
    }
}
```

**Logic**:
- **Tall images (AR < 0.6)**: Calculate exact scale to make image width fill screen width
- **Wide/normal images (AR ≥ 0.6)**: Use fixed 2.0x zoom for better visibility

### 3. Maximum Scale Calculation
```swift
private func calculateMaxScale(for geometry: GeometryProxy) -> CGFloat {
    // Allow up to 2x the double-tap scale for pinch zoom
    return calculateDoubleTapScale(for: geometry) * 2.0
}
```

**Purpose**: Provides consistent pinch zoom behavior - always allows 2x the double-tap scale.

## Zoom Behavior by Image Type

### Tall Images (Aspect Ratio < 0.6)
- **Initial state**: Fitted to screen height (very narrow)
- **Double-tap**: Zooms to cover full screen width
- **Alignment**: Top-aligned when zoomed
- **Scrolling**: Only upward scrolling allowed
- **Example**: 0.06 aspect ratio image gets significant zoom to fill width

### Wide/Normal Images (Aspect Ratio ≥ 0.6)
- **Initial state**: Fitted to screen width (normal size)
- **Double-tap**: 2.0x zoom for better detail viewing
- **Alignment**: Centered
- **Scrolling**: Normal behavior in all directions

## Scroll Behavior Algorithm

### For Tall Images When Zoomed:
```swift
if actualAspectRatio < 0.6 {
    // Align to top: offset.y should be positive (image top aligned to screen top)
    let topAlignedOffsetY = maxOffsetY
    
    offset = CGSize(
        width: max(-maxOffsetX, min(maxOffsetX, offset.width + delta.width)),
        height: max(0, min(topAlignedOffsetY, offset.height + delta.height))
    )
}
```

**Constraints**:
- **Top limit**: `height: max(0, ...)` - can't scroll above top alignment
- **Bottom limit**: `height: min(topAlignedOffsetY, ...)` - can't scroll below top alignment
- **Result**: Only upward scrolling allowed

## Drag-to-Exit Protection

### State Management:
```swift
@State private var isImageZoomed = false // Track if current image is zoomed
```

### Protection Logic:
```swift
.gesture(
    DragGesture()
        .onChanged { value in
            // Only allow drag-down-to-exit if no image is zoomed
            if value.translation.height > 0 && !isImageZoomed {
                dragOffset = value.translation
                isDragging = true
                showControls = true
            }
        }
        .onEnded { value in
            // Only allow exit if no image is zoomed
            if !isImageZoomed && (value.translation.height > 100 || value.velocity.height > 500) {
                dismiss()
            }
        }
)
```

**Behavior**:
- **When zoomed**: Drag-down-to-exit disabled
- **When not zoomed**: Normal drag-down-to-exit behavior
- **State updates**: Automatically tracks zoom state across image switches

## Mathematical Formulas

### Scale Calculation for Tall Images:
```
scale = screenWidth / (screenHeight * aspectRatio)
```

**Where**:
- `screenWidth`: Device screen width
- `screenHeight`: Device screen height  
- `aspectRatio`: Image width / Image height

### Top Alignment Offset:
```
topAlignedOffsetY = (screenHeight * (scale - 1.0)) / 2
```

**Purpose**: Positions image top at screen top when zoomed.

## Implementation Benefits

1. **Adaptive**: Works with any screen size and image aspect ratio
2. **Intuitive**: Tall images zoom to fill width, wide images get reasonable zoom
3. **User-friendly**: Prevents accidental exits when zoomed
4. **Consistent**: Always allows 2x pinch zoom beyond double-tap scale
5. **Efficient**: Uses actual image dimensions for accurate calculations

## Edge Cases Handled

- **Very tall images** (AR < 0.1): Get significant zoom to fill width
- **Moderately tall images** (0.1 ≤ AR < 0.6): Get calculated zoom to fill width
- **Wide images** (AR ≥ 0.6): Get 2x zoom for detail viewing
- **Screen rotation**: Calculations adapt to new screen dimensions
- **Image switching**: Zoom state properly resets between images

## Future Enhancements

- **Memory optimization**: Could cache calculated scales for performance
- **Gesture improvements**: Could add momentum scrolling for tall images
- **Accessibility**: Could add voice-over descriptions for zoom levels
- **Customization**: Could allow users to set preferred zoom levels
