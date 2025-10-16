# Debug Build Instructions

**Date**: October 17, 2025  
**Purpose**: Guide for building and debugging the Tweet iOS app with console logs

## Overview

This document provides step-by-step instructions for:
1. Building the app in Debug mode
2. Installing on iOS Simulator
3. Capturing console logs
4. Testing background/foreground behavior

## Prerequisites

- Xcode installed
- iOS Simulator available
- Terminal access

## Step 1: Build in Debug Mode

### Using Terminal (Recommended)

```bash
# Navigate to project directory
cd /Users/cfa532/Documents/GitHub/Tweet-iOS

# Build in Debug mode with derived data path
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath ./DerivedData \
  build
```

### Key Differences from Release Mode

- **Debug mode**: Includes NSLog statements and debug symbols
- **Release mode**: Strips debug info, no console logs visible
- **DerivedDataPath**: Ensures we know where the built app is located

## Step 2: Boot iOS Simulator

```bash
# List available simulators
xcrun simctl list devices | grep -A 5 "iPhone"

# Boot a specific simulator (replace with actual UDID)
xcrun simctl boot 03E452D8-16BB-4188-A609-1C61565EB550

# Open Simulator app
open -a Simulator
```

## Step 3: Install the Debug Build

```bash
# Install the built app
xcrun simctl install 03E452D8-16BB-4188-A609-1C61565EB550 \
  /Users/cfa532/Documents/GitHub/Tweet-iOS/DerivedData/Build/Products/Debug-iphonesimulator/Tweet.app
```

## Step 4: Capture Console Logs

### Method 1: Launch with Console Output (Recommended)

```bash
# Launch app with console output
xcrun simctl launch --console 03E452D8-16BB-4188-A609-1C61565EB550 com.example.Tweet
```

This method shows logs in real-time and is perfect for debugging startup issues.

### Method 2: Background Log Stream

```bash
# Start log stream in background
log stream --predicate 'processImagePath contains "Tweet"' --level debug --style compact &

# Launch app normally
xcrun simctl launch 03E452D8-16BB-4188-A609-1C61565EB550 com.example.Tweet
```

### Method 3: Console App

1. Open **Console** app on macOS
2. Select your iOS Simulator in the sidebar
3. View real-time logs

## Step 5: Test Background/Foreground Behavior

### Simulate Background

```bash
# Send app to background
xcrun simctl device 03E452D8-16BB-4188-A609-1C61565EB550 press home
```

### Return to Foreground

```bash
# Bring app back to foreground
xcrun simctl launch 03E452D8-16BB-4188-A609-1C61565EB550 com.example.Tweet
```

## Expected Debug Logs

### App Startup

```
DEBUG: [AppDelegate] MuteState initialized early
DEBUG: [AppDelegate] LocalHTTPServer started on app launch
DEBUG: [LocalHTTPServer] ✅ Successfully bound to port 18355
DEBUG: [MUTE STATE] Mute state changed to: true
```

### Video Loading

```
DEBUG: [SHARED ASSET CACHE] Found valid cached playlist at: .../master.m3u8
DEBUG: [LocalHTTPServer] Served cached playlist with rewritten URLs
DEBUG: [CachingPlayerItem] Using LocalHTTPServer URL: http://127.0.0.1:18355/...
```

### Background/Foreground

```
[AppDelegate] App did enter background
[AppDelegate] App will enter foreground
[AppDelegate] Short background period, ensured LocalHTTPServer is running
```

## Troubleshooting

### Build Issues

**Problem**: Build fails with "Unable to find a device"
```bash
# Solution: Use exact simulator UDID
xcrun simctl list devices | grep "iPhone 16 Pro"
# Copy the UDID from output and use it
```

**Problem**: Build succeeds but no logs appear
```bash
# Solution: Ensure Debug mode
xcodebuild -configuration Debug ...
```

### Simulator Issues

**Problem**: Simulator won't boot
```bash
# Solution: Reset simulator
xcrun simctl shutdown 03E452D8-16BB-4188-A609-1C61565EB550
xcrun simctl erase 03E452D8-16BB-4188-A609-1C61565EB550
xcrun simctl boot 03E452D8-16BB-4188-A609-1C61565EB550
```

**Problem**: App won't install
```bash
# Solution: Check bundle identifier
# Verify the app bundle exists
ls -la /Users/cfa532/Documents/GitHub/Tweet-iOS/DerivedData/Build/Products/Debug-iphonesimulator/Tweet.app
```

### Log Issues

**Problem**: No logs appear
```bash
# Solution: Try different log methods
# Method 1: Direct launch with console
xcrun simctl launch --console 03E452D8-16BB-4188-A609-1C61565EB550 com.example.Tweet

# Method 2: Check if app is running
xcrun simctl list | grep Tweet
```

## Testing Specific Features

### Test MuteState Fix

1. Launch app and check for:
```
DEBUG: [MUTE STATE] Mute state changed to: true
```
2. Videos should be muted from first frame

### Test LocalHTTPServer Fix

1. Launch app and check for:
```
DEBUG: [LocalHTTPServer] ✅ Successfully bound to port 18355
```
2. Go to background for 5 seconds, return
3. Check for:
```
[AppDelegate] Short background period, ensured LocalHTTPServer is running
DEBUG: [LocalHTTPServer] Already running/starting/stopping, skipping duplicate start
```

### Test Long Background Recovery

1. Go to background for 6+ minutes
2. Return to foreground
3. Check for:
```
[AppDelegate] Long background period detected, restarting video infrastructure
DEBUG: [SHARED ASSET CACHE] Clearing video players for background recovery
```

## Performance Notes

- **Debug builds** are larger and slower than Release builds
- **Console logs** add overhead - disable in production
- **Simulator** performance may differ from real device
- **DerivedData** can be deleted to force clean builds

## Clean Build

```bash
# Clean derived data for fresh build
rm -rf /Users/cfa532/Documents/GitHub/Tweet-iOS/DerivedData

# Rebuild
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath ./DerivedData \
  build
```

## Quick Commands Reference

```bash
# Build and install in one command
xcodebuild -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath ./DerivedData build && xcrun simctl install 03E452D8-16BB-4188-A609-1C61565EB550 ./DerivedData/Build/Products/Debug-iphonesimulator/Tweet.app && xcrun simctl launch --console 03E452D8-16BB-4188-A609-1C61565EB550 com.example.Tweet

# Stop all simulators
xcrun simctl shutdown all

# List running simulators
xcrun simctl list devices | grep "Booted"
```

## Related Documentation

- [LocalHTTPServer Background Fix](fixes/LOCAL_HTTP_SERVER_BACKGROUND_FIX.md)
- [MuteState Startup Race Fix](fixes/MUTE_STATE_STARTUP_RACE_FIX.md)
- [Architecture Overview](ARCHITECTURE.md)
- [Video System Documentation](VIDEO_SYSTEM.md)

## Notes

- Always use Debug mode for development and testing
- Console logs are essential for debugging timing issues
- Background/foreground testing requires simulator commands
- Keep simulator UDID handy for repeated testing