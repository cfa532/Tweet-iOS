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

extension NSAttributedString.Key {
    static let moreLinkTap = NSAttributedString.Key("com.tweet.moreLinkTap")
    static let tweetDetectedURL = NSAttributedString.Key("com.tweet.detectedURL")
}

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
        label.textColor = XTheme.text
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    // Video caption label (for single-video tweets with title)
    private let captionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = XTheme.secondaryText
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

    // Audio playlist hosting
    private var audioHostingController: UIHostingController<AnyView>?
    private let audioContainerView = UIView()

    // Document attachments hosting (keeps SwiftUI, but reuses one host per cell)
    private var documentHostingController: UIHostingController<AnyView>?
    private let documentContainerView = UIView()

    var onTweetBodyTap: (() -> Void)?
    var onContentExpanded: (() -> Void)?
    /// Per-feed video coordinator (set by TweetCellContentView)
    weak var videoCoordinator: VideoPlaybackCoordinator?
    var cellHorizontalPadding: CGFloat = 16 {
        didSet {
            mediaGridView.cellHorizontalPadding = cellHorizontalPadding
        }
    }
    /// Whether the video caption label is currently visible (for single-video tweets with title)
    private(set) var isCaptionVisible: Bool = false
    /// Whether the content is truncated with a "More..." suffix
    private(set) var isTruncated: Bool = false
    /// Whether content has been expanded by the user tapping "More..."
    private(set) var isExpanded: Bool = false
    private var currentFullContent: String?
    private var currentTweetId: String?
    private var currentCellTweetId: String?
    private var currentIsEmbedded: Bool = false
    private weak var parentViewController: UIViewController?
    private weak var contentLabelTapGesture: UITapGestureRecognizer?
    private var contentCancellable: AnyCancellable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let hostingController = audioHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        if let hostingController = documentHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
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

        // Build content stack: [contentLabel, audioContainer, mediaContainer, captionLabel, documentContainer]
        contentStack.addArrangedSubview(contentLabel)
        contentStack.addArrangedSubview(audioContainerView)
        contentStack.addArrangedSubview(mediaContainerView)
        contentStack.addArrangedSubview(captionLabel)
        contentStack.addArrangedSubview(documentContainerView)

        // Set initial spacing (will be adjusted per tweet)
        contentStack.setCustomSpacing(4, after: contentLabel)  // text → attachments gap
        contentStack.setCustomSpacing(8, after: audioContainerView)  // audio → media gap
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

        // Tap gesture on content label
        let tap = UITapGestureRecognizer(target: self, action: #selector(bodyTapped))
        contentLabel.addGestureRecognizer(tap)
        contentLabel.isUserInteractionEnabled = true
        contentLabelTapGesture = tap
    }

    @objc private func bodyTapped() {
        if let tap = contentLabelTapGesture {
            let tapPoint = tap.location(in: contentLabel)
            if let url = Self.detectedURL(in: contentLabel, at: tapPoint) {
                Self.openExternalURL(url)
                return
            }
        }

        if isTruncated, !isExpanded, let tap = contentLabelTapGesture {
            let tapPoint = tap.location(in: contentLabel)
            if isMoreLinkTap(at: tapPoint) {
                expandContent()
                return
            }
        }
        onTweetBodyTap?()
    }

    /// Check whether a point (in TweetBodyUIView coordinate space) hits the "More..." link.
    func isMoreLinkPoint(_ pointInBodyView: CGPoint) -> Bool {
        guard isTruncated, !isExpanded else { return false }
        let labelPoint = convert(pointInBodyView, to: contentLabel)
        return isMoreLinkTap(at: labelPoint)
    }

    func isURLLinkPoint(_ pointInBodyView: CGPoint) -> Bool {
        let labelPoint = convert(pointInBodyView, to: contentLabel)
        return Self.detectedURL(in: contentLabel, at: labelPoint) != nil
    }

    func isAudioPlayerPoint(_ pointInBodyView: CGPoint) -> Bool {
        !audioContainerView.isHidden && audioContainerView.frame.contains(pointInBodyView)
    }

    private func isMoreLinkTap(at pointInContentLabel: CGPoint) -> Bool {
        guard let attrText = contentLabel.attributedText,
              attrText.length > 0,
              contentLabel.bounds.contains(pointInContentLabel) else { return false }

        let textStorage = NSTextStorage(attributedString: attrText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: contentLabel.bounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = contentLabel.numberOfLines
        textContainer.lineBreakMode = contentLabel.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let charIndex = layoutManager.characterIndex(
            for: pointInContentLabel, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard charIndex < attrText.length else { return false }
        return attrText.attribute(.moreLinkTap, at: charIndex, effectiveRange: nil) != nil
    }

    private func expandContent() {
        guard let content = currentFullContent, !isExpanded else { return }
        isExpanded = true

        contentLabel.numberOfLines = 0
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.attributedText = Self.makeFullContentAttributedString(content: content)

        setNeedsLayout()
        onContentExpanded?()
    }

    private func renderTextContent(tweet: Tweet, isEmbedded: Bool) {
        if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Compute available text width (must match deterministic height calculator)
            let screenWidth = UIScreen.main.bounds.width
            let regularContentWidth = (
                screenWidth
                - cellHorizontalPadding
                - 3 // mainStack leading
                - 42 // avatar
                - 4 // avatar/content spacing
            )
            let textWidth: CGFloat
            if isEmbedded {
                // bodyView is below headerRow (full contentStack width, NOT beside embedded avatar)
                // regular content width + embedded wrapper extension (4)
                // - embedded content stack padding (8 + 8)
                textWidth = regularContentWidth + 4 - 16
            } else {
                textWidth = regularContentWidth
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
            // Detect truncation: the "More..." suffix carries the .moreLinkTap attribute
            let attrText = contentLabel.attributedText
            let lastIndex = (attrText?.length ?? 0) - 1
            if lastIndex >= 0, let attr = attrText,
               attr.attribute(.moreLinkTap, at: lastIndex, effectiveRange: nil) != nil {
                isTruncated = true
                currentFullContent = content
            } else {
                isTruncated = false
                currentFullContent = nil
            }
            contentLabel.isHidden = false
        } else {
            contentLabel.attributedText = nil
            contentLabel.isHidden = true
            isTruncated = false
            currentFullContent = nil
        }
    }

    private func bindTweetContentUpdates(_ tweet: Tweet) {
        // Rebind only when switching to a different tweet object.
        guard observedTweet !== tweet else { return }
        observedTweet = tweet
        contentCancellable?.cancel()
        contentCancellable = tweet.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                // If content changed remotely/local-edit, collapse and redraw immediately.
                self.isExpanded = false
                self.contentLabel.numberOfLines = Self.maxContentLines
                self.contentLabel.lineBreakMode = .byTruncatingTail
                self.renderTextContent(tweet: tweet, isEmbedded: self.currentIsEmbedded)
                self.setNeedsLayout()
                self.superview?.setNeedsLayout()
                self.onContentExpanded?()
            }
    }

    private weak var observedTweet: Tweet?

    func configure(tweet: Tweet, isEmbedded: Bool, cellTweetId: String?,
                   parentViewController: UIViewController) {
        self.parentViewController = parentViewController
        bindTweetContentUpdates(tweet)

        // Pure retweets render the original tweet's media inside the retweet cell.
        // The media owner tweet can be unchanged while the visible cell context changes,
        // so include cellTweetId/isEmbedded in the reuse guard to keep video identifiers fresh.
        if currentTweetId == tweet.mid,
           currentCellTweetId == cellTweetId,
           currentIsEmbedded == isEmbedded {
            return
        }
        currentTweetId = tweet.mid
        currentCellTweetId = cellTweetId
        currentIsEmbedded = isEmbedded

        // Reset expansion state for new tweet
        isExpanded = false
        isTruncated = false
        currentFullContent = nil
        contentLabel.numberOfLines = Self.maxContentLines
        contentLabel.lineBreakMode = .byTruncatingTail

        // Clean up media grid and reset document content for reuse
        mediaGridView.prepareForReuse()
        audioContainerView.isHidden = true
        audioHostingController?.rootView = AnyView(EmptyView())
        documentContainerView.isHidden = true
        documentHostingController?.rootView = AnyView(EmptyView())

        // --- Text content ---
        renderTextContent(tweet: tweet, isEmbedded: isEmbedded)

        // --- Attachments ---
        let audioAttachments = tweet.attachments?.filter { $0.type == .audio } ?? []
        let mediaAttachments = tweet.attachments?.filter { Self.isMediaType($0.type) } ?? []
        let documentAttachments = tweet.attachments?.filter { Self.isDocumentType($0.type) } ?? []
        let hasAudio = !audioAttachments.isEmpty
        let hasMedia = !mediaAttachments.isEmpty
        let hasDocuments = !documentAttachments.isEmpty

        // --- Audio playlist ---
        if hasAudio {
            audioContainerView.isHidden = false
            let audioView = CompactAudioPlaylistPlayer(
                parentTweet: tweet,
                attachments: audioAttachments
            )
            let hostingController = ensureAudioHostingController(parentViewController: parentViewController)
            hostingController.rootView = AnyView(audioView)
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.setNeedsLayout()

            contentStack.setCustomSpacing(contentLabel.isHidden ? 4 : 8, after: contentLabel)
            contentStack.setCustomSpacing(hasMedia ? 8 : 0, after: audioContainerView)
        } else {
            audioContainerView.isHidden = true
            audioHostingController?.rootView = AnyView(EmptyView())
            contentStack.setCustomSpacing(0, after: audioContainerView)
        }

        // --- Media grid ---
        if hasMedia {
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
            let caption = singleVideoCaption(tweet: tweet, attachments: mediaAttachments, hasTextContent: !contentLabel.isHidden)
            if let caption {
                captionLabel.text = caption
                captionLabel.isHidden = false
                isCaptionVisible = true
            } else {
                captionLabel.isHidden = true
                captionLabel.text = nil
                isCaptionVisible = false
            }

            // Adjust spacing based on whether there's text/audio above media
            if hasAudio {
                contentStack.setCustomSpacing(8, after: audioContainerView)
            } else if contentLabel.isHidden {
                // No text: 4pt top padding before media
                contentStack.setCustomSpacing(4, after: contentLabel)
            } else {
                // Text present: 8pt gap
                contentStack.setCustomSpacing(8, after: contentLabel)
            }
        } else {
            mediaContainerView.isHidden = true
            captionLabel.isHidden = true
            isCaptionVisible = false

            // Collapse spacing after content label if no media
            if !hasAudio {
                contentStack.setCustomSpacing(0, after: contentLabel)
            }
        }

        // --- Documents ---
        if hasDocuments {
            documentContainerView.isHidden = false

            // Reuse one hosting controller per cell instead of recreating it on every configure.
            let docView = DocumentAttachmentsView(
                parentTweet: tweet,
                documents: documentAttachments,
                maxDocuments: 2
            )
            let hostingController = ensureDocumentHostingController(parentViewController: parentViewController)
            hostingController.rootView = AnyView(docView)
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.setNeedsLayout()

            // Add spacing before documents if there's media or text
            if hasMedia {
                contentStack.setCustomSpacing(8, after: captionLabel.isHidden ? mediaContainerView : captionLabel)
            } else if hasAudio {
                contentStack.setCustomSpacing(8, after: audioContainerView)
            } else if !contentLabel.isHidden {
                contentStack.setCustomSpacing(8, after: contentLabel)
            }
        } else {
            documentContainerView.isHidden = true
            documentHostingController?.rootView = AnyView(EmptyView())
        }
    }

    func prepareForReuse() {
        currentTweetId = nil
        currentCellTweetId = nil
        contentLabel.attributedText = nil
        contentLabel.numberOfLines = Self.maxContentLines
        contentLabel.lineBreakMode = .byTruncatingTail
        captionLabel.text = nil
        captionLabel.isHidden = true
        isCaptionVisible = false
        isTruncated = false
        isExpanded = false
        currentFullContent = nil
        onTweetBodyTap = nil
        onContentExpanded = nil
        mediaGridView.prepareForReuse()
        audioContainerView.isHidden = true
        audioHostingController?.rootView = AnyView(EmptyView())
        documentContainerView.isHidden = true
        documentHostingController?.rootView = AnyView(EmptyView())

        // Reset spacing to defaults
        contentStack.setCustomSpacing(4, after: contentLabel)
        contentStack.setCustomSpacing(8, after: audioContainerView)
        contentStack.setCustomSpacing(2, after: mediaContainerView)
        contentStack.setCustomSpacing(0, after: captionLabel)
    }

    private func ensureAudioHostingController(parentViewController: UIViewController) -> UIHostingController<AnyView> {
        if let hostingController = audioHostingController {
            if hostingController.parent !== parentViewController {
                hostingController.willMove(toParent: nil)
                hostingController.view.removeFromSuperview()
                hostingController.removeFromParent()
                parentViewController.addChild(hostingController)
                audioContainerView.addSubview(hostingController.view)
                hostingController.didMove(toParent: parentViewController)
                hostingController.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    hostingController.view.topAnchor.constraint(equalTo: audioContainerView.topAnchor),
                    hostingController.view.leadingAnchor.constraint(equalTo: audioContainerView.leadingAnchor),
                    hostingController.view.trailingAnchor.constraint(equalTo: audioContainerView.trailingAnchor, constant: -2),
                    hostingController.view.bottomAnchor.constraint(equalTo: audioContainerView.bottomAnchor),
                ])
            }
            return hostingController
        }

        let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        hostingController.view.backgroundColor = .clear
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        hostingController.sizingOptions = [.intrinsicContentSize]

        parentViewController.addChild(hostingController)
        audioContainerView.addSubview(hostingController.view)
        hostingController.didMove(toParent: parentViewController)

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: audioContainerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: audioContainerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: audioContainerView.trailingAnchor, constant: -2),
            hostingController.view.bottomAnchor.constraint(equalTo: audioContainerView.bottomAnchor),
        ])

        audioHostingController = hostingController
        return hostingController
    }

    private func ensureDocumentHostingController(parentViewController: UIViewController) -> UIHostingController<AnyView> {
        if let hostingController = documentHostingController {
            if hostingController.parent !== parentViewController {
                hostingController.willMove(toParent: nil)
                hostingController.view.removeFromSuperview()
                hostingController.removeFromParent()
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
            }
            return hostingController
        }

        let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
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
        return hostingController
    }

    // MARK: - Helpers

    private func singleVideoCaption(tweet: Tweet, attachments: [MimeiFileType], hasTextContent: Bool) -> String? {
        guard attachments.count == 1 else { return nil }
        let attachment = attachments[0]
        guard attachment.type == .video || attachment.type == .hls_video else { return nil }

        if let rawTitle = tweet.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTitle.isEmpty {
            return rawTitle
        }

        // Only show filename when the tweet has no text content
        if !hasTextContent,
           let rawFileName = attachment.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        case .image, .video, .hls_video:
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
        paragraphStyle.lineSpacing = 3
        paragraphStyle.lineBreakMode = .byWordWrapping

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: XTheme.text,
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
            return makeFullContentAttributedString(content: content)
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
            return makeFullContentAttributedString(content: content)
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
        bodyPs.lineSpacing = 3
        bodyPs.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(string: bodyText, attributes: [
            .font: font,
            .foregroundColor: XTheme.text,
            .paragraphStyle: bodyPs
        ])
        result.append(NSAttributedString(string: moreString, attributes: [
            .font: font,
            .foregroundColor: XTheme.accent,
            .moreLinkTap: true,
        ]))
        applyDetectedLinks(to: result, in: NSRange(location: 0, length: bodyText.utf16.count))

        return result
    }

    static func makeFullContentAttributedString(content: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(string: content, attributes: [
            .font: contentFont,
            .foregroundColor: XTheme.text,
            .paragraphStyle: paragraphStyle,
        ])
        applyDetectedLinks(to: result, in: NSRange(location: 0, length: result.length))
        return result
    }

    static func detectedURL(in label: UILabel, at point: CGPoint) -> URL? {
        guard let attrText = label.attributedText,
              attrText.length > 0,
              label.bounds.contains(point) else { return nil }

        let textStorage = NSTextStorage(attributedString: attrText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: label.bounds.size)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = label.numberOfLines
        textContainer.lineBreakMode = label.lineBreakMode
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let characterIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard characterIndex < attrText.length,
              let url = attrText.attribute(.tweetDetectedURL, at: characterIndex, effectiveRange: nil) as? URL else {
            return nil
        }
        return url
    }

    static func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // NSDataDetector is expensive to initialize (regex compilation, ~10–50ms).
    // Reuse one instance across all calls — enumerateMatches is thread-safe for read-only use.
    private static let urlDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func applyDetectedLinks(to attributedString: NSMutableAttributedString, in range: NSRange) {
        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= attributedString.length,
              let detector = urlDetector else {
            return
        }

        let fullString = attributedString.string as NSString
        detector.enumerateMatches(in: attributedString.string, options: [], range: range) { match, _, _ in
            guard let match,
                  let url = match.url,
                  NSMaxRange(match.range) <= attributedString.length else { return }

            let matchedText = fullString.substring(with: match.range)
            let trimmedLength = matchedText.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)］】》」'\"")).utf16.count
            let linkRange = NSRange(location: match.range.location, length: trimmedLength)
            guard linkRange.length > 0 else { return }

            attributedString.addAttributes([
                .tweetDetectedURL: url,
                .foregroundColor: XTheme.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: linkRange)
        }
    }
}
