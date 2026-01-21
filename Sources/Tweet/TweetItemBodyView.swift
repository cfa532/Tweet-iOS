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
struct TweetItemBodyView: View {
    @ObservedObject var tweet: Tweet
    var enableTap: Bool = false
    var isVisible: Bool = true
    var isEmbedded: Bool = false // Flag to indicate this is an embedded tweet (prevents video loading)
    var sourceTweetId: String? = nil // ID of tweet user is viewing (retweet ID for retweets)
    var onTweetBodyTap: (() -> Void)? = nil // Callback to navigate to tweet detail
    @State private var showLoginSheet = false
    @State private var isTruncated = false
    @State private var truncationTask: Task<Void, Never>? = nil
    @State private var hasCheckedTruncation = false // Track if we've already checked
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    // Cache screen dimensions to avoid repeated UIScreen.main calls
    private static let cachedGridWidth: CGFloat = {
        let screenWidth = UIScreen.main.bounds.width
        return max(10, screenWidth - 32)
    }()
    
    // MARK: - Optimized Truncation Detection with Caching
    
    /// Fast heuristic check before expensive calculation
    /// Estimates if text might be truncated based on character count
    private func quickTruncationEstimate(text: String, maxLines: Int) -> Bool? {
        // Rough estimate: ~40 characters per line for typical font sizes
        let estimatedCharsPerLine = 40
        let estimatedMaxChars = estimatedCharsPerLine * maxLines
        
        // If text is much shorter, definitely not truncated
        if text.count < estimatedMaxChars / 2 {
            return false
        }
        
        // If text is much longer, probably truncated
        if text.count > estimatedMaxChars * 2 {
            return true
        }
        
        // Unclear - need precise calculation
        return nil
    }
    
    /// Calculate if text will be truncated at given line limit
    /// OPTIMIZED: Uses fast heuristic first, caches result
    private func checkTextTruncation(text: String, maxLines: Int) async -> Bool {
        // Try quick estimate first
        if let estimate = quickTruncationEstimate(text: text, maxLines: maxLines) {
            return estimate
        }
        
        // Fall back to precise calculation only if needed
        // Use the same width as the text view (screen width - padding)
        let availableWidth = UIScreen.main.bounds.width - 32 // Match frame padding
        
        // Use UIFont that matches SwiftUI's .body font
        let font = UIFont.preferredFont(forTextStyle: .body)
        
        // Calculate the size for limited lines first (cheaper)
        let lineHeight = font.lineHeight
        let maxHeight = lineHeight * CGFloat(maxLines)
        
        // Create NSAttributedString with the font
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        
        // OPTIMIZATION: Use smaller constraint size for faster calculation
        let constraintSize = CGSize(width: availableWidth, height: maxHeight * 1.5)
        
        let boundingRect = attributedString.boundingRect(
            with: constraintSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        
        // If the full text height exceeds the max height, it's truncated
        return boundingRect.height > maxHeight
    }

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
                    .lineLimit(7)
                    .if(enableTap) { $0.contentShape(Rectangle()) }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                    .if(onTweetBodyTap != nil) { view in
                        view.onTapGesture {
                            // Tap to open tweet detail
                            onTweetBodyTap?()
                        }
                    }
                    .task(id: content) {
                        // OPTIMIZATION: Only check truncation once per content
                        guard !hasCheckedTruncation else { return }
                        
                        // Cancel previous task if content changed
                        truncationTask?.cancel()
                        
                        // Calculate truncation off main thread with low priority
                        truncationTask = Task.detached(priority: .low) {
                            let truncated = await checkTextTruncation(text: content, maxLines: 7)
                            
                            // Check if task was cancelled
                            guard !Task.isCancelled else { return }
                            
                            // Update UI on main thread
                            await MainActor.run {
                                isTruncated = truncated
                                hasCheckedTruncation = true
                            }
                        }
                    }
                    .onDisappear {
                        // Reset check flag when view disappears to allow recalculation if needed
                        hasCheckedTruncation = false
                        truncationTask?.cancel()
                    }
                
                if isTruncated && onTweetBodyTap != nil {
                    Button(action: { 
                        // Navigate to detail view
                        onTweetBodyTap?()
                    }) {
                        Text(LocalizedStringKey("More..."))
                            .font(.body)
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
