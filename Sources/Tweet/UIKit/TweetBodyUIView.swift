//
//  TweetBodyUIView.swift
//  Tweet
//
//  Pure UIKit tweet body replacing SwiftUI TweetItemBodyView.
//  Shows text content and media grid.
//  Phase 3: Media grid uses pure UIKit MediaGridUIView (no UIHostingController).
//  Refactored to use internal UIStackView for robust, predictable layout.
//
import UIKit
import SwiftUI
import Combine

class TweetBodyUIView: UIView {

    // Internal stack view to manage all content
    private let contentStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .fill
        sv.spacing = 0
        return sv
    }()

    private let contentLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 7
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .label
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    // Video caption label (for single-video tweets with title)
    private let captionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .label.withAlphaComponent(0.6)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    // Pure UIKit media grid (Phase 3)
    let mediaGridView = MediaGridUIView()
    private var mediaContainerView: UIView = {
        let v = UIView()
        return v
    }()

    // Document attachments hosting (keeps SwiftUI — not in critical path)
    private var documentHostingController: UIHostingController<AnyView>?
    private let documentContainerView = UIView()

    // Height constraint for media (used for dynamic sizing)
    private var mediaHeightConstraint: NSLayoutConstraint?

    var onTweetBodyTap: (() -> Void)?
    /// Per-feed video coordinator (set by TweetCellContentView)
    weak var videoCoordinator: VideoPlaybackCoordinator?
    /// Whether the video caption label is currently visible (for single-video tweets with title)
    private(set) var isCaptionVisible: Bool = false
    private var currentTweetId: String?
    private weak var parentViewController: UIViewController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = .clear

        // Add media grid to its container (4pt trailing inset for right margin)
        mediaGridView.clipsToBounds = true
        mediaGridView.layer.cornerRadius = 8
        mediaContainerView.addSubview(mediaGridView)
        mediaGridView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mediaGridView.topAnchor.constraint(equalTo: mediaContainerView.topAnchor),
            mediaGridView.leadingAnchor.constraint(equalTo: mediaContainerView.leadingAnchor),
            mediaGridView.trailingAnchor.constraint(equalTo: mediaContainerView.trailingAnchor, constant: -2),
            mediaGridView.bottomAnchor.constraint(equalTo: mediaContainerView.bottomAnchor),
        ])

        // Build content stack: [contentLabel, mediaContainer, captionLabel, documentContainer]
        contentStack.addArrangedSubview(contentLabel)
        contentStack.addArrangedSubview(mediaContainerView)
        contentStack.addArrangedSubview(captionLabel)
        contentStack.addArrangedSubview(documentContainerView)

        // Set initial spacing (will be adjusted per tweet)
        contentStack.setCustomSpacing(4, after: contentLabel)  // text → media gap
        contentStack.setCustomSpacing(2, after: mediaContainerView)  // media → caption gap
        contentStack.setCustomSpacing(0, after: captionLabel)  // caption → documents gap

        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Anchor stack to edges with 2pt top padding
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Media height constraint (will be set dynamically)
        mediaHeightConstraint = mediaContainerView.heightAnchor.constraint(equalToConstant: 0)
        mediaHeightConstraint?.priority = UILayoutPriority(999)
        mediaHeightConstraint?.isActive = true

        // Tap gesture on content label
        let tap = UITapGestureRecognizer(target: self, action: #selector(bodyTapped))
        contentLabel.addGestureRecognizer(tap)
        contentLabel.isUserInteractionEnabled = true
    }

    @objc private func bodyTapped() {
        onTweetBodyTap?()
    }

    func configure(tweet: Tweet, isEmbedded: Bool, cellTweetId: String?,
                   parentViewController: UIViewController) {
        self.parentViewController = parentViewController

        // Skip if same tweet
        if currentTweetId == tweet.mid { return }
        currentTweetId = tweet.mid

        // Clean up media grid and document hosting
        mediaGridView.prepareForReuse()
        removeDocumentHosting()

        // --- Text content ---
        if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Compute available text width (must match deterministic height calculator)
            let screenWidth = UIScreen.main.bounds.width
            let textWidth: CGFloat
            if isEmbedded {
                // screenWidth - cellPad(16) - leading(3) - avatar(42) - spacing(4) - embPad(16) - embAvatar(40) - embSpacing(8)
                textWidth = screenWidth - 129
            } else {
                // screenWidth - cellPad(16) - leading(3) - avatar(42) - spacing(4)
                textWidth = screenWidth - 65
            }
            if let cached = tweet.cachedContentAttributedString,
               tweet.cachedContentWidth == textWidth {
                contentLabel.attributedText = cached
            } else {
                let attrString = Self.makeContentAttributedString(content: content, availableWidth: textWidth)
                tweet.cachedContentAttributedString = attrString
                tweet.cachedContentWidth = textWidth
                contentLabel.attributedText = attrString
            }
            contentLabel.isHidden = false
        } else {
            contentLabel.attributedText = nil
            contentLabel.isHidden = true
        }

        // --- Attachments ---
        let mediaAttachments = tweet.attachments?.filter { Self.isMediaType($0.type) } ?? []
        let documentAttachments = tweet.attachments?.filter { Self.isDocumentType($0.type) } ?? []
        let hasMedia = !mediaAttachments.isEmpty
        let hasDocuments = !documentAttachments.isEmpty

        // --- Media grid ---
        if hasMedia {
            // Calculate actual available width based on context
            let screenWidth = UIScreen.main.bounds.width
            let gridWidth: CGFloat
            if isEmbedded {
                // Embedded: cell padding (32+32) + embedded container (8+4) + avatar (40) + spacing (8) = 124
                gridWidth = max(10, screenWidth - 124)
            } else {
                // Regular: cell padding (32+32) + media trailing inset (2) = 66
                gridWidth = max(10, screenWidth - 66)
            }

            let mediaHeight = MediaGridViewModel.calculateHeight(for: mediaAttachments, gridWidth: gridWidth)
            mediaHeightConstraint?.constant = mediaHeight
            mediaContainerView.isHidden = false

            // Configure pure UIKit media grid
            mediaGridView.videoCoordinator = videoCoordinator
            mediaGridView.configure(
                tweet: tweet,
                attachments: mediaAttachments,
                isEmbedded: isEmbedded,
                cellTweetId: cellTweetId,
                shouldLoadVideo: true,
                parentViewController: parentViewController
            )

            // Caption for single video
            let caption = singleVideoCaption(tweet: tweet, attachments: mediaAttachments)
            if let caption {
                captionLabel.text = caption
                captionLabel.isHidden = false
                isCaptionVisible = true
            } else {
                captionLabel.isHidden = true
                captionLabel.text = nil
                isCaptionVisible = false
            }

            // Adjust spacing based on whether there's text above media
            if contentLabel.isHidden {
                // No text: reduce spacing before media (media starts at 2pt from top)
                contentStack.setCustomSpacing(0, after: contentLabel)
            } else {
                // Text present: 4pt gap
                contentStack.setCustomSpacing(4, after: contentLabel)
            }
        } else {
            mediaContainerView.isHidden = true
            mediaHeightConstraint?.constant = 0
            captionLabel.isHidden = true
            isCaptionVisible = false

            // Collapse spacing after content label if no media
            contentStack.setCustomSpacing(0, after: contentLabel)
        }

        // --- Documents ---
        if hasDocuments {
            documentContainerView.isHidden = false

            // Host SwiftUI DocumentAttachmentsView (not in critical scroll path)
            let docView = DocumentAttachmentsView(
                parentTweet: tweet,
                documents: documentAttachments,
                maxDocuments: 2
            )
            let hostingController = UIHostingController(rootView: AnyView(docView))
            hostingController.view.backgroundColor = .clear
            hostingController.view.insetsLayoutMarginsFromSafeArea = false
            hostingController.sizingOptions = [.intrinsicContentSize]

            parentViewController.addChild(hostingController)
            documentContainerView.addSubview(hostingController.view)
            hostingController.didMove(toParent: parentViewController)

            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingController.view.topAnchor.constraint(equalTo: documentContainerView.topAnchor),
                hostingController.view.leadingAnchor.constraint(equalTo: documentContainerView.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: documentContainerView.trailingAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: documentContainerView.bottomAnchor),
            ])

            documentHostingController = hostingController

            // Add spacing before documents if there's media or text
            if hasMedia || !contentLabel.isHidden {
                contentStack.setCustomSpacing(8, after: captionLabel.isHidden ? mediaContainerView : captionLabel)
            }
        } else {
            documentContainerView.isHidden = true
        }
    }

    func prepareForReuse() {
        currentTweetId = nil
        contentLabel.attributedText = nil
        captionLabel.text = nil
        captionLabel.isHidden = true
        isCaptionVisible = false
        onTweetBodyTap = nil
        mediaGridView.prepareForReuse()
        removeDocumentHosting()

        // Reset spacing to defaults
        contentStack.setCustomSpacing(4, after: contentLabel)
        contentStack.setCustomSpacing(2, after: mediaContainerView)
        contentStack.setCustomSpacing(0, after: captionLabel)
    }

    private func removeDocumentHosting() {
        if let hc = documentHostingController {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            documentHostingController = nil
        }
    }

    // MARK: - Helpers

    private func singleVideoCaption(tweet: Tweet, attachments: [MimeiFileType]) -> String? {
        guard attachments.count == 1 else { return nil }
        let attachment = attachments[0]
        guard attachment.type == .video || attachment.type == .hls_video else { return nil }

        if let rawTitle = tweet.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTitle.isEmpty {
            return rawTitle
        }

        if let rawFileName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawFileName.isEmpty {
            let components = rawFileName.split(separator: ".")
            if components.count > 1 {
                return components.dropLast().joined(separator: ".")
            }
            return rawFileName
        }

        return nil
    }

    static func isMediaType(_ type: MediaType) -> Bool {
        switch type {
        case .image, .video, .hls_video, .audio:
            return true
        default:
            return false
        }
    }

    static func isDocumentType(_ type: MediaType) -> Bool {
        switch type {
        case .pdf, .word, .excel, .ppt, .zip, .txt, .html, .unknown:
            return true
        default:
            return false
        }
    }

    // MARK: - Truncation with "More>>" indicator

    static let contentFont = UIFont.systemFont(ofSize: 16)
    static let maxContentLines = 7

    /// Shared UILabel for truncation detection — matches UILabel's TextKit2 rendering.
    /// NSLayoutManager (TextKit1) and UILabel (TextKit2) can disagree on line breaking,
    /// so we trust UILabel since that's what actually renders the text in cells.
    private static let truncationCheckLabel: UILabel = {
        let label = UILabel()
        label.font = contentFont
        return label
    }()

    /// Build attributed text. If text exceeds maxContentLines, truncate and append accent-colored " More>>".
    static func makeContentAttributedString(content: String, availableWidth: CGFloat) -> NSAttributedString {
        let font = contentFont
        let maxLines = maxContentLines

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1
        paragraphStyle.lineBreakMode = .byWordWrapping

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]

        // Use UILabel to detect whether text actually exceeds maxLines.
        // NSLayoutManager (TextKit1) and UILabel (TextKit2) can disagree on line breaking,
        // so we trust UILabel since that's what renders the text.
        let checkLabel = truncationCheckLabel
        let attrText = NSAttributedString(string: content, attributes: textAttributes)
        checkLabel.attributedText = attrText
        let fitSize = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)

        checkLabel.numberOfLines = 0
        let fullHeight = checkLabel.sizeThatFits(fitSize).height
        checkLabel.numberOfLines = maxLines
        let clampedHeight = checkLabel.sizeThatFits(fitSize).height

        let needsTruncation = fullHeight > clampedHeight + 1 // 1pt tolerance

        // No truncation needed — return plain text
        guard needsTruncation else {
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 1
            ps.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: content, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: ps
            ])
        }

        // UILabel says truncation is needed — use TextKit to find the truncation point
        let textStorage = NSTextStorage(string: content, attributes: textAttributes)
        let textContainer = NSTextContainer(size: CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        // Collect glyph ranges per line
        var lineGlyphRanges: [NSRange] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            lineGlyphRanges.append(lineRange)
            glyphIndex = NSMaxRange(lineRange)
        }

        // Edge case: UILabel says truncation needed but NSLayoutManager disagrees.
        // Return plain text — UILabel will naturally truncate via numberOfLines=7.
        guard lineGlyphRanges.count > maxLines else {
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 1
            ps.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: content, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: ps
            ])
        }

        // Text is truncated — find character range visible in maxLines
        let lastLineGlyphRange = lineGlyphRanges[maxLines - 1]
        let lastLineCharRange = layoutManager.characterRange(forGlyphRange: lastLineGlyphRange, actualGlyphRange: nil)
        let lastLineStart = lastLineCharRange.location

        // Measure localized "More..." suffix width to know how much room to reserve
        let moreString = " " + NSLocalizedString("More...", comment: "")
        let moreWidth = NSAttributedString(string: moreString, attributes: [.font: font]).size().width
        let targetWidth = availableWidth - moreWidth - 2 // 2px safety margin

        // Binary search for the longest substring that fits within targetWidth
        var lo = lastLineStart
        var hi = NSMaxRange(lastLineCharRange)
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            let lastLineText = (content as NSString).substring(with: NSRange(location: lastLineStart, length: mid - lastLineStart))
            let lineWidth = NSAttributedString(string: lastLineText, attributes: [.font: font]).size().width
            if lineWidth <= targetWidth {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        let trimEnd = lo

        // Build body text: everything up to trimEnd, strip trailing whitespace
        var bodyText = (content as NSString).substring(to: trimEnd)
        while bodyText.hasSuffix(" ") || bodyText.hasSuffix("\n") || bodyText.hasSuffix("\r") {
            bodyText = String(bodyText.dropLast())
        }

        // Build final attributed string
        let bodyPs = NSMutableParagraphStyle()
        bodyPs.lineSpacing = 1
        bodyPs.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(string: bodyText, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: bodyPs
        ])
        result.append(NSAttributedString(string: moreString, attributes: [
            .font: font,
            .foregroundColor: UIColor.systemBlue,
        ]))

        return result
    }
}
