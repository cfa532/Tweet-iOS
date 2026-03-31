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

## Planned: Server-Side Push (APNs)

### Architecture
```
Server (Backend) -> APNs (Apple) -> iOS -> App
```

### Setup Requirements
1. Enable Push Notifications capability in Xcode
2. Enable Background Modes > Remote notifications
3. Generate APNs Key (.p8) from Apple Developer Portal
4. Register device tokens with backend on app launch

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
- Payload includes sender name, message content, badge count, chat session ID

### Migration Strategy
1. Implement push alongside local notifications
2. Test with beta users
3. Gradually migrate
4. Keep local notifications as fallback
