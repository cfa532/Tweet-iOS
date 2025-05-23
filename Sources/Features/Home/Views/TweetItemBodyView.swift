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
    @Binding var tweet: Tweet
    var retweet: (Tweet) async -> Void
    var embedded: Bool = false
    var enableTap: Bool = false
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let content = tweet.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
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
                // Calculate the aspect ratio for the grid
                let count = attachments.count
                let allPortrait = attachments.allSatisfy { ($0.aspectRatio ?? 1) < 1 }
                let allLandscape = attachments.allSatisfy { ($0.aspectRatio ?? 1) > 1 }
                let aspect: CGFloat = {
                    switch count {
                    case 1:
                        if (attachments[0].aspectRatio ?? 1) < 1 { return 4.0/3.0 }
                        else { return 3.0/4.0 }
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
                }()
                // Use the parent's width minus padding (16pt each side)
                let width = UIScreen.main.bounds.width - 32
                let height = width / aspect

                MediaGridView(attachments: attachments, baseUrl: baseUrl)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        Spacer(minLength: 12)
        if !embedded {
            TweetActionButtonsView(tweet: $tweet, retweet: retweet)
        }
    }
}
