import Foundation

@MainActor
class ComposeTweetViewModel: ObservableObject {
    @Published var tweetContent = ""
    @Published var showPollCreation = false
    @Published var showLocationPicker = false
    @Published var error: Error?
    
    func postTweet() async {
        do {
            let _: Bool = try await NetworkService.shared.invoke("createTweet", tweetContent)
            tweetContent = ""
        } catch {
            self.error = error
        }
    }
} 