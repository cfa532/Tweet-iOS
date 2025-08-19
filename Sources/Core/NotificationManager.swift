import UIKit
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()
    
    // Private property to track badge count since UNUserNotificationCenter doesn't provide a way to read it
    private var currentBadgeCount: Int = 0
    
    private override init() {
        super.init()
    }
    
    // MARK: - Notification Permission
    
    func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            print("[NotificationManager] Notification permission granted: \(granted)")
            return granted
        } catch {
            print("[NotificationManager] Error requesting notification permission: \(error)")
            return false
        }
    }
    
    func checkNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }
    
    // MARK: - Local Notifications
    
    func scheduleChatNotification(for message: ChatMessage, senderName: String) {
        let center = UNUserNotificationCenter.current()
        
        // Increment badge count for new notification
        let newBadgeCount = getCurrentBadgeCount() + 1
        
        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = message.content ?? "New message"
        content.sound = .default
        content.badge = NSNumber(value: newBadgeCount)
        
        // Add custom data for handling notification tap
        content.userInfo = [
            "messageId": message.id,
            "senderId": message.authorId,
            "chatSessionId": message.chatSessionId,
            "type": "chat_message"
        ]
        
        // Create notification trigger (immediate)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        
        // Create notification request
        let request = UNNotificationRequest(
            identifier: "chat_message_\(message.id)",
            content: content,
            trigger: trigger
        )
        
        // Schedule the notification
        center.add(request) { error in
            if let error = error {
                print("[NotificationManager] Error scheduling notification: \(error)")
            } else {
                // Update internal badge count after successful scheduling
                self.updateBadgeCount(newBadgeCount)
                print("[NotificationManager] Chat notification scheduled for message: \(message.id)")
            }
        }
    }
    
    // MARK: - Badge Management
    
    func updateBadgeCount(_ count: Int) {
        DispatchQueue.main.async {
            // Update internal counter
            self.currentBadgeCount = count
            
            // If count is more than 9, set to -1 to show "N" (iOS default behavior)
            let badgeNumber = count > 9 ? -1 : count
            UNUserNotificationCenter.current().setBadgeCount(badgeNumber) { error in
                if let error = error {
                    print("[NotificationManager] Error setting badge count: \(error)")
                } else {
                    print("[NotificationManager] Updated app badge count to: \(count > 9 ? "N" : "\(count)")")
                }
            }
        }
    }
    
    func incrementBadgeCount() {
        let currentCount = getCurrentBadgeCount()
        updateBadgeCount(currentCount + 1)
    }
    
    func decrementBadgeCount() {
        let currentCount = getCurrentBadgeCount()
        updateBadgeCount(max(0, currentCount - 1))
    }
    
    func clearBadgeCount() {
        updateBadgeCount(0)
    }
    
    private func getCurrentBadgeCount() -> Int {
        return currentBadgeCount
    }
    
    // MARK: - Notification Actions
    
    func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String, type == "chat_message" else {
            return
        }
        
        // Post notification to open chat screen
        NotificationCenter.default.post(
            name: .openChatFromNotification,
            object: nil,
            userInfo: userInfo
        )
        
        // Clear badge count when notification is tapped
        clearBadgeCount()
    }
    
    // MARK: - Utility Methods
    
    func removeAllPendingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        print("[NotificationManager] Removed all pending notifications")
    }
    
    func removeAllDeliveredNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        print("[NotificationManager] Removed all delivered notifications")
    }
    
    // MARK: - Testing
    
    func testNotification() {
        let testMessage = ChatMessage(
            authorId: "test_user",
            receiptId: "current_user",
            chatSessionId: "test_session",
            content: "This is a test notification message",
            timestamp: Date().timeIntervalSince1970
        )
        
        scheduleChatNotification(for: testMessage, senderName: "Test User")
        print("[NotificationManager] Test notification scheduled")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification tap
        handleNotificationTap(response.notification.request.content.userInfo)
        completionHandler()
    }
}
