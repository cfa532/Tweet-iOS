# Push Notifications

**Status:** Local notifications in production; server-side push planned

---

## Current System (Local Notifications)

### Components
- **NotificationManager** (`Sources/Core/NotificationManager.swift`) - permissions, scheduling, badge management, tap handling
- **ChatSessionManager** - triggers notifications on new messages, fetches sender details
- **AppDelegate** - requests permissions on launch, background task scheduling

### Flow
1. Background task runs every 15 minutes (`com.example.Tweet.messageCheck`)
2. `ChatSessionManager.checkBackendForNewMessages()` detects new messages
3. Local notification created with sender name and message content
4. Badge count incremented
5. Notification tap navigates to chat screen via `openChatFromNotification` notification

### Badge Management
```swift
NotificationManager.shared.clearBadgeCount()
NotificationManager.shared.updateBadgeCount(5)
NotificationManager.shared.incrementBadgeCount()
```

### Limitations
- Requires app to poll server (background execution limited by iOS)
- May be delayed or skipped
- Does not work when app is completely closed

---

## Planned: APNs Push Gateway for IPFS Backend

Tweet's backend may run on user/provider IPFS nodes that are not controlled by
the app developer. Those nodes must not receive the Apple APNs private key.
APNs delivery should go through a small developer-controlled push gateway.

### Architecture
```
IPFS / provider node / sender app
        -> Developer-controlled push gateway
        -> APNs
        -> iOS
        -> Tweet app
```

The gateway is only a notification bridge. It should not become the source of
truth for messages or media. Message payloads remain in the existing IPFS/backend
network and are fetched/decrypted by the app after wake or notification tap.

### Setup Requirements
1. Enable Push Notifications capability in Xcode
2. Enable Background Modes > Remote notifications
3. Generate APNs Key (.p8) from Apple Developer Portal
4. Register device tokens with backend on app launch
5. Operate a trusted push gateway that holds the APNs key

### Push Gateway Responsibilities
- Store device tokens per user and app environment
- Accept signed "recipient has new event" requests from app/backend nodes
- Verify request signatures or scoped notify tokens
- Rate-limit and deduplicate event IDs
- Send APNs requests using the developer-owned APNs key
- Avoid storing message bodies unless a future product decision requires it

### IPFS-Friendly Event Shape
Use a minimal trigger payload from backend nodes to the gateway:

```json
{
  "recipientUserId": "user-mid",
  "eventId": "stable-message-or-session-event-id",
  "eventType": "chat_message",
  "encryptedCid": "optional-ipfs-cid-or-message-pointer",
  "createdAt": "2026-06-26T15:00:00Z",
  "signature": "sender-or-provider-signature"
}
```

The gateway validates this request and sends a generic APNs payload. Private
message content should not be exposed to the gateway unless it is already safe
for Apple notification transport and lock-screen display.

### iOS Implementation

```swift
// AppDelegate - register for remote notifications
application.registerForRemoteNotifications()

// Handle device token
func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    Task { await sendDeviceTokenToServer(token) }
}
```

### Server-Side
- Store device tokens per user (support multiple devices)
- Send push via APNs HTTP/2 API with JWT authentication
- Prefer generic payloads such as "New message"
- Include only routing metadata needed to open/fetch the right conversation
- Use `content-available: 1` only as a best-effort background wake hint
- Use visible alert pushes for reliable user-visible notifications

### APNs Payload Guidance

Recommended visible alert:

```json
{
  "aps": {
    "alert": {
      "title": "New message",
      "body": "Open Tweet to view it."
    },
    "badge": 1,
    "sound": "default"
  },
  "eventId": "stable-message-or-session-event-id",
  "eventType": "chat_message"
}
```

Recommended silent wake-up, best effort only:

```json
{
  "aps": {
    "content-available": 1
  },
  "eventId": "stable-message-or-session-event-id",
  "eventType": "chat_message"
}
```

iOS may delay or skip silent pushes. They should improve freshness but must not
be the only path for message delivery.

### Apple Requirements and References
- Register the app with APNs and collect device tokens
- Send APNs requests from a trusted provider server using token-based auth
- Use the correct bundle topic and production/sandbox environment
- Handle token rotation and invalid-token responses

References:
- https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns
- https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server
- https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
- https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app

### Migration Strategy
1. Implement push alongside local notifications
2. Test with beta users
3. Gradually migrate
4. Keep local notifications as fallback
