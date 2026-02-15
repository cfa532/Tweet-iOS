# Universal Links Setup Guide

Universal Links allow HTTP/HTTPS URLs to open directly in your iOS app without going through Safari first.

## Prerequisites

- Your app's bundle identifiers:
  - **Debug**: `com.example.Tweet.debug`
  - **Release**: `com.example.Tweet`
- Your domains:
  - **Debug**: `d2.fireshare.us`
  - **Release**: `tweet.fireshare.us` (or `fireshare.us`)

## Step 1: Configure Xcode Project

### 1.1 Add Associated Domains Capability

1. Open your project in Xcode
2. Select your **Tweet** target
3. Go to **Signing & Capabilities** tab
4. Click **+ Capability**
5. Add **Associated Domains**
6. Add your domains with `applinks:` prefix:

**For Debug:**
```
applinks:d2.fireshare.us
```

**For Release:**
```
applinks:tweet.fireshare.us
applinks:fireshare.us
```

**Note:** You can add multiple domains. The format is `applinks:yourdomain.com`

### 1.2 Verify Info.plist (Automatic)

Xcode will automatically add the `com.apple.developer.associated-domains` entitlement. You can verify it's added correctly.

## Step 2: Create apple-app-site-association File

You need to create an `apple-app-site-association` file (no file extension) and host it on your server.

### 2.1 File Format

Create a JSON file named `apple-app-site-association` (no extension) with this content:

```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "TEAM_ID.com.example.Tweet",
        "paths": [
          "/tweet/*",
          "/entry*"
        ]
      },
      {
        "appID": "TEAM_ID.com.example.Tweet.debug",
        "paths": [
          "/tweet/*",
          "/entry*"
        ]
      }
    ]
  }
}
```

**Important:**
- Replace `TEAM_ID` with your Apple Developer Team ID (found in Apple Developer account)
- The `paths` array specifies which URL paths should open in the app
- Use `*` for wildcard matching
- The `apps` array should be empty (legacy field)

### 2.2 File Location

The file must be accessible at:
- `https://yourdomain.com/.well-known/apple-app-site-association`
- OR `https://yourdomain.com/apple-app-site-association`

**Recommended location:** `/.well-known/apple-app-site-association`

### 2.3 Server Requirements

1. **HTTPS Required**: Universal Links only work with HTTPS (except for localhost testing)
2. **Content-Type**: Should be `application/json` or `text/plain`
3. **No Redirects**: The file must be served directly (no 301/302 redirects)
4. **Accessible**: Must be accessible without authentication

### 2.4 Example Server Configuration

#### Nginx
```nginx
location /.well-known/apple-app-site-association {
    default_type application/json;
    add_header Content-Type application/json;
    return 200 '{
      "applinks": {
        "apps": [],
        "details": [
          {
            "appID": "TEAM_ID.com.example.Tweet",
            "paths": ["/tweet/*", "/entry*"]
          }
        ]
      }
    }';
}
```

#### Apache (.htaccess)
```apache
<Files "apple-app-site-association">
    Header set Content-Type "application/json"
</Files>
```

#### Express.js (Node.js)
```javascript
app.get('/.well-known/apple-app-site-association', (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.send({
    applinks: {
      apps: [],
      details: [{
        appID: 'TEAM_ID.com.example.Tweet',
        paths: ['/tweet/*', '/entry*']
      }]
    }
  });
});
```

## Step 3: Find Your Team ID

1. Go to [Apple Developer Portal](https://developer.apple.com/account/)
2. Sign in with your Apple ID
3. Your Team ID is displayed in the top right corner (10 characters, like `ABC123DEFG`)

## Step 4: Testing

### 4.1 Verify File is Accessible

Test that your file is accessible:
```bash
curl https://fireshare.us/.well-known/apple-app-site-association
curl https://d2.fireshare.us/.well-known/apple-app-site-association
```

### 4.2 Test on Device

1. **Install the app** on a physical device (Universal Links don't work in simulator)
2. **Long press** a link in Notes, Messages, or Safari
3. You should see "Open in Tweet" option
4. **Tap the link** - it should open directly in the app

### 4.3 Debug Universal Links

If Universal Links aren't working:

1. **Check file format**: Use [Apple's validator](https://search.developer.apple.com/appsearch-validation-tool/)
2. **Verify HTTPS**: The file must be served over HTTPS
3. **Check paths**: Make sure the URL paths match your `paths` array
4. **Clear cache**: iOS caches the association file. To force refresh:
   - Delete and reinstall the app
   - Or wait 24 hours for cache to expire

### 4.4 Test Commands

```bash
# Test Universal Link
xcrun simctl openurl booted "https://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"

# Verify association file
curl -I https://fireshare.us/.well-known/apple-app-site-association
```

## Step 5: Handle Multiple Domains

If you have multiple domains (like `fireshare.us` and `tweet.fireshare.us`):

1. Add all domains to Associated Domains in Xcode
2. Host the `apple-app-site-association` file on each domain
3. Or use a single file with multiple app IDs if using different bundle IDs

## Troubleshooting

### Universal Links Not Working?

1. **File not found**: Check the file is accessible via HTTPS
2. **Wrong Team ID**: Verify your Team ID matches your Apple Developer account
3. **Wrong Bundle ID**: Ensure bundle ID matches exactly (case-sensitive)
4. **Paths don't match**: Check that your URL paths match the `paths` array
5. **Cache issue**: Delete and reinstall the app
6. **Not on device**: Universal Links require a physical device (not simulator)

### Common Errors

- **"No apps available"**: The association file isn't found or has errors
- **Opens in Safari**: The file format is incorrect or paths don't match
- **"Open in App" banner**: Universal Links aren't configured, but custom scheme works

## Additional Resources

- [Apple Documentation: Universal Links](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app)
- [Apple Validation Tool](https://search.developer.apple.com/appsearch-validation-tool/)
- [Testing Universal Links](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app#test-universal-links)

## Notes

- Universal Links work on **physical devices only** (not simulator)
- The association file is cached by iOS for up to 24 hours
- HTTPS is required (except for localhost testing)
- The file must be served directly (no redirects)
- Path matching is case-sensitive

