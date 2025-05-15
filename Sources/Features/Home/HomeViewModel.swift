import Foundation

@MainActor
class HomeViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []
    @Published var isLoading = false
    @Published var error: Error?
    
    func fetchTweets() async {
        isLoading = true
        error = nil
        
        do {
            let fetchedTweets: [Tweet] = try await HproseService.shared.invoke("getTweets")
            tweets = fetchedTweets
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    func likeTweet(_ tweet: Tweet) async {
        do {
            let _: Bool = try await HproseService.shared.invoke("likeTweet", tweet.id)
            if let index = tweets.firstIndex(where: { $0.id == tweet.id }) {
                var updatedTweet = tweet
                updatedTweet.isLiked.toggle()
                tweets[index] = updatedTweet
            }
        } catch {
            self.error = error
        }
    }
    
    func retweet(_ tweet: Tweet) async {
        do {
            let _: Bool = try await HproseService.shared.invoke("retweet", tweet.id)
            if let index = tweets.firstIndex(where: { $0.id == tweet.id }) {
                var updatedTweet = tweet
                updatedTweet.isRetweeted.toggle()
                tweets[index] = updatedTweet
            }
        } catch {
            self.error = error
        }
    }
} 