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

struct TweetBodyView: View {
    @Binding var tweet: Tweet
    var enableTap: Bool = false
    var retweet: (Tweet) async -> Void
    var deleteTweet: (Tweet) async -> Void
    
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
        
        TweetActionButtonsView(tweet: $tweet, retweet: retweet)
    }
}
