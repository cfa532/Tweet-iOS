import SwiftUI

// Conditional modifier extension
extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

@available(iOS 16.0, *)
struct TweetItemBodyView: View {
    @ObservedObject var tweet: Tweet
    var enableTap: Bool = false
    var isVisible: Bool = true
    var onItemTap: ((Int) -> Void)? = nil
    @State private var isExpanded = false
    @State private var showLoginSheet = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let content = tweet.content, !content.isEmpty {
                VStack(alignment: .leading) {
                    Text(content)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(isExpanded ? nil : 10)
                        .if(enableTap) { $0.contentShape(Rectangle()) }
                    if content.count > 500 && !isExpanded {
                        Button(action: { isExpanded = true }) {
                            Text("Show more")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            if let attachments = tweet.attachments, !attachments.isEmpty {
                let aspect = MediaGridViewModel.aspectRatio(for: attachments)
                MediaGridView(parentTweet: tweet, attachments: attachments, onItemTap: onItemTap)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
    }
}
