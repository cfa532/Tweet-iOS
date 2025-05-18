import Foundation
import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
enum TweetError: LocalizedError {
    case emptyTweet
    
    var errorDescription: String? {
        switch self {
        case .emptyTweet:
            return "Tweet cannot be empty."
        }
    }
}

@available(iOS 16.0, *)
@MainActor
class ComposeTweetViewModel: ObservableObject {
    @Published var tweetContent: String = ""
    @Published var showPollCreation = false
    @Published var showLocationPicker = false
    @Published var error: Error?
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var selectedMedia: [MimeiFileType] = []
    @Published var isUploading = false
    @Published var uploadProgress = 0.0
    
    func postTweet() async {
        let trimmedContent = tweetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard !trimmedContent.isEmpty || !selectedItems.isEmpty else {
            error = TweetError.emptyTweet
            return
        }
        
        isUploading = true
        uploadProgress = 0.0
        
        do {
            // Create tweet with empty attachments initially
            let tweet = Tweet(
                mid: UUID().uuidString,
                authorId: HproseInstance.shared.appUser.mid,
                content: trimmedContent,
                timestamp: Date(),
                author: HproseInstance.shared.appUser,
                attachments: [],
            )
            
            // Prepare item data
            var itemData: [HproseInstance.PendingUpload.ItemData] = []
            for item in selectedItems {
                if let data = try await item.loadTransferable(type: Data.self),
                   let typeIdentifier = try await item.loadTransferable(type: String.self) {
                    itemData.append(HproseInstance.PendingUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data
                    ))
                }
            }
            
            // Schedule upload with prepared data
            HproseInstance.shared.scheduleTweetUpload(tweet: tweet, itemData: itemData)
            
            // Reset form
            tweetContent = ""
            selectedItems = []
            selectedMedia = []
            isUploading = false
            uploadProgress = 0.0
        } catch {
            isUploading = false
            uploadProgress = 0
            self.error = error
        }
    }
}
