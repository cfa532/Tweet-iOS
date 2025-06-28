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
                        if !viewModel.selectedItems.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(viewModel.selectedItems.enumerated()), id: \.offset) { index, item in
                                        ThumbnailView(item: item)
                                            .frame(width: 100, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                Button(action: {
                                                    viewModel.selectedItems.removeAll { $0.itemIdentifier == item.itemIdentifier }
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
                            PhotosPicker(selection: $viewModel.selectedItems,
                                       matching: .any(of: [.images, .videos])) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 20))
                                    .foregroundColor(.themeAccent)
                            }
                            .buttonStyle(.plain)
                            
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
                    Button("Tweet") {
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
