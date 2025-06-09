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
            return "Tweet cannot be empty."
        case .uploadFailed:
            return "Failed to upload tweet. Please try again."
        }
    }
}

@available(iOS 16.0, *)
@MainActor
class ComposeTweetViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var title: String = ""
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var selectedItemData: [HproseInstance.PendingUpload.ItemData] = []
    @Published var isUploading = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showPollCreation = false
    @Published var showLocationPicker = false
    @Published var error: Error?
    @Published var selectedMedia: [MimeiFileType] = []
    @Published var uploadProgress = 0.0
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var toastType: ToastView.ToastType = .error
    
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    var canPostTweet: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty
    }
    
    func uploadTweet() async {
        guard !content.isEmpty else {
            showError = true
            errorMessage = "Tweet content cannot be empty"
            return
        }
        
        isUploading = true
        defer { isUploading = false }
        
        do {
            let tweet = Tweet(
                mid: Constants.GUEST_ID,
                authorId: AppUser.shared.mid,
                content: content,
                title: title.isEmpty ? nil : title
            )
            
            if selectedItemData.isEmpty {
                if let uploadedTweet = try await hproseInstance.uploadTweet(tweet) {
                    // Post notification for new tweet
                    NotificationCenter.default.post(
                        name: .newTweetCreated,
                        object: nil,
                        userInfo: ["tweet": uploadedTweet]
                    )
                }
            } else {
                await hproseInstance.scheduleTweetUpload(tweet: tweet, itemData: selectedItemData)
            }
            
            // Reset form
            content = ""
            title = ""
            selectedItems = []
            selectedItemData = []
            
        } catch {
            showError = true
            errorMessage = error.localizedDescription
        }
    }
    
    func loadTransferable(from item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                let typeIdentifier = item.supportedContentTypes.first?.identifier ?? ""
                let fileName = typeIdentifier.components(separatedBy: ".").last ?? "image"
                selectedItemData.append(HproseInstance.PendingUpload.ItemData(
                    identifier: item.itemIdentifier ?? UUID().uuidString,
                    typeIdentifier: typeIdentifier,
                    data: data,
                    fileName: fileName
                ))
            }
        } catch {
            showError = true
            errorMessage = "Failed to load image: \(error.localizedDescription)"
        }
    }
    
    func removeItem(at index: Int) {
        guard index < selectedItemData.count else { return }
        selectedItemData.remove(at: index)
        if index < selectedItems.count {
            selectedItems.remove(at: index)
        }
    }
}
