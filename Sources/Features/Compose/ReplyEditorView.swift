//
//  ReplyEditorView.swift
//  Tweet
//
//  Created by Assistant on 2025/1/27.
//

import SwiftUI
import PhotosUI
import AVFoundation

@available(iOS 16.0, *)
struct ReplyEditorView: View {
    @ObservedObject var parentTweet: Tweet
    let isQuoting: Bool
    @State private var replyText = ""
    @State private var isExpanded = false
    @State private var showExitConfirmation = false
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var selectedVideos: [URL] = []
    @State private var showCamera = false
    @State private var showImagePicker = false
    @State private var error: Error?
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @FocusState private var isTextFieldFocused: Bool
    var onClose: (() -> Void)? = nil
    var onExpandedClose: (() -> Void)? = nil
    var initialExpanded: Bool = false
    
    @EnvironmentObject private var hproseInstance: HproseInstance
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded {
                // Collapsed state - single line input
                collapsedView
            } else {
                // Expanded state - full editor
                expandedView
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 0 : 8)
                .fill(Color(.systemBackground))
        )
        .padding(.horizontal, isExpanded ? 0 : 16)
        .padding(.vertical, 4)
        .alert(NSLocalizedString("Discard Reply", comment: "Discard reply alert title"), isPresented: $showExitConfirmation) {
            Button(NSLocalizedString("Discard", comment: "Discard button"), role: .destructive) {
                clearAndClose()
            }
            Button(NSLocalizedString("Keep Editing", comment: "Keep editing button"), role: .cancel) {
                showExitConfirmation = false
            }
        } message: {
            Text(NSLocalizedString("You have unsaved content. Are you sure you want to discard your reply?", comment: "Discard reply confirmation"))
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
        .sheet(isPresented: $showImagePicker) {
            PhotosPicker("Select Media", selection: $selectedItems, matching: .any(of: [.images, .videos]))
        }
        .onAppear {
            // Set initial expanded state if requested
            print("DEBUG: [ReplyEditorView] onAppear called, initialExpanded = \(initialExpanded)")
            if initialExpanded {
                print("DEBUG: [ReplyEditorView] Setting isExpanded = true from onAppear")
                isExpanded = true
            }
        }
        .onChange(of: initialExpanded) { _, newValue in
            // Respond to changes in initialExpanded parameter
            print("DEBUG: [ReplyEditorView] initialExpanded changed to: \(newValue)")
            if newValue {
                print("DEBUG: [ReplyEditorView] Setting isExpanded = true")
                isExpanded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newCommentAdded)) { notification in
            print("[ReplyEditorView] Received newCommentAdded notification")
            print("[ReplyEditorView] Notification userInfo: \(notification.userInfo ?? [:])")
            
            if let comment = notification.userInfo?["comment"] as? Tweet,
               let parentTweetId = notification.userInfo?["parentTweetId"] as? String {
                print("[ReplyEditorView] Comment authorId: \(comment.authorId)")
                print("[ReplyEditorView] Current user mid: \(hproseInstance.appUser.mid)")
                print("[ReplyEditorView] Parent tweet ID: \(parentTweetId)")
                print("[ReplyEditorView] Current parent tweet mid: \(parentTweet.mid)")
                print("[ReplyEditorView] Comment timestamp: \(comment.timestamp)")
                print("[ReplyEditorView] Time difference: \(abs(comment.timestamp.timeIntervalSince(Date())))")
                
                // Check if this is our comment by comparing author, timestamp, and parent tweet
                if comment.authorId == hproseInstance.appUser.mid &&
                    parentTweetId == parentTweet.mid &&
                    abs(comment.timestamp.timeIntervalSince(Date())) < 120 { // Within 2 minutes
                    print("[ReplyEditorView] Comment upload completed successfully")
                    // Toast is already shown immediately after submission, no need to show again
                } else {
                    print("[ReplyEditorView] Comment rejected - authorId: \(comment.authorId == hproseInstance.appUser.mid), parentTweetId: \(parentTweetId == parentTweet.mid), timeDiff: \(abs(comment.timestamp.timeIntervalSince(Date())) < 120)")
                }
            } else {
                print("[ReplyEditorView] Failed to extract comment or parentTweetId from notification")
            }
        }
        .overlay(
            Group {
                if showToast {
                    VStack {
                        Spacer()
                        ToastView(
                            message: toastMessage,
                            type: toastType
                        )
                        .padding(.horizontal, 20)
                        Spacer()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )
        .onReceive(NotificationCenter.default.publisher(for: .errorOccurred)) { notification in
            if let error = notification.object as? Error {
                showToastMessage(error.localizedDescription, type: .error)
            }
        }
        
    }
    
    private var collapsedView: some View {
        Button(action: {
            isExpanded = true
        }) {
            HStack(spacing: 12) {
                // User avatar
                Avatar(user: hproseInstance.appUser, size: 32)
                
                // Placeholder text with background
                HStack {
                    Text(NSLocalizedString("Post your reply...", comment: "Reply placeholder text"))
                        .foregroundColor(.secondary)
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemGray6).opacity(0.8))
                )
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var expandedView: some View {
        VStack(spacing: 12) {
            // User profile section
            HStack(alignment: .top, spacing: 8) {
                // User avatar
                Avatar(user: hproseInstance.appUser)
                    .frame(width: 40, height: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Username and handle
                    HStack {
                        Text(hproseInstance.appUser.name ?? hproseInstance.appUser.username ?? "")
                            .font(.headline)
                            .fontWeight(.bold)
                        Spacer()
                        
                        // Close button
                        Button(action: {
                            handleCloseAttempt()
                        }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                    }
                    
                    // Handle
                    Text("@\(hproseInstance.appUser.username ?? "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Reply context
                    Text("Reply to @\(parentTweet.author?.username ?? "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Text input area
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray))
                    .frame(minHeight: 80)
                
                if replyText.isEmpty {
                    Text(NSLocalizedString("Post your reply...", comment: "Reply placeholder text"))
                        .foregroundColor(.secondary)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
                
                TextEditor(text: $replyText)
                    .focused($isTextFieldFocused)
                    .padding(.horizontal, 1)
                    .padding(.vertical, 1)
                    .background(Color.clear)
                    .frame(minHeight: 80, maxHeight: 200) // Max height for ~8 lines
                    .cornerRadius(8)
            }
            
            // Display previews for attached media
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
            
            // Action buttons bar
            HStack {
                // Left side - media attachment options
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
                
                // Character counter (optional)
                if !replyText.isEmpty {
                    Text("\(replyText.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Reply button
                Button(NSLocalizedString("Reply", comment: "Reply button text")) {
                    // Capture the data before dismissing
                    let replyText = replyText
                    let selectedItems = selectedItems
                    let selectedImages = selectedImages
                    let selectedVideos = selectedVideos
                    
                    // Send notification for toast on presenting screen and clear immediately
                    NotificationCenter.default.post(
                        name: .tweetSubmitted,
                        object: nil,
                        userInfo: ["message": NSLocalizedString("Reply submitted", comment: "Reply submitted message")]
                    )
                    clearAndClose()
                    
                    // Submit reply in background after dismissing using captured data
                    Task {
                        await submitReplyInBackground(
                            text: replyText,
                            selectedItems: selectedItems,
                            selectedImages: selectedImages,
                            selectedVideos: selectedVideos
                        )
                    }
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(canSubmit ? Color.blue : Color.gray)
                )
                .disabled(!canSubmit)
            }
            
            // Error display
            if let error = error {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .onAppear {
                        // Auto-dismiss error after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self.error = nil
                        }
                    }
            }
        }
        .padding(12)
        .onAppear {
            // Auto-focus when expanded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
    
    private var canSubmit: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty || !selectedVideos.isEmpty
    }
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Auto-hide toast after appropriate duration
        let duration: TimeInterval = type == .success ? 2.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation { showToast = false }
        }
    }
    
    private func hasUnsavedContent() -> Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty || !selectedVideos.isEmpty
    }
    
    private func handleCloseAttempt() {
        if hasUnsavedContent() {
            showExitConfirmation = true
        } else {
            clearAndClose()
        }
    }
    
    private func clearAndClose() {
        replyText = ""
        selectedImages.removeAll()
        selectedItems.removeAll()
        selectedVideos.removeAll()
        isExpanded = false
        showExitConfirmation = false
        isTextFieldFocused = false
        error = nil
        onExpandedClose?()
        // Don't call onClose() here - we want to keep the collapsed view visible
    }
    
    private func submitReplyInBackground(
        text: String,
        selectedItems: [PhotosPickerItem],
        selectedImages: [UIImage],
        selectedVideos: [URL]
    ) async {
        let trimmedContent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: text,
            selectedItems: selectedItems,
            selectedImages: selectedImages,
            selectedVideos: selectedVideos
        ) else {
            print("DEBUG: Reply validation failed - empty content and no attachments")
            return
        }
        
        // Create comment tweet
        let comment = Tweet(
            mid: UUID().uuidString, // Temporary ID, will be replaced by server
            authorId: hproseInstance.appUser.mid,
            content: trimmedContent,
            timestamp: Date(),
            originalTweetId: isQuoting ? parentTweet.mid : nil,
            originalAuthorId: isQuoting ? parentTweet.authorId : nil
        )
        
        do {
            // Prepare item data for background upload using helper
            let itemData = try await MediaUploadHelper.prepareItemData(
                selectedItems: selectedItems,
                selectedImages: selectedImages,
                selectedVideos: selectedVideos
            )
            
            // Schedule comment upload in background (same as CommentComposeView)
            hproseInstance.scheduleCommentUpload(comment: comment, to: parentTweet, itemData: itemData)
            
            print("DEBUG: Reply scheduled for upload with \(itemData.count) attachments")
        } catch {
            print("DEBUG: Error preparing reply item data: \(error)")
        }
    }
    
}

#Preview {
    ReplyEditorView(parentTweet: Tweet(mid: "test", authorId: "test"), isQuoting: false)
        .environmentObject(HproseInstance.shared)
}
