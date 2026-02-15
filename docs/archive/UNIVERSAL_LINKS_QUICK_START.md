# Universal Links Quick Start

## Quick Setup Steps

### 1. In Xcode (5 minutes)

1. Open `Tweet.xcworkspace` in Xcode
2. Select the **Tweet** target
3. Go to **Signing & Capabilities** tab
4. Click **+ Capability** → Add **Associated Domains**
5. Add these domains:
   ```
   applinks:fireshare.us
   applinks:tweet.fireshare.us
   applinks:d2.fireshare.us
   ```

### 2. Find Your Team ID

1. Go to https://developer.apple.com/account/
2. Sign in
3. Your Team ID is in the top right (10 characters like `ABC123DEFG`)

### 3. Create Server File

Create a file named `apple-app-site-association` (no extension) with this content:

```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "YOUR_TEAM_ID.com.example.Tweet",
        "paths": ["/tweet/*", "/entry*"]
      },
      {
        "appID": "YOUR_TEAM_ID.com.example.Tweet.debug",
        "paths": ["/tweet/*", "/entry*"]
      }
    ]
  }
}
```

Replace `YOUR_TEAM_ID` with your actual Team ID.

### 4. Host the File

Upload the file to your server at:
- `https://fireshare.us/.well-known/apple-app-site-association`
- `https://tweet.fireshare.us/.well-known/apple-app-site-association`
- `https://d2.fireshare.us/.well-known/apple-app-site-association`

**Requirements:**
- Must be HTTPS
- Content-Type: `application/json`
- No redirects
- Accessible without login

### 5. Test

```bash
# Verify file is accessible
curl https://fireshare.us/.well-known/apple-app-site-association

# Test on device (Universal Links only work on physical devices)
# Open Safari and navigate to: https://fireshare.us/tweet/{tweetId}/{authorId}
```

## Important Notes

- ⚠️ Universal Links **only work on physical devices** (not simulator)
- ⚠️ The file must be served over **HTTPS**
- ⚠️ iOS caches the file for up to 24 hours
- ⚠️ Delete and reinstall the app to clear cache during testing

## Troubleshooting

If it doesn't work:
1. Verify file is accessible: `curl https://yourdomain.com/.well-known/apple-app-site-association`
2. Check Team ID matches your Apple Developer account
3. Verify bundle IDs match exactly
4. Delete and reinstall the app (clears cache)
5. Test on a physical device (not simulator)

For detailed instructions, see `docs/UNIVERSAL_LINKS_SETUP.md`

