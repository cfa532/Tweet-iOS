import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct CommentComposeView: View {
    @ObservedObject var tweet: Tweet
    @ObservedObject var commentsVM: CommentsViewModel
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
            await commentsVM.postComment(comment, tweet: tweet)
            dismiss()
        } catch {
            self.error = error
        }
    }
} 
