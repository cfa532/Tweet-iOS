import Foundation
import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
@MainActor
class ComposeTweetViewModel: ObservableObject {
    @Published var tweetContent: String = ""
    @Published var showPollCreation = false
    @Published var showLocationPicker = false
    @Published var error: Error?
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var selectedMedia: [MimeiFileType] = []
    
    func postTweet() async {
        // TODO: Implement tweet posting with media
    }
}
