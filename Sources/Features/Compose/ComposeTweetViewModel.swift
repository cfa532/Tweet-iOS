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
    @Published var selectedDocuments: [DocumentFile] = []
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
            selectedVideos: selectedVideos,
            selectedDocuments: selectedDocuments
        )
    }
    
    func postTweet() async throws {
        guard canPostTweet else { throw TweetError.emptyTweet }

        let record = TweetRecord(
            mid: Constants.GUEST_ID,
            authorId: hproseInstance.appUser.mid,
            content: tweetContent.trimmingCharacters(in: .whitespacesAndNewlines),
            isPrivate: isPrivate
        )
        let itemData = try await MediaUploadHelper.prepareItemData(
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos,
            selectedDocuments: selectedDocuments
        )
        try await hproseInstance.uploadManager.scheduleTweetUpload(record: record, itemData: itemData)
    }

    func clearForm() {
        tweetContent = ""
        selectedItems = []
        selectedImages = []
        selectedVideos = []
        selectedDocuments = []
        isPrivate = false
    }
}
