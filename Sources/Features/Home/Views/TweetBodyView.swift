import SwiftUI

struct TweetBodyView: View {
    let tweet: Tweet
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let content = tweet.content, !content.isEmpty {
                Text(content)
                    .font(.body)
            }
            
            if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                MediaGridView(attachments: attachments, baseUrl: baseUrl)
            }
        }
        Spacer(minLength: 12)
        TweetActionButtonsView(tweet: tweet)
    }
}
