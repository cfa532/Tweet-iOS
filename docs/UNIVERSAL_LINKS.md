# Universal Links Setup

**Status:** Production

Universal Links allow HTTP/HTTPS URLs to open directly in the app without going through Safari.

---

## Prerequisites

- **Bundle IDs:** `com.example.Tweet` (Release), `com.example.Tweet.debug` (Debug)
- **Domains:** `tweet.fireshare.us` / `fireshare.us` (Release), `d2.fireshare.us` (Debug)

---

## Setup

### 1. Xcode Configuration

1. Open `Tweet.xcworkspace`
2. Select **Tweet** target > **Signing & Capabilities**
3. Add **Associated Domains** capability
4. Add domains:
   ```
   applinks:fireshare.us
   applinks:tweet.fireshare.us
   applinks:d2.fireshare.us
   ```

### 2. Find Your Team ID

Go to https://developer.apple.com/account/ — Team ID is in the top right (10 characters like `ABC123DEFG`).

### 3. Create Server File

Create `apple-app-site-association` (no extension):

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

### 4. Host the File

Upload to each domain at `/.well-known/apple-app-site-association`

**Requirements:** HTTPS, Content-Type `application/json`, no redirects, no authentication.

#### Server Configuration Examples

**Nginx:**
```nginx
location /.well-known/apple-app-site-association {
    default_type application/json;
}
```

**Express.js:**
```javascript
app.get('/.well-known/apple-app-site-association', (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.sendFile('apple-app-site-association');
});
```

---

## Testing

```bash
# Verify file is accessible
curl https://fireshare.us/.well-known/apple-app-site-association

# Test on device (simulator doesn't support Universal Links)
# Open Safari: https://fireshare.us/tweet/{tweetId}/{authorId}
```

---

## Troubleshooting

- Universal Links **only work on physical devices** (not simulator)
- iOS caches the association file for up to 24 hours — delete and reinstall app to clear
- Verify Team ID and Bundle ID match exactly (case-sensitive)
- File must be served directly — no 301/302 redirects
- Use [Apple's validator](https://search.developer.apple.com/appsearch-validation-tool/) to check file format
