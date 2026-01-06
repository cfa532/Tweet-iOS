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
    var isEmbedded: Bool = false // Flag to indicate this is an embedded tweet (prevents video loading)
    var sourceTweetId: String? = nil // ID of tweet user is viewing (retweet ID for retweets)
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
            // Separate media and documents
            if let attachments = tweet.attachments, !attachments.isEmpty {
                // Filter attachments into media (visual) and documents
                let mediaAttachments = attachments.filter { isMediaType($0.type) }
                let documentAttachments = attachments.filter { isDocumentType($0.type) }
                
                VStack(alignment: .leading, spacing: 0) {
                    // MediaGrid for images, videos, and audio (visual content)
                    if !mediaAttachments.isEmpty {
                        MediaGridView(
                            parentTweet: tweet,
                            attachments: mediaAttachments,
                            isEmbedded: isEmbedded,
                            sourceTweetId: sourceTweetId  // Pass the viewing context tweet ID
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .cornerRadius(8)
                            .id("\(tweet.mid)_grid_\(isEmbedded ? "embedded" : "regular")")
                            .padding(.top, 4)
                            // STABILITY: Layout priority ensures media grid maintains consistent sizing
                            .layoutPriority(1)
                            // STABILITY: Fixed vertical size prevents content from shifting media position
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if let caption = singleVideoCaption(for: mediaAttachments) {
                            Text(caption)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.primary.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    
                    // Document attachments vertically (below media) - limit to 2 in list
                    if !documentAttachments.isEmpty {
                        DocumentAttachmentsView(
                            parentTweet: tweet,
                            documents: documentAttachments,
                            maxDocuments: 2 // Show at most 2 documents in tweet list
                        )
                        .padding(.top, mediaAttachments.isEmpty ? 4 : 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
    }
    
    // MARK: - Helper Functions
    
    /// Determines if a media type is visual content (should be in MediaGrid)
    private func isMediaType(_ type: MediaType) -> Bool {
        switch type {
        case .image, .video, .hls_video, .audio:
            return true
        default:
            return false
        }
    }
    
    /// Determines if a media type is a document (should be in DocumentAttachmentsView)
    private func isDocumentType(_ type: MediaType) -> Bool {
        switch type {
        case .pdf, .word, .excel, .ppt, .zip, .txt, .html, .unknown:
            return true
        default:
            return false
        }
    }
}
