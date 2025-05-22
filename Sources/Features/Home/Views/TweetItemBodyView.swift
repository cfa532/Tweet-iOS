import SwiftUI

// Conditional modifier extension
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct TweetItemBodyView: View {
    @Binding var tweet: Tweet
    var retweet: (Tweet) async -> Void
    var embedded: Bool = false
    var enableTap: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let content = tweet.content, !content.isEmpty {
                Text(content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .if(enableTap) { $0.contentShape(Rectangle()) }
            }
            
            if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                MediaGridView(attachments: attachments, baseUrl: baseUrl)
            }
        }
        Spacer(minLength: 12)
        if !embedded {
            TweetActionButtonsView(tweet: $tweet, retweet: retweet)
        }
    }
}
