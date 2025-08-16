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
    @State private var isSubmitting = false
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
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
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
       .sheet(isPresented: $showCamera) {
           CameraView { image in
               if let image = image {
                   selectedImages.append(image)
               }
           }
       }
               .sheet(isPresented: $showImagePicker) {
           PhotosPicker("Select Media", selection: $selectedItems, matching: .any(of: [.images, .videos]))
       }
               .onAppear {
            // Set initial expanded state if requested
            if initialExpanded {
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
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showToast)
        )

    }
    
    private var collapsedView: some View {
        Button(action: {
            isExpanded = true
        }) {
            HStack(spacing: 12) {
                // User avatar
                Avatar(user: hproseInstance.appUser)
                    .frame(width: 24, height: 24)
                
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
                        .fill(Color(.systemGray6))
                )
                

            }
            .padding(.vertical, 8)
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
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemGray6))
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.clear)
                    .frame(minHeight: 80)
            }
            
            // Display previews for attached media
            MediaPreviewGrid(
                selectedItems: selectedItems,
                selectedImages: selectedImages,
                onRemoveItem: { index in
                    selectedItems.remove(at: index)
                },
                onRemoveImage: { index in
                    selectedImages.remove(at: index)
                }
            )
            
            // Action buttons bar
            HStack {
                // Left side - media attachment options
                MediaPicker(
                    selectedItems: $selectedItems,
                    selectedImages: $selectedImages,
                    showCamera: $showCamera,
                    error: $error,
                    maxSelectionCount: 4,
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
                DebounceButton(
                    cooldownDuration: 0.5,
                    enableAnimation: true,
                    enableVibration: false
                ) {
                    submitReply()
                } label: {
                    Text(NSLocalizedString("Reply", comment: "Reply button text"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(canSubmit ? Color.blue : Color.gray)
                        )
                }
                .disabled(!canSubmit || isSubmitting)
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
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty
    }
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Auto-hide toast after appropriate duration
        let duration: TimeInterval = type == .success ? 2.0 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation { showToast = false }
        }
    }
    
    private func hasUnsavedContent() -> Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty
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
        isExpanded = false
        showExitConfirmation = false
        isTextFieldFocused = false
        error = nil
        onExpandedClose?()
        // Don't call onClose() here - we want to keep the collapsed view visible
    }
    

    
    private func submitReply() {
        let trimmedContent = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Allow empty content if there are attachments
        guard MediaUploadHelper.validateContent(
            content: replyText,
            selectedItems: selectedItems,
            selectedImages: selectedImages
        ) else {
            print("DEBUG: Reply validation failed - empty content and no attachments")
            showToastMessage(NSLocalizedString("Comment cannot be empty.", comment: "Empty comment error"), type: .error)
            return
        }
        
        isSubmitting = true
        
        Task {
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
                    selectedImages: selectedImages
                )
                
                // Schedule comment upload in background (same as CommentComposeView)
                hproseInstance.scheduleCommentUpload(comment: comment, to: parentTweet, itemData: itemData)
                
                // Show success toast immediately and close view after delay
                await MainActor.run {
                    clearAndClose()
                    isSubmitting = false
                    
                    // Show success toast immediately
                    showToastMessage(NSLocalizedString("Comment published successfully", comment: "Comment published success message"), type: .success)
                    
                    // Close the view after a delay to allow toast to be seen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        onClose?()
                    }
                }
            } catch {
                await MainActor.run {
                    showToastMessage(NSLocalizedString("Failed to upload comment. Please try again.", comment: "Comment upload failed error"), type: .error)
                    isSubmitting = false
                }
            }
        }
    }
}

#Preview {
    ReplyEditorView(parentTweet: Tweet(mid: "test", authorId: "test"), isQuoting: false)
        .environmentObject(HproseInstance.shared)
}
