import Foundation
import SwiftUI
import PhotosUI
import Photos

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
    
    var canPostTweet: Bool {
        let hasContent = !tweetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !selectedItems.isEmpty
        let isWithinLimit = tweetContent.count <= 280
        
        return (hasContent || hasAttachments) && isWithinLimit
    }
    
    func postTweet() async {
        print("DEBUG: Starting postTweet()")
        
        let trimmedContent = tweetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard !trimmedContent.isEmpty || !selectedItems.isEmpty else {
            print("DEBUG: Tweet validation failed - empty content and no attachments")
            error = TweetError.emptyTweet
            return
        }
        
        isUploading = true
        uploadProgress = 0.0
        
        // Create tweet object
        print("DEBUG: Creating tweet object")
        let tweet = Tweet(
            mid: "",
            authorId: HproseInstance.shared.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            title: nil,
            originalTweetId: nil,
            originalAuthorId: nil,
            author: nil,
            favorites: [false, false, false],
            favoriteCount: 0,
            bookmarkCount: 0,
            retweetCount: 0,
            commentCount: 0,
            attachments: nil,
            isPrivate: false,
            downloadable: nil
        )
        
        // Prepare item data
        print("DEBUG: Preparing item data for \(selectedItems.count) items")
        var itemData: [HproseInstance.PendingUpload.ItemData] = []
        
        for item in selectedItems {
            print("DEBUG: Processing item: \(item.itemIdentifier ?? "unknown")")
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    print("DEBUG: Successfully loaded image data: \(data.count) bytes")
                    itemData.append(HproseInstance.PendingUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: item.supportedContentTypes.first?.identifier ?? "public.image",
                        data: data
                    ))
                }
            } catch {
                print("DEBUG: Error loading image data: \(error)")
                self.error = error
                isUploading = false
                uploadProgress = 0.0
                return
            }
        }
        
        print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
        HproseInstance.shared.scheduleTweetUpload(tweet: tweet, itemData: itemData)
        
        // Reset form
        print("DEBUG: Resetting form")
        tweetContent = ""
        selectedItems = []
        selectedMedia = []
        isUploading = false
        uploadProgress = 0.0
    }
}
