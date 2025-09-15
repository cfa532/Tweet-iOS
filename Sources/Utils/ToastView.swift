import SwiftUI

@available(iOS 16.0, *)
struct ToastView: View {
    let message: String
    let type: ToastType
    
    enum ToastType { case success, error, info }
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(textColor)
                .font(.system(size: 16, weight: .medium))
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textColor)
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
        case .info: return Color(.systemGray6).opacity(0.95)
        }
    }
    
    private var borderColor: Color {
        switch type {
        case .success: return Color(.systemGray4).opacity(0.8)
        case .error: return Color(.systemGray4).opacity(0.8)
        case .info: return Color(.systemGray4).opacity(0.8)
        }
    }
    
    private var textColor: Color {
        switch type {
        case .success: return Color(.label)
        case .error: return Color(.label)
        case .info: return Color(.label)
        }
    }
    
    private var iconName: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
} 