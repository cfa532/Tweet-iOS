import Foundation
import SwiftUI
import PhotosUI
import Photos

@available(iOS 16.0, *)
enum TweetError: LocalizedError {
    case emptyTweet
    case emptyComment
    case uploadFailed
    case commentUploadFailed
    
    var errorDescription: String? {
        switch self {
        case .emptyTweet:
            return NSLocalizedString("Tweet cannot be empty.", comment: "Empty tweet error")
        case .emptyComment:
            return NSLocalizedString("Comment cannot be empty.", comment: "Empty comment error")
        case .uploadFailed:
            return NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Upload failed error")
        case .commentUploadFailed:
            return NSLocalizedString("Failed to upload comment. Please try again.", comment: "Comment upload failed error")
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
    @Published var selectedImages: [UIImage] = []
    @Published var selectedVideos: [URL] = []
    @Published var selectedMedia: [MimeiFileType] = []
    @Published var uploadProgress = 0.0
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastType: ToastView.ToastType = .error
    @Published var isPrivate: Bool = false
    
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
        // Default to public (false) for all builds
        self.isPrivate = false
    }
    
    var canPostTweet: Bool {
        MediaUploadHelper.validateContent(
            content: tweetContent,
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos
        )
    }
    
    func postTweet() async {
        let trimmedContent = tweetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: tweetContent,
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos
        ) else {
            print("DEBUG: Tweet validation failed - empty content and no attachments")
            toastMessage = NSLocalizedString("Tweet cannot be empty.", comment: "Empty tweet error")
            toastType = .error
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { self.showToast = false }
            }
            return
        }
        
        // Create tweet object
        #if DEBUG
        let isPrivateValue = isPrivate
        #else
        let isPrivateValue = false
        #endif
        
        let tweet = Tweet(
            mid: Constants.GUEST_ID,        // placeholder Mimei Id
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
            attachments: nil,
            isPrivate: isPrivateValue
        )
        
        // Prepare item data using helper
        let itemData: [HproseInstance.PendingTweetUpload.ItemData]
        
        do {
            itemData = try await MediaUploadHelper.prepareItemData(
                selectedItems: selectedItems,
                selectedImages: selectedImages,
                selectedVideos: selectedVideos
            )
        } catch {
            print("DEBUG: Error preparing item data: \(error)")
            toastMessage = NSLocalizedString("Failed to upload tweet. Please try again.", comment: "Upload failed error")
            toastType = .error
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { self.showToast = false }
            }
            return
        }
        
        print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
        hproseInstance.scheduleTweetUpload(tweet: tweet, itemData: itemData)
    }
    
    func clearForm() {
        tweetContent = ""
        selectedItems = []
        selectedImages = []
        selectedVideos = []
        isPrivate = false
    }
}
