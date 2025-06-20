#!/bin/bash

echo "=========================================="
echo "FFmpeg-iOS Swift Package Integration Script"
echo "=========================================="
echo ""

echo "This script will guide you through adding the FFmpeg-iOS Swift Package to your Xcode project."
echo ""

# Check if we're in the right directory
if [ ! -d "Tweet.xcworkspace" ]; then
    echo "❌ Error: Tweet.xcworkspace directory not found in current directory"
    echo "Please run this script from the Tweet-iOS project root directory"
    exit 1
fi

echo "✅ Found Tweet.xcworkspace"
echo ""

echo "Step-by-step instructions to add FFmpeg-iOS Swift Package:"
echo ""
echo "1. Open Xcode and open Tweet.xcworkspace"
echo "2. In Xcode, go to File → Add Package Dependencies..."
echo "3. In the search field, enter: https://github.com/kewlbear/FFmpeg-iOS.git"
echo "4. Click 'Add Package'"
echo "5. Select your target (Tweet) and click 'Add Package'"
echo "6. Wait for Xcode to resolve and download the package"
echo ""

echo "After adding the package, you can test the integration by:"
echo "1. Building the project (⌘+B)"
echo "2. Running the app in simulator or device"
echo "3. The FFmpegWrapper will automatically detect if FFmpeg-iOS is available"
echo "4. Upload a video file to test HLS conversion"
echo ""

echo "Files created for integration:"
echo "✅ Sources/Core/FFmpegWrapper.swift - Main wrapper class"
echo "✅ FFMPEG_INTEGRATION.md - Complete integration guide"
echo ""

echo "New Features:"
echo "✅ Automatic video conversion to HLS format with 720p resolution"
echo "✅ Zip packaging of HLS files for backend upload"
echo "✅ Integration with HproseInstance.uploadToIPFS method"
echo ""

echo "To test the integration:"
echo "1. Upload a video file through the app"
echo "2. The system will automatically convert it to HLS format"
echo "3. Check the backend for the zip package containing HLS files"
echo "4. Verify the uploaded file type is 'zip' for video files"
echo ""

echo "Package URL: https://github.com/kewlbear/FFmpeg-iOS.git"
echo "Documentation: FFMPEG_INTEGRATION.md"
echo ""

echo "=========================================="
echo "Integration script completed!"
echo "==========================================" 