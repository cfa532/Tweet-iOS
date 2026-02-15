# Push Notifications Implementation Guide

## Overview

This guide explains how to implement **server-side push notifications** for the Tweet iOS app, replacing the current local notification system with a more reliable push notification system.

## Current System vs Push Notifications

### Current System (Local Notifications)
- ✅ Works when app is in background
- ❌ Requires app to poll server for new messages
- ❌ Limited by iOS background execution time
- ❌ May be delayed or skipped by iOS
- ❌ Doesn't work when app is completely closed

### Push Notifications
- ✅ Works even when app is completely closed
- ✅ Instant delivery (no polling needed)
- ✅ More reliable
- ✅ Better battery efficiency
- ✅ No background task limits

## Architecture

```
┌─────────────┐      ┌──────────┐      ┌─────┐      ┌──────────┐
│   Server    │─────▶│   APNs   │─────▶│ iOS │─────▶│   App    │
│ (Backend)   │      │ (Apple)  │      │     │      │          │
└─────────────┘      └──────────┘      └─────┘      └──────────┘
     │                    │
     │                    │
     └────────────────────┘
   Device Token Storage
```

## Implementation Steps

### 1. Apple Developer Setup

#### Enable Push Notifications Capability
1. Open Xcode project
2. Select your app target
3. Go to "Signing & Capabilities"
4. Click "+ Capability"
5. Add "Push Notifications"
6. Add "Background Modes" → Enable "Remote notifications"

#### Generate APNs Key/Certificate
**Option A: APNs Key (Recommended - Easier)**
1. Go to [Apple Developer Portal](https://developer.apple.com/account/)
2. Navigate to "Certificates, Identifiers & Profiles"
3. Go to "Keys" → Click "+" to create new key
4. Enable "Apple Push Notifications service (APNs)"
5. Download the `.p8` key file
6. Note the Key ID and Team ID

**Option B: APNs Certificate (More complex)**
1. Create Certificate Signing Request (CSR) in Keychain
2. Upload CSR to Apple Developer Portal
3. Download `.cer` file
4. Convert to `.p12` format

### 2. iOS App Implementation

#### Step 1: Register for Remote Notifications

Add to `AppDelegate.swift`:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    // ... existing code ...
    
    // Register for remote notifications
    application.registerForRemoteNotifications()
    
    return true
}
```

#### Step 2: Handle Device Token Registration

```swift
// Successfully registered for push notifications
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
    let token = tokenParts.joined()
    print("[AppDelegate] 📱 Device token: \(token)")
    
    // Send device token to your server
    Task {
        await sendDeviceTokenToServer(token)
    }
}

// Failed to register for push notifications
func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    print("[AppDelegate] ❌ Failed to register for remote notifications: \(error)")
}
```

#### Step 3: Send Device Token to Server

```swift
private func sendDeviceTokenToServer(_ token: String) async {
    let hproseInstance = HproseInstance.shared
    let userId = hproseInstance.appUser.mid
    
    guard userId != Constants.GUEST_ID else {
        print("[AppDelegate] Skipping device token registration for guest user")
        return
    }
    
    do {
        // Call your backend API to register device token
        // Example: await hproseInstance.registerDeviceToken(userId: userId, token: token)
        print("[AppDelegate] ✅ Device token sent to server")
    } catch {
        print("[AppDelegate] ❌ Error sending device token: \(error)")
    }
}
```

#### Step 4: Handle Incoming Push Notifications

```swift
// Handle push notification when app is in foreground
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
) {
    // Show notification even when app is in foreground
    completionHandler([.banner, .sound, .badge])
}

// Handle push notification tap
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    let userInfo = response.notification.request.content.userInfo
    
    // Handle notification tap (same as local notifications)
    if let type = userInfo["type"] as? String, type == "chat_message" {
        NotificationManager.shared.handleNotificationTap(userInfo)
    }
    
    completionHandler()
}

// Handle silent push notification (when app is in background/closed)
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    print("[AppDelegate] 📬 Received remote notification: \(userInfo)")
    
    // Process notification and update app state
    Task {
        // Refresh messages from server
        await ChatSessionManager.shared.checkBackendForNewMessages()
        completionHandler(.newData)
    }
}
```

### 3. Server-Side Implementation

#### Step 1: Store Device Tokens

Your server needs to:
1. Store device tokens per user
2. Handle multiple devices per user
3. Remove tokens when user logs out or uninstalls app

**Database Schema Example:**
```sql
CREATE TABLE device_tokens (
    user_id VARCHAR(255),
    device_token VARCHAR(255),
    platform VARCHAR(10), -- 'ios' or 'android'
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    PRIMARY KEY (user_id, device_token)
);
```

#### Step 2: Send Push Notification to APNs

**Using APNs Key (.p8) - Recommended:**

```python
import jwt
import requests
from datetime import datetime, timedelta

def send_push_notification(device_token, message, badge_count):
    # APNs Configuration
    TEAM_ID = "YOUR_TEAM_ID"
    KEY_ID = "YOUR_KEY_ID"
    BUNDLE_ID = "com.yourcompany.Tweet"
    APNS_KEY_PATH = "path/to/AuthKey_KEYID.p8"
    
    # Generate JWT token
    with open(APNS_KEY_PATH, 'r') as f:
        secret = f.read()
    
    headers = {
        'alg': 'ES256',
        'kid': KEY_ID
    }
    
    payload = {
        'iss': TEAM_ID,
        'iat': datetime.utcnow()
    }
    
    token = jwt.encode(payload, secret, algorithm='ES256', headers=headers)
    
    # APNs URL (use production or sandbox)
    apns_url = f"https://api.push.apple.com/3/device/{device_token}"
    
    # Notification payload
    notification = {
        "aps": {
            "alert": {
                "title": message.get("sender_name", "New Message"),
                "body": message.get("content", "You have a new message")
            },
            "badge": badge_count,
            "sound": "default",
            "thread-id": message.get("chat_session_id", "")
        },
        "messageId": message.get("id"),
        "senderId": message.get("sender_id"),
        "chatSessionId": message.get("chat_session_id"),
        "type": "chat_message"
    }
    
    # Send to APNs
    headers = {
        'authorization': f'bearer {token}',
        'apns-topic': BUNDLE_ID,
        'apns-push-type': 'alert',
        'apns-priority': '10'
    }
    
    response = requests.post(apns_url, json=notification, headers=headers)
    return response.status_code == 200
```

**Using APNs Certificate (.p12):**

```python
from apns2.client import APNsClient
from apns2.payload import Payload

def send_push_notification_cert(device_token, message, badge_count):
    # Load certificate
    client = APNsClient(
        'path/to/certificate.p12',
        use_sandbox=False,  # True for development
        use_alternative_port=False
    )
    
    # Create payload
    payload = Payload(
        alert={
            "title": message.get("sender_name", "New Message"),
            "body": message.get("content", "You have a new message")
        },
        badge=badge_count,
        sound="default",
        thread_id=message.get("chat_session_id", "")
    )
    
    # Send notification
    client.send_notification(device_token, payload, topic="com.yourcompany.Tweet")
```

#### Step 3: Trigger Notification on New Message

When a new chat message arrives on your server:

```python
def on_new_chat_message(message):
    # Get recipient user ID
    recipient_id = message['receipt_id']
    
    # Get all device tokens for this user
    device_tokens = get_device_tokens_for_user(recipient_id)
    
    # Get unread message count
    badge_count = get_unread_message_count(recipient_id)
    
    # Send push notification to all user's devices
    for token in device_tokens:
        send_push_notification(
            device_token=token,
            message={
                "id": message['id'],
                "sender_id": message['author_id'],
                "sender_name": get_user_name(message['author_id']),
                "content": message['content'],
                "chat_session_id": message['chat_session_id']
            },
            badge_count=badge_count
        )
```

## Testing

### Development (Sandbox)
- Use sandbox APNs URL: `https://api.sandbox.push.apple.com`
- Use development device tokens
- Test with development provisioning profile

### Production
- Use production APNs URL: `https://api.push.apple.com`
- Use production device tokens
- Requires App Store distribution

### Test Notification
```bash
# Using curl (requires JWT token)
curl -v \
  -H "authorization: bearer $JWT_TOKEN" \
  -H "apns-topic: com.yourcompany.Tweet" \
  -H "apns-push-type: alert" \
  -H "apns-priority: 10" \
  -d '{"aps":{"alert":"Test notification","badge":1,"sound":"default"}}' \
  https://api.sandbox.push.apple.com/3/device/$DEVICE_TOKEN
```

## Advantages

1. **Instant Delivery**: Notifications arrive immediately when messages are sent
2. **Works When Closed**: App doesn't need to be running
3. **Battery Efficient**: No polling required
4. **Reliable**: APNs handles delivery retries
5. **Scalable**: Server can send to millions of devices

## Disadvantages

1. **Server Required**: Need backend infrastructure
2. **APNs Dependency**: Relies on Apple's service
3. **Setup Complexity**: More complex than local notifications
4. **Cost**: May require server resources

## Migration Strategy

1. **Phase 1**: Implement push notifications alongside local notifications
2. **Phase 2**: Test with beta users
3. **Phase 3**: Gradually migrate users to push notifications
4. **Phase 4**: Keep local notifications as fallback

## Troubleshooting

### Notifications Not Arriving
1. Check device token is registered on server
2. Verify APNs certificate/key is valid
3. Check notification payload format
4. Verify bundle ID matches
5. Check APNs connection (sandbox vs production)

### Device Token Issues
1. Token changes when app is reinstalled
2. Token changes when device is restored
3. Token may be invalidated by Apple
4. Always re-register token on app launch

## Resources

- [Apple Push Notification Service Documentation](https://developer.apple.com/documentation/usernotifications)
- [APNs Provider API](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server)
- [APNs HTTP/2 API](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/sending_notification_requests_to_apns)

