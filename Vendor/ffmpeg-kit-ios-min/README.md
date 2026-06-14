# Minimal FFmpegKit iOS Build

This local pod replaces the default `ffmpeg-kit-ios` CocoaPod with a smaller FFmpegKit build for Tweet's local video conversion flow.

Build characteristics:

- iOS deployment target: 15.0
- Architectures: `ios-arm64`, `ios-arm64_x86_64-simulator`
- Enabled platform libraries: zlib, AudioToolbox, VideoToolbox
- Excluded: GPL x264/x265 and the broader "full" FFmpegKit dependency set

The app commands use `h264_videotoolbox` instead of `libx264`, so this build does not include x264.
