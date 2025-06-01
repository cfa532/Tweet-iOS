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
        !tweetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty
    }
    
    func postTweet() async {
        print("DEBUG: Starting postTweet()")
        
        let trimmedContent = tweetContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard !trimmedContent.isEmpty || !selectedItems.isEmpty else {
            print("DEBUG: Tweet validation failed - empty content and no attachments")
            toastMessage = "Tweet cannot be empty"
            toastType = .error
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { self.showToast = false }
            }
            return
        }
        
        // Create tweet object
        print("DEBUG: Creating tweet object")
        let tweet = Tweet(
            mid: "",
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            title: nil,
            originalTweetId: nil,
            originalAuthorId: nil,
            author: hproseInstance.appUser,
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
                    
                    // Get the type identifier and determine file extension
                    let typeIdentifier = item.supportedContentTypes.first?.identifier ?? "public.image"
                    let fileExtension: String
                    
                    if typeIdentifier.contains("jpeg") || typeIdentifier.contains("jpg") {
                        fileExtension = "jpg"
                    } else if typeIdentifier.contains("png") {
                        fileExtension = "png"
                    } else if typeIdentifier.contains("gif") {
                        fileExtension = "gif"
                    } else if typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
                        fileExtension = "heic"
                    } else if typeIdentifier.contains("mp4") {
                        fileExtension = "mp4"
                    } else if typeIdentifier.contains("mov") {
                        fileExtension = "mov"
                    } else if typeIdentifier.contains("m4v") {
                        fileExtension = "m4v"
                    } else if typeIdentifier.contains("mkv") {
                        fileExtension = "mkv"
                    } else {
                        fileExtension = "file"
                    }
                    
                    // Create a unique filename with timestamp
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let filename = "\(timestamp)_\(UUID().uuidString).\(fileExtension)"
                    
                    itemData.append(HproseInstance.PendingUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data,
                        fileName: filename
                    ))
                }
            } catch {
                print("DEBUG: Error loading image data: \(error)")
                toastMessage = "Failed to load media: \(error.localizedDescription)"
                toastType = .error
                showToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { self.showToast = false }
                }
                return
            }
        }
        
        // Set uploading state
        isUploading = true
        
        print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
        hproseInstance.scheduleTweetUpload(tweet: tweet, itemData: itemData)
        
        // Reset form
        tweetContent = ""
        selectedItems = []
        isUploading = false
        
        // Post notification for new tweet
        NotificationCenter.default.post(
            name: .newTweetCreated,
            object: nil,
            userInfo: ["tweet": tweet]
        )
    }
}
