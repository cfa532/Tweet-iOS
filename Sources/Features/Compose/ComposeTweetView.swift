import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct ComposeTweetView: View {
    @StateObject private var viewModel = ComposeTweetViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool
    @State private var shouldFocus = false
    @State private var showMediaPicker = false
    
    private let hproseInstance = HproseInstance.shared
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $viewModel.tweetContent)
                    .frame(maxHeight: .infinity)
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
                
                // Attachment toolbar
                HStack(spacing: 20) {
                    PhotosPicker(selection: $viewModel.selectedItems,
                               matching: .any(of: [.images, .videos])) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { /* TODO: Add poll */ }) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { /* TODO: Add location */ }) {
                        Image(systemName: "location")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text("\(max(0, Constants.MAX_TWEET_SIZE - viewModel.tweetContent.count))")
                        .foregroundColor(viewModel.tweetContent.count > Constants.MAX_TWEET_SIZE ? .red : .gray)
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
                            await viewModel.postTweet()
                            dismiss()
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
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}

@available(iOS 16.0, *)
struct ThumbnailView: View {
    let item: PhotosPickerItem
    @State private var image: Image?
    
    var body: some View {
        Group {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
            }
        }
        .task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                image = Image(uiImage: uiImage)
            }
        }
    }
}

#Preview {
    if #available(iOS 16.0, *) {
        ComposeTweetView()
    } else {
        // Fallback on earlier versions
    }
} 
