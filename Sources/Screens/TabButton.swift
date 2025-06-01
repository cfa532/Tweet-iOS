import SwiftUI



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
