import SwiftUI

struct ComposeTweetView: View {
    @StateObject private var viewModel = ComposeTweetViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $viewModel.tweetContent)
                    .frame(maxHeight: .infinity)
                    .padding()
                
                HStack {
                    Button(action: { viewModel.showPollCreation = true }) {
                        Image(systemName: "chart.bar")
                    }
                    
                    Button(action: { viewModel.showLocationPicker = true }) {
                        Image(systemName: "location")
                    }
                    
                    Spacer()
                    
                    Text("\(280 - viewModel.tweetContent.count)")
                        .foregroundColor(viewModel.tweetContent.count > 280 ? .red : .gray)
                }
                .padding()
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
                    .disabled(viewModel.tweetContent.isEmpty || viewModel.tweetContent.count > 280)
                }
            }
            .sheet(isPresented: $viewModel.showPollCreation) {
                PollCreationView()
            }
            .sheet(isPresented: $viewModel.showLocationPicker) {
                LocationPickerView()
            }
        }
    }
} 