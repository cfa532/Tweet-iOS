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
        let tweet = Tweet(
            mid: Constants.GUEST_ID,        // placeholder Mimei Id
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            attachments: nil,
        )
        
        // Prepare item data
        var itemData: [HproseInstance.PendingTweetUpload.ItemData] = []
        
        for item in selectedItems {
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
                    
                    // Determine if this is a video file for noResample parameter
                    let isVideo = typeIdentifier.contains("movie") || 
                                 typeIdentifier.contains("video") || 
                                 ["mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf"].contains(fileExtension)
                    
                    itemData.append(HproseInstance.PendingTweetUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data,
                        fileName: filename,
                        noResample: false // Set to false for now
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
        isUploading = false
        
        // Hide the upload toast after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation { self.showToast = false }
        }
    }
}
