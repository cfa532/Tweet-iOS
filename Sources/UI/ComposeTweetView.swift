import SwiftUI

struct ComposeTweetView: View {
    @State private var tweetContent = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $tweetContent)
                    .frame(maxHeight: .infinity)
                    .padding()
                
                HStack {
                    Button(action: {}) {
                        Image(systemName: "chart.bar")
                    }
                    
                    Button(action: {}) {
                        Image(systemName: "location")
                    }
                    
                    Spacer()
                    
                    Text("\(280 - tweetContent.count)")
                        .foregroundColor(tweetContent.count > 280 ? .red : .gray)
                }
                .padding()
            }
            .navigationTitle("New Tweet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Tweet") {
                        // Post tweet functionality would go here
                        dismiss()
                    }
                    .disabled(tweetContent.isEmpty || tweetContent.count > 280)
                }
            }
            #endif
        }
    }
}