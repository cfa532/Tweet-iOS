import SwiftUI

/// A custom button wrapper that prevents unintentional repeated tapping
/// by adding a cooldown period between taps.
struct PreventRepeatedTapButton<Label: View>: View {
    private let action: () -> Void
    private let label: () -> Label
    private let cooldownDuration: TimeInterval
    private let disabledColor: Color?
    private let enableAnimation: Bool
    private let enableVibration: Bool
    
    @State private var isEnabled: Bool = true
    @State private var lastTapTime: Date = Date.distantPast
    
    /// Initialize the button with custom parameters
    /// - Parameters:
    ///   - cooldownDuration: Minimum time interval between taps (default: 0.5 seconds)
    ///   - disabledColor: Color to show when button is disabled (default: nil - uses system disabled color)
    ///   - enableAnimation: Whether to show animation when button is disabled (default: true)
    ///   - enableVibration: Whether to provide haptic feedback when tapped (default: false)
    ///   - action: The action to perform when tapped
    ///   - label: The button label view
    init(
        cooldownDuration: TimeInterval = 0.5,
        disabledColor: Color? = nil,
        enableAnimation: Bool = true,
        enableVibration: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.cooldownDuration = cooldownDuration
        self.disabledColor = disabledColor
        self.enableAnimation = enableAnimation
        self.enableVibration = enableVibration
        self.action = action
        self.label = label
    }
    
    var body: some View {
        Button(action: handleTap) {
            label()
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : (enableAnimation ? 0.6 : 1.0))
        .animation(enableAnimation ? .easeInOut(duration: 0.1) : nil, value: isEnabled)
    }
    
    private func handleTap() {
        let currentTime = Date()
        let timeSinceLastTap = currentTime.timeIntervalSince(lastTapTime)
        
        // Check if enough time has passed since the last tap
        guard timeSinceLastTap >= cooldownDuration else {
            return
        }
        
        // Provide haptic feedback if enabled
        if enableVibration {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare() // Prepare for better responsiveness
            impactFeedback.impactOccurred()
        }
        
        // Update last tap time and disable button temporarily
        lastTapTime = currentTime
        isEnabled = false
        
        // Perform the action
        action()
        
        // Re-enable the button after cooldown
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownDuration) {
            isEnabled = true
        }
    }
}

/// Convenience initializer for text-based buttons
extension PreventRepeatedTapButton where Label == Text {
    init(
        _ title: String,
        cooldownDuration: TimeInterval = 0.5,
        disabledColor: Color? = nil,
        enableAnimation: Bool = true,
        enableVibration: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            cooldownDuration: cooldownDuration,
            disabledColor: disabledColor,
            enableAnimation: enableAnimation,
            enableVibration: enableVibration,
            action: action
        ) {
            Text(title)
        }
    }
}

/// Convenience initializer for system image buttons
extension PreventRepeatedTapButton where Label == Image {
    init(
        systemName: String,
        cooldownDuration: TimeInterval = 0.5,
        disabledColor: Color? = nil,
        enableAnimation: Bool = true,
        enableVibration: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            cooldownDuration: cooldownDuration,
            disabledColor: disabledColor,
            enableAnimation: enableAnimation,
            enableVibration: enableVibration,
            action: action
        ) {
            Image(systemName: systemName)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PreventRepeatedTapButton("Tap Me (0.5s cooldown)") {
            print("Button tapped!")
        }
        
        PreventRepeatedTapButton(
            "Tap Me (1s cooldown)",
            cooldownDuration: 1.0
        ) {
            print("Button tapped!")
        }
        
        PreventRepeatedTapButton(
            systemName: "heart.fill",
            cooldownDuration: 0.3
        ) {
            print("Heart tapped!")
        }
        .foregroundColor(.red)
        
        PreventRepeatedTapButton(
            cooldownDuration: 0.8
        ) {
            print("Custom button tapped!")
        } label: {
            HStack {
                Image(systemName: "star.fill")
                Text("Custom Label")
            }
            .foregroundColor(.blue)
        }
    }
    .padding()
}
