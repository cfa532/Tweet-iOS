import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct ComposeTweetView: View {
    @StateObject private var viewModel: ComposeTweetViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool
    @State private var shouldFocus = false
    @State private var showMediaPicker = false
    @State private var hproseInstance = HproseInstanceState.shared
    
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
                ScrollView {
                    VStack(spacing: 0) {
                        TextEditor(text: $viewModel.tweetContent)
                            .frame(minHeight: 150)
                            .padding()
                            .focused($isEditorFocused)
                            .background(Color(.systemBackground))
                            .onTapGesture {
                                isEditorFocused = true
                            }
                        
                        // Thumbnail preview section
                        MediaPreviewGrid(
                            selectedItems: viewModel.selectedItems,
                            onRemoveItem: { index in
                                viewModel.selectedItems.remove(at: index)
                            },
                            onRemoveImage: { _ in }
                        )
                        .frame(height: viewModel.selectedItems.isEmpty ? 0 : 120)
                        .background(Color(.systemBackground))
                        
                        // Attachment toolbar
                        HStack(spacing: 20) {
                            MediaPicker(
                                selectedItems: $viewModel.selectedItems,
                                showCamera: .constant(false),
                                error: .constant(nil),
                                maxSelectionCount: 4,
                                supportedTypes: [.image, .movie]
                            )
                            
                            Spacer()
                            
                            #if DEBUG
                            // Private toggle - only show on debug builds
                            HStack(spacing: 8) {
                                Image(systemName: "lock")
                                    .font(.system(size: 16))
                                    .foregroundColor(viewModel.isPrivate ? .themeAccent : .themeSecondaryText)
                                
                                Toggle(NSLocalizedString("Private", comment: "Private tweet toggle"), isOn: $viewModel.isPrivate)
                                    .toggleStyle(SwitchToggleStyle(tint: .themeAccent))
                                    .labelsHidden()
                            }
                            #endif
                            
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
                }
                
                // Error toast overlay (only for validation errors)
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
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.tweetContent.count > 0)
    }
}
