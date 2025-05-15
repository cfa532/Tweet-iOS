import Foundation

@MainActor
class ComposeTweetViewModel: ObservableObject {
    @Published var tweetContent = ""
    @Published var showPollCreation = false
    @Published var showLocationPicker = false
    @Published var error: Error?
    
    func postTweet() async {
        // Remove or replace lines using NetworkService.shared.invoke
    }
} 