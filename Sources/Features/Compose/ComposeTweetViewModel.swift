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
        
        do {
            print("DEBUG: Creating tweet object")
            // Create tweet with empty attachments initially
            let tweet = Tweet(
                mid: UUID().uuidString,
                authorId: HproseInstance.shared.appUser.mid,
                content: trimmedContent,
                timestamp: Date(),
                author: HproseInstance.shared.appUser,
            )
            
            print("DEBUG: Preparing item data for \(selectedItems.count) items")
            // Prepare item data
            var itemData: [HproseInstance.PendingUpload.ItemData] = []
            for item in selectedItems {
                print("DEBUG: Processing item: \(item.itemIdentifier ?? "unknown")")
                do {
                    // First try to get the type identifier
                    let typeIdentifier = try await item.loadTransferable(type: String.self)
                    print("DEBUG: Type identifier: \(typeIdentifier ?? "nil")")
                    
                    // Then try to get the image data
                    if let data = try await item.loadTransferable(type: Data.self) {
                        print("DEBUG: Successfully loaded image data: \(data.count) bytes")
                        itemData.append(HproseInstance.PendingUpload.ItemData(
                            identifier: item.itemIdentifier ?? UUID().uuidString,
                            typeIdentifier: typeIdentifier ?? "public.image",
                            data: data
                        ))
                    } else {
                        print("DEBUG: Failed to load image data")
                    }
                } catch {
                    print("DEBUG: Error loading item data: \(error)")
                }
            }
            
            print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
            // Schedule upload with prepared data
            HproseInstance.shared.scheduleTweetUpload(tweet: tweet, itemData: itemData)
            
            print("DEBUG: Resetting form")
            // Reset form
            tweetContent = ""
            selectedItems = []
            selectedMedia = []
            isUploading = false
            uploadProgress = 0.0
        } catch {
            print("DEBUG: Error in postTweet: \(error)")
            isUploading = false
            uploadProgress = 0
            self.error = error
        }
    }
}
