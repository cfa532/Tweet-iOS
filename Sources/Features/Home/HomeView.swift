import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    
    var body: some View {
        NavigationView {
            List(viewModel.tweets) { tweet in
                TweetRow(tweet: tweet)
            }
            .navigationTitle("Home")
            .refreshable {
                await viewModel.fetchTweets()
            }
            .task {
                await viewModel.fetchTweets()
            }
        }
    }
}

struct TweetRow: View {
    let tweet: Tweet
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let avatarUrl = tweet.author?.avatar {
                    AsyncImage(url: URL(string: avatarUrl)) { image in
                        image.resizable()
                    } placeholder: {
                        Color.gray
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                }
                
                VStack(alignment: .leading) {
                    Text(tweet.author.displayName)
                        .font(.headline)
                    Text("@\(tweet.author.username)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            
            Text(tweet.content)
                .font(.body)
            
            HStack(spacing: 20) {
                Button(action: {}) {
                    Label("\(tweet.comments)", systemImage: "message")
                }
                
                Button(action: {}) {
                    Label("\(tweet.retweets)", systemImage: "arrow.2.squarepath")
                }
                
                Button(action: {}) {
                    Label("\(tweet.likes)", systemImage: tweet.isLiked ? "heart.fill" : "heart")
                }
            }
            .foregroundColor(.gray)
        }
        .padding(.vertical, 8)
    }
} 
