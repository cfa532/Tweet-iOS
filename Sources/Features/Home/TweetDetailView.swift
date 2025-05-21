import SwiftUI

struct TweetDetailView: View {
    let tweet: Tweet
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Author info
                HStack(alignment: .top, spacing: 12) {
                    if let user = tweet.author {
                        Avatar(user: user, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name ?? "User Name")
                                .font(.headline)
                            Text("@\(user.username ?? "username")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                // Tweet content
                if let content = tweet.content, !content.isEmpty {
                    Text(content)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                // Attachments
                if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl, !attachments.isEmpty {
                    MediaGridView(attachments: attachments, baseUrl: baseUrl)
                        .frame(maxWidth: .infinity)
                }
                // Action bar
                TweetActionButtonsView(tweet: tweet)
                    .padding(.top, 16)
            }
            .padding()
        }
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
    }
} 