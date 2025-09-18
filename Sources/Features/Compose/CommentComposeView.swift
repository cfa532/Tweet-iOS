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
    @State private var selectedImages: [UIImage] = []
    @State private var selectedVideos: [URL] = []
    // Note: isSubmitting state is now managed by DebounceButton
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var showCancelConfirmation = false
    @State private var showCamera = false
    @FocusState private var isEditorFocused: Bool
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Convert PhotosPickerItem array to IdentifiablePhotosPickerItem array
    private var identifiableItems: [IdentifiablePhotosPickerItem] {
        selectedItems.map { IdentifiablePhotosPickerItem(item: $0) }
    }
    
    // Check if there's content or attachments that would be lost
    private var hasContentOrAttachments: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty || !selectedVideos.isEmpty
    }

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
                                    Text(LocalizedStringKey("Quote Tweet"))
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
                                    Text("@\(tweet.author?.username ?? NSLocalizedString("username", comment: "Default username"))")
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
                        MediaPreviewGrid(
                            selectedItems: selectedItems,
                            selectedImages: selectedImages,
                            selectedVideos: selectedVideos,
                            onRemoveItem: { index in
                                selectedItems.remove(at: index)
                            },
                            onRemoveImage: { index in
                                selectedImages.remove(at: index)
                            },
                            onRemoveVideo: { index in
                                selectedVideos.remove(at: index)
                            }
                        )
                        .frame(height: (selectedItems.isEmpty && selectedImages.isEmpty && selectedVideos.isEmpty) ? 0 : 120)
                        .background(Color(.systemBackground))
                        
                        // Attachment toolbar
                        HStack(spacing: 20) {
                            MediaPicker(
                                selectedItems: $selectedItems,
                                selectedImages: $selectedImages,
                                selectedVideos: $selectedVideos,
                                showCamera: $showCamera,
                                error: $error,
                                maxSelectionCount: 20,
                                supportedTypes: [.image, .movie]
                            )
                            
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
                    .animation(.easeInOut(duration: 0.3), value: true)
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
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                        if hasContentOrAttachments {
                            showCancelConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    DebounceButton(
                        NSLocalizedString("Publish", comment: "Publish comment button"),
                        cooldownDuration: 1.0,
                        enableAnimation: true,
                        enableVibration: false
                    ) {
                        Task {
                            await submitComment()
                        }
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedItems.isEmpty && selectedImages.isEmpty && selectedVideos.isEmpty)
                    // Note: Progress indicator is now managed by DebounceButton
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(commentText.count > 0)
        .overlay(
            // Toast message overlay
            VStack {
                Spacer()
                if showToast {
                    ToastView(message: toastMessage, type: toastType)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )
        .onAppear {
            // Try to focus immediately
            isEditorFocused = true
            
            // If immediate focus doesn't work, try again after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isEditorFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .errorOccurred)) { notification in
            if let error = notification.object as? Error {
                showToastMessage(error.localizedDescription, type: .error)
            }
        }
        .alert(NSLocalizedString("Discard Comment?", comment: "Cancel confirmation title"), isPresented: $showCancelConfirmation) {
            Button(NSLocalizedString("Discard", comment: "Discard button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("Keep Editing", comment: "Keep editing button"), role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text(NSLocalizedString("Your comment will be discarded and cannot be recovered.", comment: "Cancel confirmation message"))
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image, videoURL in
                if let image = image {
                    selectedImages.append(image)
                }
                if let videoURL = videoURL {
                    selectedVideos.append(videoURL)
                }
            }
        }
    }
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Hide toast after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + (type == .error ? 5 : 2)) {
            withAnimation { showToast = false }
        }
    }
    
    private func submitComment() async {
        let trimmedContent = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: commentText,
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos
        ) else {
            print("DEBUG: Comment validation failed - empty content and no attachments")
            await MainActor.run {
                showToastMessage(NSLocalizedString("Comment cannot be empty.", comment: "Empty comment error"), type: .error)
            }
            return
        }
        
        // Note: isSubmitting state is now managed by DebounceButton
        
        // Create comment object with a temporary UUID
        let comment = Tweet(
            mid: UUID().uuidString,         // temporary ID that will be replaced by server
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            originalTweetId: isQuoting ? tweet.mid : nil,
            originalAuthorId: isQuoting ? tweet.authorId : nil
        )
        
        // Prepare item data using helper
        print("DEBUG: Preparing item data for \(selectedItems.count) items")
        let itemData: [HproseInstance.PendingTweetUpload.ItemData]
        
        do {
            itemData = try await MediaUploadHelper.prepareItemData(
                selectedItems: selectedItems,
                selectedImages: selectedImages,
                selectedVideos: selectedVideos
            )
        } catch {
            print("DEBUG: Error preparing item data: \(error)")
            await MainActor.run {
                showToastMessage(NSLocalizedString("Failed to upload comment. Please try again.", comment: "Comment upload failed error"), type: .error)
            }
            return
        }
        
        print("DEBUG: Scheduling comment upload with \(itemData.count) attachments")
        hproseInstance.scheduleCommentUpload(comment: comment, to: tweet, itemData: itemData)
        
        // Reset form and dismiss
        await MainActor.run {
            commentText = ""
            selectedItems = []
            selectedImages = []
            selectedVideos = []
            
            // Show success toast before dismissing
            showToastMessage(NSLocalizedString("Comment submitted", comment: "Comment submitted message"), type: .success)
            
            // Dismiss after a short delay to show the toast
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                dismiss()
            }
        }
    }
    
} 
