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
            ComposeTweetContentView(
                viewModel: viewModel,
                isEditorFocused: _isEditorFocused,
                dismiss: dismiss
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.content.count > 0)
    }
}

@available(iOS 16.0, *)
private struct ComposeTweetContentView: View {
    @ObservedObject var viewModel: ComposeTweetViewModel
    @FocusState var isEditorFocused: Bool
    let dismiss: DismissAction
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.content)
                    .frame(maxHeight: .infinity)
                    .padding()
                    .focused($isEditorFocused)
                    .background(Color(.systemBackground))
                    .onTapGesture {
                        isEditorFocused = true
                    }
                
                if !viewModel.selectedItems.isEmpty {
                    ThumbnailsView(viewModel: viewModel)
                }
                
                AttachmentToolbar(viewModel: viewModel)
            }
            
            if viewModel.showToast {
                ToastOverlay(message: viewModel.toastMessage)
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
                    Task {
                        await viewModel.uploadTweet()
                        dismiss()
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

@available(iOS 16.0, *)
private struct ThumbnailsView: View {
    @ObservedObject var viewModel: ComposeTweetViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.selectedItems, id: \.itemIdentifier) { item in
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
}

@available(iOS 16.0, *)
private struct AttachmentToolbar: View {
    @ObservedObject var viewModel: ComposeTweetViewModel
    
    var body: some View {
        HStack(spacing: 20) {
            PhotosPicker(selection: $viewModel.selectedItems,
                       matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("\(max(0, Constants.MAX_TWEET_SIZE - viewModel.content.count))")
                .foregroundColor(viewModel.content.count > Constants.MAX_TWEET_SIZE ? .red : .gray)
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
}

@available(iOS 16.0, *)
private struct ToastOverlay: View {
    let message: String
    
    var body: some View {
        VStack {
            Spacer()
            ToastView(message: message, type: .error)
                .padding(.bottom, 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
