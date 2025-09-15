import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct ComposeTweetView: View {
    @StateObject private var viewModel: ComposeTweetViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool
    @State private var shouldFocus = false
    @State private var showMediaPicker = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Convert PhotosPickerItem array to IdentifiablePhotosPickerItem array
    private var identifiableItems: [IdentifiablePhotosPickerItem] {
        viewModel.selectedItems.map { IdentifiablePhotosPickerItem(item: $0) }
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
            .navigationTitle(NSLocalizedString("New Tweet", comment: "New tweet screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                        viewModel.clearForm()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    DebounceButton(
                        NSLocalizedString("Publish", comment: "Publish tweet button"),
                        cooldownDuration: 1.0,
                        enableAnimation: true,
                        enableVibration: false
                    ) {
                        // Post tweet in background
                        Task {
                            await viewModel.postTweet()
                            
                            // Send notification for toast on presenting screen and dismiss immediately
                            await MainActor.run {
                                NotificationCenter.default.post(
                                    name: .tweetSubmitted,
                                    object: nil,
                                    userInfo: ["message": NSLocalizedString("Tweet submitted", comment: "Tweet submitted message")]
                                )
                                viewModel.clearForm()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.canPostTweet)
                }
            }
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
                    viewModel.toastMessage = error.localizedDescription
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
    }
    
    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                textEditor
                mediaPreview
                attachmentToolbar
            }
        }
    }
    
    private var textEditor: some View {
        TextEditor(text: $viewModel.tweetContent)
            .frame(minHeight: 150)
            .padding()
            .focused($isEditorFocused)
            .background(Color(.systemBackground))
            .onTapGesture {
                isEditorFocused = true
            }
    }
    
    private var mediaPreview: some View {
        MediaPreviewGrid(
            selectedItems: viewModel.selectedItems,
            onRemoveItem: { index in
                viewModel.selectedItems.remove(at: index)
            },
            onRemoveImage: { _ in }
        )
        .frame(height: viewModel.selectedItems.isEmpty ? 0 : 120)
        .background(Color(.systemBackground))
    }
    
    private var attachmentToolbar: some View {
        HStack(spacing: 20) {
            MediaPicker(
                selectedItems: $viewModel.selectedItems,
                showCamera: .constant(false),
                error: $viewModel.error,
                maxSelectionCount: 4,
                supportedTypes: [.image, .movie]
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
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.showToast)
            }
        }
    }
}
