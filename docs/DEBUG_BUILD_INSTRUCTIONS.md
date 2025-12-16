# Debug Build Instructions

**Date**: October 17, 2025  
**Purpose**: Guide for building and capturing logs from iOS Simulator and Real Devices

---

## 🚀 Quick Reference: Accessing Logs

### Real Device (Most Common)
```bash
# Install tool first (one time only)
brew install libimobiledevice

# Get device UDID
xcrun devicectl list devices

# Stream logs
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "tweet"

# Filter for specific components
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "tweet" | grep -iE "DEBUG|ERROR|localhttpserver"
```

### Simulator
```bash
# Get simulator UDID
xcrun simctl list devices | grep Booted

# Stream logs
xcrun simctl spawn SIMULATOR_UDID log stream --predicate 'process == "Tweet"' --level debug
```

**See full details below in "Accessing Logs" section.**

---

## Building the App

### For iOS Simulator (Debug Mode)

```bash
cd /Users/cfa532/Documents/GitHub/Tweet-iOS

# Build Debug version for simulator
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath ./DerivedData \
  build

# Install on simulator
xcrun simctl install SIMULATOR_UDID ./DerivedData/Build/Products/Debug-iphonesimulator/Tweet.app
```

### For Real iOS Device (Debug Mode)

```bash
cd /Users/cfa532/Documents/GitHub/Tweet-iOS

# Method 1: Get device UDID using system_profiler (most reliable)
system_profiler SPUSBDataType 2>&1 | grep -A 10 "iPhone\|iPad" | grep "Serial Number"
# Output example: Serial Number: 00008110001230222230401E

# Method 2: Try xcrun devicectl (may timeout on some systems)
xcrun devicectl list devices

# Build Debug version and install to the device directly (workspace pulls in Pods)
# Note: Use the UDID with dashes: 00008110-001230222230401E
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Debug \
  -destination "platform=iOS,arch=arm64,id=DEVICE_UDID" \
  -allowProvisioningUpdates \
  build install
```

**Notes**
- Replace `DEVICE_UDID` with the identifier from `system_profiler` command above, inserting dashes after the 8th character (e.g. `00008110-001230222230401E`).
- Use the full destination format including `platform=iOS,arch=arm64` for better compatibility.
- `-allowProvisioningUpdates` lets Xcode refresh signing assets automatically. Drop it if signing is already set up locally.
- The command uses `Tweet.xcworkspace` so CocoaPods frameworks (e.g. ffmpegkit) resolve correctly.
- If `xcrun devicectl` times out, use `system_profiler` method instead.

### For Real iOS Device (Release Mode)

```bash
cd /Users/cfa532/Documents/GitHub/Tweet-iOS

# Get device UDID using system_profiler (most reliable)
system_profiler SPUSBDataType 2>&1 | grep -A 10 "iPhone\|iPad" | grep "Serial Number"
# Output example: Serial Number: 00008110001230222230401E

# Build Release version and install in one command (recommended)
# Note: Use the UDID with dashes: 00008110-001230222230401E
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Release \
  -destination "platform=iOS,arch=arm64,id=DEVICE_UDID" \
  -allowProvisioningUpdates \
  build install
```

**Alternative: Build then Install Separately**

If you prefer to build and install as separate steps:

```bash
# Build only
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Release \
  -sdk iphoneos \
  -destination "platform=iOS,arch=arm64,id=DEVICE_UDID" \
  -derivedDataPath ./DerivedData \
  -allowProvisioningUpdates \
  build

# Install (if xcrun devicectl works on your system)
xcrun devicectl device install app \
  --device DEVICE_UDID \
  ./DerivedData/Build/Products/Release-iphoneos/Tweet.app
```

**Notes**
- The single-command approach (`build install`) is more reliable and handles code signing automatically.
- Replace `DEVICE_UDID` with your device identifier including dashes (e.g. `00008110-001230222230401E`).
- The full destination format `platform=iOS,arch=arm64,id=DEVICE_UDID` ensures proper device targeting.
- `-allowProvisioningUpdates` handles automatic code signing and provisioning profile management.

## Capturing Logs

### From iOS Simulator

#### Method 1: Launch with Console Output

```bash
# Launch and see logs immediately
xcrun simctl launch --console SIMULATOR_UDID com.example.Tweet
```

#### Method 2: Log Stream

```bash
# Start log stream
log stream --predicate 'processImagePath contains "Tweet"' --level debug &

# Launch app
xcrun simctl launch SIMULATOR_UDID com.example.Tweet
```

### From Real iOS Device

#### Using idevicesyslog (Recommended)

**Install libimobiledevice first:**
```bash
brew install libimobiledevice
```

**Stream logs from device:**
```bash
# Get device UDID
system_profiler SPUSBDataType 2>&1 | grep -A 10 "iPhone\|iPad" | grep "Serial Number"
# Or
xcrun devicectl list devices

# Stream all logs
idevicesyslog -u DEVICE_UDID

# Stream filtered logs
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "tweet"

# Stream specific components
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "tweet" | grep -iE "localhttpserver|appdelegate|background"

# Debug share functionality
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "SHARE\|tweet"

# Save to file
idevicesyslog -u DEVICE_UDID 2>&1 | grep -i "tweet" | tee ~/Desktop/tweet_logs.txt
```

**Example: Capture background/foreground cycle:**
```bash
# Start logging
idevicesyslog -u 00008110-001230222230401E 2>&1 | grep -i "tweet" | grep -iE "background|foreground|server|port" &

# Perform your test (background app, wait, return)

# Stop logging
killall idevicesyslog
```

**Example: Debug share feature:**
```bash
# Start logging share functionality
idevicesyslog -u 00008110-001230222230401E 2>&1 | grep -i "SHARE\|tweet" &

# Tap share button on a tweet with attachments in the app

# Stop logging
killall idevicesyslog
```

## Important Notes

### NSLog vs print

- **NSLog**: Always appears in device/simulator logs (both Debug and Release)
- **print**: May be stripped in Release builds, use NSLog for critical debugging

### Release Mode Logging

Release builds **DO** include `NSLog` statements. You will see:
```
Tweet(Foundation)[PID] <Notice>: [LocalHTTPServer] Server started
Tweet[PID] <Debug>: [AppDelegate] App entering foreground
```

### Simulator vs Real Device

- **Simulator**: Faster, easier to reset, but may not show real device issues
- **Real Device**: Required for testing background behavior, network, and Release-mode race conditions

## Quick Reference

### Get Simulator UDID
```bash
xcrun simctl list devices | grep "iPhone"
```

### Get Real Device UDID

**Recommended Method (most reliable):**
```bash
system_profiler SPUSBDataType 2>&1 | grep -A 10 "iPhone\|iPad" | grep "Serial Number"
# Output: Serial Number: 00008110001230222230401E
# Add dashes after 8th character: 00008110-001230222230401E
```

**Alternative (may timeout):**
```bash
xcrun devicectl list devices
```

### Launch App
```bash
# Simulator
xcrun simctl launch SIMULATOR_UDID com.example.Tweet

# Real Device (must be unlocked)
xcrun devicectl device process launch --device DEVICE_UDID com.example.Tweet
```

### Simulate Background (Simulator Only)
```bash
xcrun simctl device SIMULATOR_UDID press home
```

### Stop All Simulators
```bash
xcrun simctl shutdown all
```

## Troubleshooting

### xcrun devicectl times out or fails

**Problem:** `ERROR: Timed out waiting for CoreDeviceService to fully initialize`

**Solution:** Use `system_profiler` instead:
```bash
system_profiler SPUSBDataType 2>&1 | grep -A 10 "iPhone\|iPad" | grep "Serial Number"
```
This method is more reliable and doesn't depend on CoreDeviceService.

### Device UDID format issues

**Problem:** `Unable to find a device matching the provided destination specifier`

**Solution:** Ensure UDID has dashes in the correct position:
- ❌ Wrong: `00008110001230222230401E` (no dashes)
- ✅ Correct: `00008110-001230222230401E` (dash after 8th character)

Also use the full destination format:
```bash
-destination "platform=iOS,arch=arm64,id=00008110-001230222230401E"
```

### No logs appear from real device

1. Ensure `libimobiledevice` is installed: `brew install libimobiledevice`
2. Check device is connected: `system_profiler SPUSBDataType | grep -A 10 "iPhone"`
3. Unlock the device
4. Trust the computer (Settings → General → Device Management)

### Build fails

- Clean derived data: `rm -rf ./DerivedData`
- Clean build: Add `clean` before `build` in xcodebuild command
- If compilation errors occur, check for syntax errors in recent code changes

### App won't install

- Check bundle identifier matches
- Ensure device is unlocked
- Check code signing in Xcode project settings
- Try using `build install` in a single command instead of separate steps
- Verify `-allowProvisioningUpdates` flag is included for automatic code signing
