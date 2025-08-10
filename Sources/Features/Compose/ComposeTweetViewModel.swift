import Foundation
import SwiftUI
import PhotosUI
import Photos

@available(iOS 16.0, *)
enum TweetError: LocalizedError {
    case emptyTweet
    case uploadFailed
    
    var errorDescription: String? {
        switch self {
        case .emptyTweet:
            return NSLocalizedString("Tweet cannot be empty.", comment: "Empty tweet error")
        case .uploadFailed:
            return NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Upload failed error")
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
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastType: ToastView.ToastType = .error
    
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    var canPostTweet: Bool {
        MediaUploadHelper.validateContent(
            content: tweetContent,
            selectedItems: selectedItems,
            selectedImages: []
        )
    }
    
    func postTweet() async {
        let trimmedContent = tweetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: tweetContent,
            selectedItems: selectedItems,
            selectedImages: []
        ) else {
            print("DEBUG: Tweet validation failed - empty content and no attachments")
            toastMessage = "Tweet cannot be empty"
            toastType = .error
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.showToast = false }
            }
            isUploading = false
            return
        }
        
        // Create tweet object
        let tweet = Tweet(
            mid: Constants.GUEST_ID,        // placeholder Mimei Id
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            attachments: nil,
        )
        
        // Prepare item data using helper
        let itemData: [HproseInstance.PendingTweetUpload.ItemData]
        
        do {
            itemData = try await MediaUploadHelper.prepareItemData(
                selectedItems: selectedItems,
                selectedImages: []
            )
        } catch {
            print("DEBUG: Error preparing item data: \(error)")
            toastMessage = "Failed to load media: \(error.localizedDescription)"
            toastType = .error
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.showToast = false }
            }
            isUploading = false
            return
        }
        
        // Show toast before starting upload
        toastMessage = "Uploading tweet..."
        toastType = .info
        showToast = true
        
        // Set uploading state
        isUploading = true
        
        print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
        hproseInstance.scheduleTweetUpload(tweet: tweet, itemData: itemData)
        
        // Reset form
        tweetContent = ""
        selectedItems = []
        
        // Hide the upload toast after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation { self.showToast = false }
        }
        
        // Reset uploading state
        isUploading = false
    }
}
