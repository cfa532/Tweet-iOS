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

### For Real iOS Device (Release Mode)

```bash
cd /Users/cfa532/Documents/GitHub/Tweet-iOS

# Get device UDID
xcrun devicectl list devices

# Build Release version for device
xcodebuild -workspace Tweet.xcworkspace \
  -scheme Tweet \
  -configuration Release \
  -sdk iphoneos \
  -destination 'platform=iOS,id=DEVICE_UDID' \
  -derivedDataPath ./DerivedData \
  build

# Install on device
xcrun devicectl device install app \
  --device DEVICE_UDID \
  ./DerivedData/Build/Products/Release-iphoneos/Tweet.app
```

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
```bash
xcrun devicectl list devices
# Or
system_profiler SPUSBDataType | grep -A 10 "iPhone" | grep "Serial Number"
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

### No logs appear from real device

1. Ensure `libimobiledevice` is installed: `brew install libimobiledevice`
2. Check device is connected: `xcrun devicectl list devices`
3. Unlock the device
4. Trust the computer (Settings → General → Device Management)

### Build fails

- Clean derived data: `rm -rf ./DerivedData`
- Clean build: Add `clean` before `build` in xcodebuild command

### App won't install

- Check bundle identifier matches
- Ensure device is unlocked
- Check code signing in Xcode project settings
