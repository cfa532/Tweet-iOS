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
                            
                            Button(action: { /* TODO: Add poll */ }) {
                                Image(systemName: "chart.bar")
                                    .font(.system(size: 20))
                                    .foregroundColor(.themeAccent)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { /* TODO: Add location */ }) {
                                Image(systemName: "location")
                                    .font(.system(size: 20))
                                    .foregroundColor(.themeAccent)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            // Private toggle
                            HStack(spacing: 8) {
                                Image(systemName: "lock")
                                    .font(.system(size: 16))
                                    .foregroundColor(viewModel.isPrivate ? .themeAccent : .themeSecondaryText)
                                
                                Toggle("Private", isOn: $viewModel.isPrivate)
                                    .toggleStyle(SwitchToggleStyle(tint: .themeAccent))
                                    .labelsHidden()
                            }
                            
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
                
                if viewModel.showToast {
                    VStack {
                        Spacer()
                        ToastView(message: viewModel.toastMessage, type: .error)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: viewModel.showToast)
                }
            }
            .navigationTitle("New Tweet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    DebounceButton(
                        "Tweet",
                        cooldownDuration: 0.5,
                        enableAnimation: true,
                        enableVibration: false
                    ) {
                        // Immediately dismiss the view and prevent repeated tapping
                        dismiss()
                        
                        // Set uploading state to prevent repeated taps
                        viewModel.isUploading = true
                        
                        // Post tweet in background
                        Task {
                            await viewModel.postTweet()
                        }
                    }
                    .disabled(!viewModel.canPostTweet || viewModel.isUploading)
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
