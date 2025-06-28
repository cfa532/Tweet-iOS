import SwiftUI

@available(iOS 16.0, *)
struct ToastView: View {
    let message: String
    let type: ToastType
    
    enum ToastType { case success, error, info }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(.white)
                .font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(backgroundColor)
        .cornerRadius(22)
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var backgroundColor: Color {
        switch type {
        case .success: return Color.green.opacity(0.9)
        case .error: return Color.red.opacity(0.9)
        case .info: return Color.blue.opacity(0.9)
        }
    }
    
    private var borderColor: Color {
        switch type {
        case .success: return Color.green.opacity(0.7)
        case .error: return Color.red.opacity(0.7)
        case .info: return Color.blue.opacity(0.7)
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