import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct CommentComposeView: View {
    @ObservedObject var tweet: Tweet
    @Environment(\.dismiss) private var dismiss
    @State private var commentText = ""
    @State private var error: Error?
    @State private var isQuoting = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Quote checkbox
                HStack {
                    Button(action: { isQuoting.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: isQuoting ? "checkmark.square.fill" : "square")
                                .foregroundColor(isQuoting ? .blue : .secondary)
                            Text("Quote Tweet")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    Spacer()
                }
                .padding()
                .background(Color(.systemBackground))
                
                // Original tweet preview when quoting
                if isQuoting {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(tweet.author?.name ?? "Unknown")
                                .font(.headline)
                            Text("@\(tweet.author?.username ?? "")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        if let content = tweet.content {
                            Text(content)
                                .font(.body)
                                .lineLimit(3)
                        }
                        
                        if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                            MediaGridView(attachments: attachments, baseUrl: baseUrl)
                                .frame(maxHeight: 100)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .frame(maxHeight: 150)
                }
                
                TextEditor(text: $commentText)
                    .frame(maxHeight: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                
                // Thumbnail preview section
                if !selectedItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(selectedItems, id: \.itemIdentifier) { item in
                                ThumbnailView(item: item)
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        Button(action: {
                                            selectedItems.removeAll { $0.itemIdentifier == item.itemIdentifier }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.white)
                                                .background(Color.black.opacity(0.5))
                                                .clipShape(Circle())
                                        }
                                        .padding(4),
                                        alignment: .topTrailing
                                    )
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 120)
                    .background(Color(.systemBackground))
                }
                
                // Attachment toolbar
                HStack(spacing: 20) {
                    PhotosPicker(selection: $selectedItems,
                               matching: .any(of: [.images, .videos])) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text("\(max(0, Constants.MAX_TWEET_SIZE - commentText.count))")
                        .foregroundColor(commentText.count > Constants.MAX_TWEET_SIZE ? .red : .gray)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(.systemGray4)),
                    alignment: .top
                )
            }
            .navigationTitle(isQuoting ? "Quote Tweet" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isQuoting ? "Quote" : "Reply") {
                        Task {
                            await submitComment()
                        }
                    }
                    .disabled((commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedItems.isEmpty))
                }
            }
        }
    }
    
    private func submitComment() async {
        do {
            // Create the comment object
            var comment = Tweet(
                mid: "", // Placeholder ID
                authorId: hproseInstance.appUser.mid,
                content: commentText.trimmingCharacters(in: .whitespacesAndNewlines),
                timestamp: Date(),
                originalTweetId: isQuoting ? tweet.mid : nil,
                originalAuthorId: isQuoting ? tweet.authorId : nil
            )
            // Ensure optimistic comment has author set
            comment.author = hproseInstance.appUser
            // Prepare item data for attachments
            var itemData: [HproseInstance.PendingUpload.ItemData] = []
            for item in selectedItems {
                if let data = try await item.loadTransferable(type: Data.self) {
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
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let filename = "\(timestamp)_\(UUID().uuidString).\(fileExtension)"
                    itemData.append(HproseInstance.PendingUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data,
                        fileName: filename
                    ))
                }
            }
            // Optimistic UI update: post notification with placeholder comment and incremented count
            await MainActor.run {
                let optimisticTweet = tweet
                optimisticTweet.commentCount = (tweet.commentCount ?? 0) + 1
                NotificationCenter.default.post(
                    name: NSNotification.Name("NewCommentAdded"),
                    object: nil,
                    userInfo: [
                        "tweetId": tweet.mid,
                        "updatedTweet": optimisticTweet,
                        "comment": comment
                    ]
                )
            }
            // Schedule the comment upload with attachments, and handle backend result
            Task {
                // Simulate backend returning a real comment (replace with actual backend logic)
                let realComment: Tweet? = nil // <- Replace with actual backend result if available
                if let realComment = realComment {
                    var realCommentWithAuthor = realComment
                    if realCommentWithAuthor.author == nil {
                        realCommentWithAuthor.author = hproseInstance.appUser
                    }
                    await MainActor.run {
                        let updatedTweet = tweet
                        updatedTweet.commentCount = (tweet.commentCount ?? 0) + 1 // or use backend count if available
                        NotificationCenter.default.post(
                            name: NSNotification.Name("NewCommentAdded"),
                            object: nil,
                            userInfo: [
                                "tweetId": tweet.mid,
                                "updatedTweet": updatedTweet,
                                "comment": realCommentWithAuthor
                            ]
                        )
                    }
                }
                let result = await withCheckedContinuation { continuation in
                    hproseInstance.scheduleCommentUpload(comment: comment, to: tweet, itemData: itemData)
                    // There is no direct callback, so you may need to listen for a notification or implement a completion handler in scheduleCommentUpload.
                    // For now, simulate backend failure after a delay for demonstration:
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        // Simulate failure (set to true to test failure handling)
                        let didFail = false
                        continuation.resume(returning: didFail)
                    }
                }
                if result {
                    // Backend failed: revert optimistic UI
                    await MainActor.run {
                        let revertedTweet = tweet
                        revertedTweet.commentCount = max(0, (tweet.commentCount ?? 1) - 1)
                        NotificationCenter.default.post(
                            name: NSNotification.Name("RevertCommentAdded"),
                            object: nil,
                            userInfo: [
                                "tweetId": tweet.mid,
                                "updatedTweet": revertedTweet,
                                "comment": comment
                            ]
                        )
                    }
                }
            }
            // Dismiss the view immediately since the upload will happen in the background
            dismiss()
        } catch {
            self.error = error
        }
    }
} 
