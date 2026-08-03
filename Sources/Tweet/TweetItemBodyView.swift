import SwiftUI
import UIKit

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
private struct FeedStyleTruncatedTextView: UIViewRepresentable {
    let content: String
    let onBodyTap: (() -> Void)?

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = TweetBodyUIView.maxContentLines
        label.lineBreakMode = .byTruncatingTail
        label.font = TweetBodyUIView.contentFont
        label.textColor = .label
        label.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        label.addGestureRecognizer(tap)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        context.coordinator.onBodyTap = onBodyTap
        let width = uiView.bounds.width > 0 ? uiView.bounds.width : UIScreen.main.bounds.width - 32
        uiView.attributedText = TweetBodyUIView.makeContentAttributedString(
            content: content,
            availableWidth: width
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 32
        uiView.attributedText = TweetBodyUIView.makeContentAttributedString(
            content: content,
            availableWidth: width
        )
        let fitSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitSize.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBodyTap: onBodyTap)
    }

    final class Coordinator: NSObject {
        var onBodyTap: (() -> Void)?

        init(onBodyTap: (() -> Void)?) {
            self.onBodyTap = onBodyTap
        }

        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let label = gesture.view as? UILabel else { return }
            let point = gesture.location(in: label)
            if let url = TweetBodyUIView.detectedURL(in: label, at: point) {
                TweetBodyUIView.openExternalURL(url)
                return
            }
            onBodyTap?()
        }
    }
}

@available(iOS 16.0, *)
struct TweetItemBodyView: View {
    @ObservedObject var tweet: Tweet
    var enableTap: Bool = false
    var isVisible: Bool = true
    var isEmbedded: Bool = false // Flag to indicate this is an embedded tweet (prevents video loading)
    var cellTweetId: String? = nil // ID of tweet user is viewing (retweet ID for retweets)
    var onTweetBodyTap: (() -> Void)? = nil // Callback to navigate to tweet detail
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
                FeedStyleTruncatedTextView(content: content, onBodyTap: onTweetBodyTap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .if(enableTap) { $0.contentShape(Rectangle()) }
                    .padding(.bottom, 2)
            }
            // Separate media and documents
            if let attachments = tweet.attachments, !attachments.isEmpty {
                // Filter attachments into audio, visual media, and documents
                let audioAttachments = attachments.filter { $0.type == .audio }
                let mediaAttachments = attachments.filter { isMediaType($0.type) }
                let documentAttachments = attachments.filter { isDocumentType($0.type) }
                
                VStack(alignment: .leading, spacing: 0) {
                    if !audioAttachments.isEmpty {
                        CompactAudioPlaylistPlayer(
                            parentTweet: tweet,
                            attachments: audioAttachments
                        )
                        .padding(.top, 6)
                    }

                    // MediaGrid for images and videos
                    if !mediaAttachments.isEmpty {
                        MediaGridView(
                            parentTweet: tweet,
                            attachments: mediaAttachments,
                            isEmbedded: isEmbedded,
                            cellTweetId: cellTweetId  // Pass the viewing context tweet ID
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .cornerRadius(8)
                            .id("\(tweet.mid)_grid_\(isEmbedded ? "embedded" : "regular")")
                            .padding(.top, audioAttachments.isEmpty ? 6 : 8)
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
                        .padding(.top, (mediaAttachments.isEmpty && audioAttachments.isEmpty) ? 4 : 8)
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
        case .image, .video, .hls_video:
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
