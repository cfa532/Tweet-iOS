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
    @State private var isSubmitting = false
    @FocusState private var isEditorFocused: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance

    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
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
                                        .foregroundColor(.themeText)
                                    Text("@\(tweet.author?.username ?? "")")
                                        .font(.subheadline)
                                        .foregroundColor(.themeSecondaryText)
                                }
                                
                                if let content = tweet.content {
                                    Text(content)
                                        .font(.body)
                                        .foregroundColor(.themeText)
                                        .lineLimit(3)
                                }
                            }
                            .padding()
                            .background(Color.themeSecondaryBackground)
                            .cornerRadius(8)
                            .padding(.horizontal)
                            .frame(maxHeight: 150)
                        }
                        
                        TextEditor(text: $commentText)
                            .frame(minHeight: 150)
                            .padding()
                            .focused($isEditorFocused)
                            .background(Color(.systemBackground))
                            .onTapGesture {
                                isEditorFocused = true
                            }
                        
                        // Thumbnail preview section
                        if !selectedItems.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(selectedItems.enumerated()), id: \.offset) { index, item in
                                        ThumbnailView(item: item)
                                            .frame(width: 100, height: 100)
                                            .overlay(
                                                Button(action: {
                                                    selectedItems.remove(at: index)
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
                                    .foregroundColor(.themeAccent)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            Text("\(max(0, Constants.MAX_TWEET_SIZE - commentText.count))")
                                .foregroundColor(commentText.count > Constants.MAX_TWEET_SIZE ? .red : .themeSecondaryText)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.themeBackground)
                        .overlay(
                            Rectangle()
                                .frame(height: 1)
                                .foregroundColor(Color.themeBorder),
                            alignment: .top
                        )
                    }
                }
                
                if let error = error {
                    VStack {
                        Spacer()
                        ToastView(message: error.localizedDescription, type: .error)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: error != nil)
                    .onAppear {
                        // Auto-dismiss error after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                self.error = nil
                            }
                        }
                    }
                }
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
                    .disabled((commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedItems.isEmpty) || isSubmitting)
                    .overlay(
                        Group {
                            if isSubmitting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    )
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(commentText.count > 0)
        .onAppear {
            // Try to focus immediately
            isEditorFocused = true
            
            // If immediate focus doesn't work, try again after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isEditorFocused = true
            }
        }
    }
    
    private func submitComment() async {
        let trimmedContent = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard !trimmedContent.isEmpty || !selectedItems.isEmpty else {
            print("DEBUG: Comment validation failed - empty content and no attachments")
            await MainActor.run {
                error = TweetError.emptyTweet
            }
            return
        }
        
        await MainActor.run {
            isSubmitting = true
        }
        
        // Create comment object with a temporary UUID
        let comment = Tweet(
            mid: UUID().uuidString,         // temporary ID that will be replaced by server
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            originalTweetId: isQuoting ? tweet.mid : nil,
            originalAuthorId: isQuoting ? tweet.authorId : nil
        )
        
        // Prepare item data
        print("DEBUG: Preparing item data for \(selectedItems.count) items")
        var itemData: [HproseInstance.PendingTweetUpload.ItemData] = []
        
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
                    
                    // Determine if this is a video file for noResample parameter
                    _ = typeIdentifier.contains("movie") || 
                                 typeIdentifier.contains("video") || 
                                 ["mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf"].contains(fileExtension)
                    
                    itemData.append(HproseInstance.PendingTweetUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data,
                        fileName: filename,
                        noResample: false // Resample the vidoe.
                    ))
                }
            } catch {
                print("DEBUG: Error loading image data: \(error)")
                await MainActor.run {
                    self.error = error
                    isSubmitting = false
                }
                return
            }
        }
        
        print("DEBUG: Scheduling comment upload with \(itemData.count) attachments")
        hproseInstance.scheduleCommentUpload(comment: comment, to: tweet, itemData: itemData)
        
        // Reset form and dismiss
        await MainActor.run {
            commentText = ""
            selectedItems = []
            isSubmitting = false
            dismiss()
        }
    }
} 
