import SwiftUI

struct TabButton: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? XTheme.textColor : XTheme.secondaryTextColor)
                Rectangle()
                    .fill(isSelected ? XTheme.accentColor : Color.clear)
                    .frame(width: 56, height: 4)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: isSelected ? XTheme.accentColor.opacity(0.25) : Color.clear, radius: 1, x: 0, y: 1)
    }
}

// MARK: - Preview
struct TabButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            TabButton(title: "Tab 1", isSelected: true) {}
            TabButton(title: "Tab 2", isSelected: false) {}
        }
        .padding()
    }
} 
