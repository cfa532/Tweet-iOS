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
    var visibleTweetId: String? = nil // The ID of the visible tweet in feed (for retweets)
    var isEmbedded: Bool = false // Flag to indicate this is an embedded tweet (prevents video loading)
    @State private var isExpanded = false
    @State private var showLoginSheet = false
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Cache screen dimensions to avoid repeated UIScreen.main calls
    private static let cachedGridWidth: CGFloat = {
        let screenWidth = UIScreen.main.bounds.width
        return max(10, screenWidth - 32)
    }()

    /// Caption text for a single-video media grid: prefers tweet title, falls back to video file name (without extension)
    private func singleVideoCaption(for attachments: [MimeiFileType]) -> String? {
        guard attachments.count == 1 else { return nil }
        let attachment = attachments[0]
        
        // Only show caption for video / HLS video
        guard attachment.type == .video || attachment.type == .hls_video else { return nil }
        
        // Prefer tweet title if available
        if let rawTitle = tweet.title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTitle.isEmpty {
            return rawTitle
        }
        
        // Fallback to file name without extension
        if let rawFileName = attachment.fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawFileName.isEmpty {
            let components = rawFileName.split(separator: ".")
            if components.count > 1 {
                return components.dropLast().joined(separator: ".")
            } else {
                return rawFileName
            }
        }
        
        return nil
    }

    private func handleGuestAction() {
        if hproseInstance.appUser.isGuest {
            showLoginSheet = true
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isExpanded ? nil : 7)
                    .if(enableTap) { $0.contentShape(Rectangle()) }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                
                if content.count > 500 && !isExpanded {
                    Button(action: { isExpanded = true }) {
                        Text(LocalizedStringKey("Show more"))
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
            }
            // MediaGrid to show attachment previews.
            if let attachments = tweet.attachments, !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MediaGridView(
                        parentTweet: tweet,
                        attachments: attachments,
                        visibleTweetId: visibleTweetId ?? tweet.mid,
                        isEmbedded: isEmbedded
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .cornerRadius(8)
                        // Include visibleTweetId + embedded flag to avoid duplicate identities when the same
                        // original tweet is embedded in multiple retweets/quotes simultaneously.
                        .id("\(visibleTweetId ?? tweet.mid)_\(tweet.mid)_grid_\(isEmbedded ? "embedded" : "regular")")
                        .padding(.top, 4)
                    
                    if let caption = singleVideoCaption(for: attachments) {
                        Text(caption)
                            .font(.system(size: 14, weight: .regular)) // Use explicit size to control spacing
                            .foregroundColor(.primary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true) // Prevent extra vertical expansion
                            .padding(.top, 2)
                    }
                }
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
    }
}
