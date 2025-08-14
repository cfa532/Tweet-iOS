# Push Notifications for Chat Messages

This document describes the push notification system implemented for incoming chat messages in the Tweet iOS app.

## Overview

The notification system provides:
- **System notifications** when new chat messages arrive while the app is in background
- **App icon badges** showing the number of unread messages
- **Notification tap handling** to open the appropriate chat screen

## Components

### 1. NotificationManager (`Sources/Core/NotificationManager.swift`)
- Handles notification permissions
- Schedules local notifications
- Manages app icon badge counts
- Handles notification tap events

### 2. ChatSessionManager Integration
- Automatically triggers notifications when new messages are detected
- Fetches user details for notification display names
- Only shows notifications when app is in background/inactive

### 3. AppDelegate Integration
- Requests notification permissions on app launch
- Background task scheduling for message checking

## How It Works

### Background Message Checking
1. **Background Task**: AppDelegate registers a background task that runs every 15 minutes
2. **Message Detection**: ChatSessionManager checks for new messages via `checkBackendForNewMessages()`
3. **Notification Triggering**: When new messages are found, `triggerNotificationForMessage()` is called

### Notification Flow
1. **Permission Check**: Verifies user has granted notification permissions
2. **User Details**: Fetches sender's name/username for notification display
3. **Notification Creation**: Creates local notification with message content
4. **Badge Update**: Increments app icon badge count
5. **Scheduling**: Schedules notification for immediate display

### Notification Tap Handling
1. **Tap Detection**: NotificationManager handles notification taps
2. **Navigation**: Posts `openChatFromNotification` notification
3. **Chat Opening**: Main app receives notification and navigates to chat screen
4. **Badge Clearing**: Clears badge count when chat is opened

## Configuration

### Info.plist Requirements
```xml
<key>NSUserNotificationUsageDescription</key>
<string>This app uses notifications to alert you about new chat messages.</string>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.Tweet.messageCheck</string>
</array>
```

### Notification Permissions
The app requests the following permissions:
- **Alerts**: Show notification banners
- **Sounds**: Play notification sounds
- **Badges**: Update app icon badge count

## Usage

### Testing Notifications
```swift
// Test notification (for development)
NotificationManager.shared.testNotification()
```

### Manual Badge Management
```swift
// Clear badge count
NotificationManager.shared.clearBadgeCount()

// Set specific badge count
NotificationManager.shared.updateBadgeCount(5)

// Increment/decrement badge
NotificationManager.shared.incrementBadgeCount()
NotificationManager.shared.decrementBadgeCount()
```

### Notification Cleanup
```swift
// Remove all pending notifications
NotificationManager.shared.removeAllPendingNotifications()

// Remove all delivered notifications
NotificationManager.shared.removeAllDeliveredNotifications()
```

## Background Task Scheduling

The background task is automatically scheduled:
- **Frequency**: Every 15 minutes
- **Identifier**: `com.example.Tweet.messageCheck`
- **Duration**: Limited by iOS background execution time limits
- **Conditions**: Only runs when app is in background

## User Experience

### Notification Display
- **Title**: Sender's name or username
- **Body**: Message content (or "New message" for empty content)
- **Sound**: Default system notification sound
- **Badge**: Incremented for each new message

### Badge Management
- **Increment**: When new message arrives
- **Display**: Shows actual number (1-9) or "N" for 10+ messages
- **Clear**: When chat list or individual chat is opened
- **Reset**: When app is launched from notification tap

### Navigation
- **Chat List**: Clears badge count when opened
- **Individual Chat**: Clears badge count when opened
- **Notification Tap**: Navigates directly to chat screen

## Limitations

1. **Background Execution**: iOS limits background execution time
2. **Notification Frequency**: System may throttle notifications
3. **User Permissions**: Requires user to grant notification permissions
4. **Network Dependency**: User details require network connection

## Troubleshooting

### Notifications Not Appearing
1. Check notification permissions in Settings
2. Verify app is in background when messages arrive
3. Check background task scheduling
4. Review notification settings in iOS Settings

### Badge Count Issues
1. Verify badge permissions are granted
2. Check badge clearing logic in chat screens
3. Review background task execution logs

### Background Task Not Running
1. Check Info.plist configuration
2. Verify background task identifier
3. Review iOS background execution limits
4. Check device battery optimization settings
