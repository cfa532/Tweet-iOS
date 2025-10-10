import SwiftUI

struct RecommendedTweetView: View {
    let onScroll: ((CGFloat, CGFloat) -> Void)?  // (offset, delta)
    
    init(onScroll: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.onScroll = onScroll
    }
    
    var body: some View {
        Text(LocalizedStringKey("Recommended tweets coming soon"))
            .foregroundColor(.themeSecondaryText)
    }
}

// MARK: - Preview
struct RecommendedTweetView_Previews: PreviewProvider {
    static var previews: some View {
        RecommendedTweetView()
    }
} 