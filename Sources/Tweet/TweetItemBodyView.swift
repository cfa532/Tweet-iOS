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
    @State private var isExpanded = false
    @State private var showLoginSheet = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    // Helper for grid aspect ratio
    func gridAspect(for attachments: [MimeiFileType]) -> CGFloat {
        let count = attachments.count
        let allPortrait = attachments.allSatisfy { ($0.aspectRatio ?? 1) < 1 }
        let allLandscape = attachments.allSatisfy { ($0.aspectRatio ?? 1) > 1 }
        switch count {
        case 1:
            if let ar = attachments[0].aspectRatio, ar > 0 {
                return CGFloat(ar) // Use actual aspect ratio
            } else {
                return 1.0 // Square when no aspect ratio is available
            }
        case 2:
            if allPortrait { return 4.0/3.0 }
            else if allLandscape { return 3.0/4.0 }
            else { return 1.0 }
        case 3:
            if allPortrait { return 4.0/3.0 }
            else if allLandscape { return 3.0/4.0 }
            else { return 1.0 }
        case 4:
            return 1.0
        default:
            return 1.0
        }
    }
    
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
            
            if let attachments = tweet.attachments, let baseUrl = tweet.author?.baseUrl {
                MediaGridView(attachments: attachments, baseUrl: baseUrl)
                    .aspectRatio(gridAspect(for: attachments), contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
    }
}
