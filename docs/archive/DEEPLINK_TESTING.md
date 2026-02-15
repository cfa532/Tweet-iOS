# Deeplink Testing Guide

## Testing Deeplinks in iOS

### Method 1: Using Simulator (Recommended for Development)

#### Step 1: Launch the Simulator
```bash
# Open Xcode and run the app on a simulator, or launch simulator manually
open -a Simulator
```

#### Step 2: Test Custom URL Scheme
```bash
# Test with custom tweet:// scheme
xcrun simctl openurl booted "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
```

#### Step 3: Test HTTP/HTTPS URLs
```bash
# Test with HTTP URL (will open in Safari first, then can open in app)
xcrun simctl openurl booted "http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
```

**Note:** For HTTP/HTTPS URLs to work as Universal Links, you need to:
1. Configure Associated Domains in Xcode capabilities
2. Set up an `apple-app-site-association` file on your server
3. For testing without Universal Links setup, you can use Safari's "Open in App" feature

### Method 2: Using Safari on Simulator/Device

1. **Launch Safari** in the simulator or on your device
2. **Navigate to** the URL: `http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9`
3. If Universal Links are configured, iOS will automatically open the app
4. If not configured, you'll see a banner at the top saying "Open in Tweet" (if the app recognizes the URL pattern)

### Method 3: Testing from Terminal (macOS)

```bash
# Open URL in default browser (will open Safari)
open "http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"

# Or use the custom scheme directly (if app is installed)
open "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
```

### Method 4: Testing on Physical Device

#### Option A: Using Safari
1. Open Safari on your iPhone
2. Type or paste: `http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9`
3. Tap the link - if Universal Links are configured, it will open in the app

#### Option B: Using Notes App
1. Create a new note
2. Type the URL: `http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9`
3. Tap the link to test

#### Option C: Using Messages/Email
1. Send yourself a message/email with the URL
2. Tap the link to test

### Method 5: Testing Custom URL Scheme Directly

For the custom `tweet://` scheme, you can test directly:

```bash
# On simulator
xcrun simctl openurl booted "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"

# On macOS (if app is installed)
open "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
```

### Method 6: Testing Hash Fragment URLs

For URLs with hash fragments (like from detail view sharing):
```bash
xcrun simctl openurl booted "http://125.229.161.122:8080/entry?aid=h5U5jxPr2p2tg2kMr8UeyRMNIJ_&ver=last#/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
```

## Expected Behavior

When a deeplink is successfully processed:
1. The app should open (if not already running) or come to foreground
2. The app should switch to the Home tab
3. The app should navigate to the tweet detail view showing the tweet with ID `y19y5iwAtdbS36IMq6uGnMSH1W6` authored by `mwmQCHCEHClCIJy-bItx5ALAhq9`

## Debugging

### Check Console Logs
Look for these log messages:
- `[AppDelegate] Received deeplink URL: ...`
- `[ContentView] Handling deeplink: ...`
- `[DeeplinkManager] Parsing URL: ...`
- `[DeeplinkManager] Navigating to tweet: ...`

### Common Issues

1. **URL not opening app**: 
   - Check that the URL scheme is registered in Info.plist
   - Verify the app is installed and running
   - For Universal Links, ensure Associated Domains are configured

2. **Navigation not working**:
   - Check console logs for parsing errors
   - Verify the tweet ID and author ID are correct
   - Ensure the app has finished initializing before navigation

3. **Tweet not found**:
   - Check network connectivity
   - Verify the tweet exists on the server
   - Check that the author ID is correct

## Testing Checklist

- [ ] Custom URL scheme (`tweet://`) works
- [ ] HTTP URL format (`http://domain.com/tweet/{id}/{authorId}`) works
- [ ] Hash fragment URL format works
- [ ] App opens from background when URL is tapped
- [ ] App navigates to correct tweet
- [ ] App handles invalid/missing tweets gracefully
- [ ] App waits for initialization before navigating
- [ ] Navigation works when app is already running
- [ ] Navigation works when app is launched from URL

