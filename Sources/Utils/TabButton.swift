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
                    .foregroundColor(isSelected ? .primary : .secondary)
                Rectangle()
                    .fill(isSelected ? Color.blue : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.clear, radius: 1, x: 0, y: 1)
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
