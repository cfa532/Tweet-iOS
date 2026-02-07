import SwiftUI
import PhotosUI
import UIKit

@available(iOS 16.0, *)
struct ComposeTweetView: View {
    @StateObject private var viewModel: ComposeTweetViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool
    @State private var shouldFocus = false
    @State private var showMediaPicker = false
    @State private var showCancelConfirmation = false
    @State private var showCamera = false
    @State private var showLoginAlert = false
    @State private var showLoginView = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func hideKeyboard() {
        isEditorFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    // Check if there's content or attachments that would be lost
    private var hasContentOrAttachments: Bool {
        !viewModel.tweetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.selectedItems.isEmpty || !viewModel.selectedImages.isEmpty || !viewModel.selectedVideos.isEmpty || !viewModel.selectedDocuments.isEmpty
    }

    init() {
        // Initialize viewModel with HproseInstance
        _viewModel = StateObject(wrappedValue: ComposeTweetViewModel(hproseInstance: HproseInstance.shared))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mainContent
                toastOverlay
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Avatar(user: hproseInstance.appUser, size: 32)
                        Text(NSLocalizedString("New Tweet", comment: "New tweet screen title"))
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                        if hasContentOrAttachments {
                            showCancelConfirmation = true
                        } else {
                            viewModel.clearForm()
                            dismiss()
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Publish", comment: "Publish tweet button")) {
                        // Check if user is guest
                        if hproseInstance.appUser.isGuest {
                            // Show login alert
                            showLoginAlert = true
                            return
                        }
                        
                        // Capture the data before dismissing
                        let tweetContent = viewModel.tweetContent
                        let selectedItems = viewModel.selectedItems
                        let selectedImages = viewModel.selectedImages
                        let selectedVideos = viewModel.selectedVideos
                        let selectedDocuments = viewModel.selectedDocuments
                        let isPrivate = viewModel.isPrivate
                        
                        // Note: Upload dialog is now shown by the upload queue
                        // No need to call startUpload here - scheduleTweetUpload handles it
                        
                        viewModel.clearForm()
                        dismiss()
                        
                        // Post tweet in background after dismissing using captured data
                        Task {
                            await postTweetInBackground(
                                content: tweetContent,
                                selectedItems: selectedItems,
                                selectedImages: selectedImages,
                                selectedVideos: selectedVideos,
                                selectedDocuments: selectedDocuments,
                                isPrivate: isPrivate
                            )
                        }
                    }
                    .disabled(!viewModel.canPostTweet)
                }

                // Keyboard accessory: always provide an explicit "Done".
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(NSLocalizedString("Done", comment: "Dismiss keyboard")) {
                        hideKeyboard()
                    }
                }
            }
            .task {
                // Wait for sheet presentation animation to complete before focusing
                // This ensures the text editor is fully presented and ready to receive focus
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for sheet animation
                await MainActor.run {
                    isEditorFocused = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .errorOccurred)) { notification in
                if let error = notification.object as? Error {
                    viewModel.toastMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                    viewModel.toastType = .error
                    viewModel.showToast = true
                    
                    // Auto-hide toast after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        withAnimation { viewModel.showToast = false }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.tweetContent.count > 0)
        .alert(NSLocalizedString("Discard Tweet?", comment: "Cancel confirmation title"), isPresented: $showCancelConfirmation) {
            Button(NSLocalizedString("Discard", comment: "Discard button"), role: .destructive) {
                viewModel.clearForm()
                dismiss()
            }
            Button(NSLocalizedString("Keep Editing", comment: "Keep editing button"), role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text(NSLocalizedString("Your tweet will be discarded and cannot be recovered.", comment: "Cancel confirmation message"))
        }
        .alert(NSLocalizedString("Login Required", comment: "Login required alert title"), isPresented: $showLoginAlert) {
            Button(NSLocalizedString("Login", comment: "Login button")) {
                showLoginView = true
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {
                // Do nothing, just dismiss the alert
            }
        } message: {
            Text(NSLocalizedString("To post tweets, you need to log in to your account.", comment: "Login required for tweets message"))
        }
        .sheet(isPresented: $showLoginView) {
            LoginView()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image, videoURL in
                if let image = image {
                    viewModel.selectedImages.append(image)
                }
                if let videoURL = videoURL {
                    viewModel.selectedVideos.append(videoURL)
                }
            }
        }
    }
    
    private var mainContent: some View {
        ZStack {
            // Tap anywhere outside the TextEditor to dismiss keyboard.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { hideKeyboard() }

            ScrollView {
                VStack(spacing: 0) {
                    textEditor
                    mediaPreview
                    attachmentToolbar
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // When the editor is focused, let the TextEditor handle vertical scrolling.
            // Otherwise the outer ScrollView often steals the scroll gesture and long text feels "stuck".
            .scrollDisabled(isEditorFocused)
        }
    }
    
    private var textEditor: some View {
        TextEditor(text: $viewModel.tweetContent)
            .frame(minHeight: 150, maxHeight: 292) // Reduced maxHeight by 8pt
            .padding()
            .focused($isEditorFocused)
            .background(Color(.systemBackground))
            .onTapGesture {
                isEditorFocused = true
            }
    }
    
    private var mediaPreview: some View {
        VStack(spacing: 0) {
            // Media preview (photos/videos)
            MediaPreviewGrid(
                selectedItems: viewModel.selectedItems,
                selectedImages: viewModel.selectedImages,
                selectedVideos: viewModel.selectedVideos,
                onRemoveItem: { index in
                    guard index < viewModel.selectedItems.count else { return }
                    viewModel.selectedItems.remove(at: index)
                },
                onRemoveImage: { index in
                    guard index < viewModel.selectedImages.count else { return }
                    viewModel.selectedImages.remove(at: index)
                },
                onRemoveVideo: { index in
                    guard index < viewModel.selectedVideos.count else { return }
                    viewModel.selectedVideos.remove(at: index)
                }
            )
            .frame(height: (viewModel.selectedItems.isEmpty && viewModel.selectedImages.isEmpty && viewModel.selectedVideos.isEmpty) ? 0 : 120)
            
            // Document preview (PDFs, etc.)
            if !viewModel.selectedDocuments.isEmpty {
                DocumentPreviewGrid(
                    documents: viewModel.selectedDocuments,
                    onRemove: { index in
                        guard index < viewModel.selectedDocuments.count else { return }
                        viewModel.selectedDocuments.remove(at: index)
                    }
                )
                .frame(height: 120)
                .padding(.top, viewModel.selectedItems.isEmpty && viewModel.selectedImages.isEmpty && viewModel.selectedVideos.isEmpty ? 0 : 8)
            }
        }
        .background(Color(.systemBackground))
    }
    
    private func postTweetInBackground(
        content: String,
        selectedItems: [PhotosPickerItem],
        selectedImages: [UIImage],
        selectedVideos: [URL],
        selectedDocuments: [DocumentFile],
        isPrivate: Bool
    ) async {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: content,
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos,
            selectedDocuments: selectedDocuments
        ) else {
            print("DEBUG: Tweet validation failed - empty content and no attachments")
            return
        }
        
        // Create tweet object using singleton
        let tweet = Tweet.getInstance(
            mid: Constants.GUEST_ID,        // placeholder Mimei Id
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970),
            author: hproseInstance.appUser,
            attachments: nil,
            isPrivate: isPrivate
        )
        
        // Prepare item data using helper
        let itemData: [HproseInstance.PendingTweetUpload.ItemData]
        
        do {
            // Show "Preparing..." in dialog while loading media data
            await MainActor.run {
                UploadProgressManager.shared.updateProgress(
                    stage: .preparing,
                    message: NSLocalizedString("Preparing attachments...", comment: "Preparing attachments"),
                    progress: 0.1,
                    detail: ""
                )
            }
            
            itemData = try await MediaUploadHelper.prepareItemData(
                selectedItems: selectedItems,
                selectedImages: selectedImages,
                selectedVideos: selectedVideos,
                selectedDocuments: selectedDocuments
            )
        } catch {
            print("DEBUG: Error preparing item data: \(error)")
            await MainActor.run {
                UploadProgressManager.shared.failUpload(
                    message: NSLocalizedString("Failed to prepare attachments", comment: "Failed to prepare attachments")
                )
            }
            return
        }
        
        print("DEBUG: Scheduling tweet upload with \(itemData.count) attachments")
        hproseInstance.scheduleTweetUpload(tweet: tweet, itemData: itemData)
    }

    private var attachmentToolbar: some View {
        HStack(spacing: 20) {
            MediaPicker(
                selectedItems: $viewModel.selectedItems,
                selectedImages: $viewModel.selectedImages,
                selectedVideos: $viewModel.selectedVideos,
                showCamera: $showCamera,
                error: $viewModel.error,
                maxSelectionCount: 20,
                supportedTypes: [.image, .movie]
            )
            
            // Document picker button
            DocumentPickerButton(
                selectedDocuments: $viewModel.selectedDocuments,
                allowedTypes: [.pdf, .text, .zip],
                icon: "doc.fill",
                color: .blue
            )
            
            Spacer()
            
            // Privacy toggle button - consistent with dropdown menu style
            Button(action: {
                viewModel.isPrivate.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isPrivate ? "lock.fill" : "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(viewModel.isPrivate ? .themeAccent : .themeSecondaryText)
                    
                    Text(viewModel.isPrivate ? LocalizedStringKey("Private") : LocalizedStringKey("Public"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.isPrivate ? .themeAccent : .themeSecondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(viewModel.isPrivate ? Color.themeAccent.opacity(0.1) : Color.themeSecondaryText.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(viewModel.isPrivate ? Color.themeAccent : Color.themeSecondaryText, lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            Text("\(max(0, Constants.MAX_TWEET_SIZE - viewModel.tweetContent.count))")
                .foregroundColor(viewModel.tweetContent.count > Constants.MAX_TWEET_SIZE ? .red : .themeSecondaryText)
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
    
    private var toastOverlay: some View {
        Group {
            if viewModel.showToast {
                VStack {
                    Spacer()
                    ToastView(message: viewModel.toastMessage, type: viewModel.toastType)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.showToast)
            }
        }
    }
    
}
