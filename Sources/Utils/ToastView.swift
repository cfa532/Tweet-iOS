import SwiftUI

@available(iOS 16.0, *)
struct ToastView: View {
    let message: String
    let type: ToastType
    
    enum ToastType { case success, error, info }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(textColor)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        case .error: return Color.red.opacity(0.9)
        case .info: return Color.blue.opacity(0.9)
        }
    }
    
    private var borderColor: Color {
        switch type {
        case .success: return Color(.systemGray4).opacity(0.8)
        case .error: return Color.red.opacity(0.7)
        case .info: return Color.blue.opacity(0.7)
        }
    }
    
    private var textColor: Color {
        switch type {
        case .success: return Color(.label)
        case .error: return .white
        case .info: return .white
        }
    }
    
    private var iconName: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "arrow.2.squarepath"
        }
    }
} 