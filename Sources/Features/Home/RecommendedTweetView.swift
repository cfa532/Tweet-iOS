import SwiftUI

struct RecommendedTweetView: View {
    let onScroll: ((CGFloat) -> Void)?
    
    init(onScroll: ((CGFloat) -> Void)? = nil) {
        self.onScroll = onScroll
    }
    
    var body: some View {
        Text("Recommended tweets coming soon")
            .foregroundColor(.themeSecondaryText)
    }
}

// MARK: - Preview
struct RecommendedTweetView_Previews: PreviewProvider {
    static var previews: some View {
        RecommendedTweetView()
    }
} 