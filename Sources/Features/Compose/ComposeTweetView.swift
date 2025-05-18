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
                    
                    Text("\(max(0, 280 - viewModel.tweetContent.count))")
                        .foregroundColor(viewModel.tweetContent.count > 280 ? .red : .gray)
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
                    .disabled(viewModel.tweetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.tweetContent.count > 280)
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

#Preview {
    if #available(iOS 16.0, *) {
        ComposeTweetView()
    } else {
        // Fallback on earlier versions
    }
} 
