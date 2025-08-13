import SwiftUI

/// A custom button style that provides haptic feedback on tap
struct HapticButtonStyle: ButtonStyle {
    private let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
    
    init(feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        self.feedbackStyle = feedbackStyle
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { isPressed in
                if isPressed {
                    let impactFeedback = UIImpactFeedbackGenerator(style: feedbackStyle)
                    impactFeedback.prepare() // Prepare for better responsiveness
                    impactFeedback.impactOccurred()
                }
            }
    }
}

/// Extension to provide convenient button style modifiers
extension View {
    /// Apply haptic feedback to a button with light impact
    func hapticButton() -> some View {
        self.buttonStyle(HapticButtonStyle(feedbackStyle: .light))
    }
    
    /// Apply haptic feedback to a button with medium impact
    func hapticButtonMedium() -> some View {
        self.buttonStyle(HapticButtonStyle(feedbackStyle: .medium))
    }
    
    /// Apply haptic feedback to a button with heavy impact
    func hapticButtonHeavy() -> some View {
        self.buttonStyle(HapticButtonStyle(feedbackStyle: .heavy))
    }
    
    /// Apply haptic feedback to a button with rigid impact
    func hapticButtonRigid() -> some View {
        self.buttonStyle(HapticButtonStyle(feedbackStyle: .rigid))
    }
    
    /// Apply haptic feedback to a button with soft impact
    func hapticButtonSoft() -> some View {
        self.buttonStyle(HapticButtonStyle(feedbackStyle: .soft))
    }
    
    /// Apply haptic feedback to any view on tap
    func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) -> some View {
        self.onTapGesture {
            let impactFeedback = UIImpactFeedbackGenerator(style: style)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        Button("Light Haptic") {
            print("Button tapped!")
        }
        .hapticButton()
        .padding()
        .background(Color.blue)
        .foregroundColor(.white)
        .cornerRadius(8)
        
        Button("Medium Haptic") {
            print("Button tapped!")
        }
        .hapticButtonMedium()
        .padding()
        .background(Color.green)
        .foregroundColor(.white)
        .cornerRadius(8)
        
        Button("Heavy Haptic") {
            print("Button tapped!")
        }
        .hapticButtonHeavy()
        .padding()
        .background(Color.red)
        .foregroundColor(.white)
        .cornerRadius(8)
        
        Button("Rigid Haptic") {
            print("Button tapped!")
        }
        .hapticButtonRigid()
        .padding()
        .background(Color.orange)
        .foregroundColor(.white)
        .cornerRadius(8)
        
        Button("Soft Haptic") {
            print("Button tapped!")
        }
        .hapticButtonSoft()
        .padding()
        .background(Color.purple)
        .foregroundColor(.white)
        .cornerRadius(8)
    }
    .padding()
}
