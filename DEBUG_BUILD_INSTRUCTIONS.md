# Debug Build Instructions

## Overview
Your Tweet app is now configured to build separate debug and release versions that can coexist on the same device.

## Configuration Changes Made
- **Debug Bundle ID**: `com.example.Tweet.debug`
- **Debug App Name**: "M2O"
- **Release Bundle ID**: `com.example.Tweet` (unchanged)
- **Release App Name**: "dTweet" (unchanged)

## How to Build Debug Version

### Method 1: Using Xcode (Recommended)
1. Open `Tweet.xcworkspace` in Xcode
2. Select your device or simulator as the target
3. In the scheme selector (top-left), make sure "Tweet" is selected
4. **Important**: Change the build configuration from "Release" to "Debug"
   - Click on the scheme name → "Edit Scheme..."
   - Go to "Run" → "Build Configuration" → Select "Debug"
5. Click the "Build and Run" button (▶️)

### Method 2: Using Command Line
```bash
# Make the script executable (if not already done)
chmod +x build_debug.sh

# Run the build script
./build_debug.sh
```

### Method 3: Manual Xcode Build
```bash
# Clean and build debug version
xcodebuild clean -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug
xcodebuild build -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -destination "generic/platform=iOS"
```

## What You'll Get
- **Production App**: "dTweet" with bundle ID `com.example.Tweet`
- **Debug App**: "Tweet Debug" with bundle ID `com.example.Tweet.debug`

Both apps can be installed simultaneously on your device without conflicts.

## Verification
After building and installing the debug version:
1. Check your device's home screen - you should see both apps
2. The debug version will be named "M2O"
3. Both apps will have separate data storage and settings
4. You can use the production app normally while testing with the debug version

## Switching Between Builds
- **For Production**: Use "Release" configuration
- **For Development**: Use "Debug" configuration

The debug version includes additional debugging features and won't interfere with your published app.
