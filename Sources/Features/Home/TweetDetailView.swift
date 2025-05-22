import SwiftUI
import AVKit

struct TweetDetailView: View {
    @Binding var tweet: Tweet
    @State private var showBrowser = false
    @State private var selectedMediaIndex = 0
    let retweet: (Tweet) async -> Void
    let deleteTweet: (Tweet) async -> Void

    var body: some View {
        VStack {
            if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl, !attachments.isEmpty {
                TabView(selection: $selectedMediaIndex) {
                    ForEach(attachments.indices, id: \.self) { index in
                        MediaCell(
                            attachment: attachments[index],
                            baseUrl: baseUrl,
                            play: index == selectedMediaIndex
                        )
                        .tag(index)
                        .onTapGesture {
                            showBrowser = true
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always)) // Show dots
                .frame(maxWidth: .infinity)
                .background(Color.black)
            }

            // Other tweet details (Author, content, etc.)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Author info
                    TweetItemHeaderView(tweet: $tweet)
                    
                    // Tweet content
                    if let content = tweet.content, !content.isEmpty {
                        Text(content)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    // Action bar
                    TweetActionButtonsView(tweet: $tweet, retweet: retweet)
                        .padding(.top, 16)
                }
                .padding()
            }
            .background(Color(.systemBackground))
        }
        .navigationTitle("Tweet")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .fullScreenCover(isPresented: $showBrowser) {
            MediaBrowserView(attachments: tweet.attachments ?? [], baseUrl: tweet.author?.baseUrl ?? "", initialIndex: selectedMediaIndex)
        }
    }
}
