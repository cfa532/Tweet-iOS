import SwiftUI

@available(iOS 16.0, *)
struct ToastView: View {
    static let retweetingMessage = NSLocalizedString("Retweeting in the background…", comment: "Retweet started toast")
    static let postingTweetMessage = NSLocalizedString("Posting tweet in the background…", comment: "Tweet publication started toast")
    static let postingCommentMessage = NSLocalizedString("Posting comment in the background…", comment: "Comment publication started toast")

    let message: String
    let type: ToastType
    /// When set, the toast shows a close button and stays until the user taps it.
    var onDismiss: (() -> Void)? = nil

    enum ToastType { case success, error, warning, info }

    /// Tells the user a post has been handed to background publication.
    @MainActor
    static func announceBackgroundPost(_ message: String) {
        NotificationCenter.default.post(name: .backgroundPostStarted, object: nil, userInfo: ["message": message])
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(textColor)
                .font(.system(size: 16, weight: .medium))
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textColor)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .padding(4)
                }
                .accessibilityLabel(NSLocalizedString("Dismiss", comment: "Dismiss toast button"))
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(backgroundColor)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var backgroundColor: Color {
        switch type {
        case .success: return Color(.systemGray6).opacity(0.95)
        case .error: return Color(.systemGray6).opacity(0.95)
        case .warning: return Color(.systemGray6).opacity(0.95)
        case .info: return Color(.systemGray6).opacity(0.95)
        }
    }
    
    private var borderColor: Color {
        switch type {
        case .success: return Color(.systemGray4).opacity(0.8)
        case .error: return Color(.systemGray4).opacity(0.8)
        case .warning: return Color(.systemGray4).opacity(0.8)
        case .info: return Color(.systemGray4).opacity(0.8)
        }
    }
    
    private var textColor: Color {
        switch type {
        case .success: return Color(.label)
        case .error: return Color(.label)
        case .warning: return Color(.label)
        case .info: return Color(.label)
        }
    }
    
    private var iconName: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
} 
