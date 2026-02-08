//
//  TweetBodyUIView.swift
//  Tweet
//
//  Pure UIKit tweet body replacing SwiftUI TweetItemBodyView.
//  Shows text content and media grid.
//  Phase 3: Media grid uses pure UIKit MediaGridUIView (no UIHostingController).
//
import UIKit
import SwiftUI
import Combine

class TweetBodyUIView: UIView {

    private let contentLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 7
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .label
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
        v.clipsToBounds = true
        v.layer.cornerRadius = 8
        return v
    }()

    // Document attachments hosting (keeps SwiftUI — not in critical path)
    private var documentHostingController: UIHostingController<AnyView>?
    private let documentContainerView = UIView()

    // Layout constraints that change based on content
    private var mediaTopToContent: NSLayoutConstraint?
    private var mediaTopToSelf: NSLayoutConstraint?
    private var mediaHeightConstraint: NSLayoutConstraint?
    private var captionTopConstraint: NSLayoutConstraint?
    // Two document-top constraints: toggle based on caption visibility (prevents reuse bug)
    private var documentTopToCaption: NSLayoutConstraint?
    private var documentTopToMedia: NSLayoutConstraint?
    private var documentHeightConstraint: NSLayoutConstraint?

    var onTweetBodyTap: (() -> Void)?
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
        addSubview(contentLabel)
        addSubview(mediaContainerView)
        addSubview(captionLabel)
        addSubview(documentContainerView)

        // Add media grid to container
        mediaContainerView.addSubview(mediaGridView)

        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        mediaContainerView.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        documentContainerView.translatesAutoresizingMaskIntoConstraints = false
        mediaGridView.translatesAutoresizingMaskIntoConstraints = false

        // Content label constraints
        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: topAnchor),
            contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Media container constraints (1pt right padding for media grid)
        NSLayoutConstraint.activate([
            mediaContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])
        // text .padding(.bottom, 2) + media .padding(.top, 6) = 8pt gap
        mediaTopToContent = mediaContainerView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 8)
        mediaTopToSelf = mediaContainerView.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        mediaHeightConstraint = mediaContainerView.heightAnchor.constraint(equalToConstant: 0)

        // Media grid fills container
        NSLayoutConstraint.activate([
            mediaGridView.topAnchor.constraint(equalTo: mediaContainerView.topAnchor),
            mediaGridView.leadingAnchor.constraint(equalTo: mediaContainerView.leadingAnchor),
            mediaGridView.trailingAnchor.constraint(equalTo: mediaContainerView.trailingAnchor),
            mediaGridView.bottomAnchor.constraint(equalTo: mediaContainerView.bottomAnchor),
        ])

        // Caption label constraints
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        captionTopConstraint = captionLabel.topAnchor.constraint(equalTo: mediaContainerView.bottomAnchor, constant: 2)

        // Document container constraints
        NSLayoutConstraint.activate([
            documentContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            documentContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            documentContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        documentTopToCaption = documentContainerView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 0)
        documentTopToMedia = documentContainerView.topAnchor.constraint(equalTo: mediaContainerView.bottomAnchor, constant: 0)
        documentHeightConstraint = documentContainerView.heightAnchor.constraint(equalToConstant: 0)

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

        // Deactivate all dynamic constraints first
        mediaTopToContent?.isActive = false
        mediaTopToSelf?.isActive = false
        mediaHeightConstraint?.isActive = false
        captionTopConstraint?.isActive = false
        documentTopToCaption?.isActive = false
        documentTopToMedia?.isActive = false
        documentHeightConstraint?.isActive = false

        // Clean up media grid and document hosting
        mediaGridView.prepareForReuse()
        removeDocumentHosting()

        // --- Text content ---
        let hasText: Bool
        if let content = tweet.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentLabel.text = content
            contentLabel.isHidden = false
            hasText = true
        } else {
            contentLabel.text = nil
            contentLabel.isHidden = true
            hasText = false
        }

        // --- Attachments ---
        let mediaAttachments = tweet.attachments?.filter { Self.isMediaType($0.type) } ?? []
        let documentAttachments = tweet.attachments?.filter { Self.isDocumentType($0.type) } ?? []
        let hasMedia = !mediaAttachments.isEmpty
        let hasDocuments = !documentAttachments.isEmpty

        // --- Media grid (Phase 3: pure UIKit) ---
        if hasMedia {
            let mediaHeight = MediaGridViewModel.calculateHeight(for: mediaAttachments, isEmbedded: isEmbedded)

            mediaHeightConstraint?.constant = mediaHeight
            mediaHeightConstraint?.isActive = true

            if hasText {
                mediaTopToContent?.constant = 8
                mediaTopToContent?.isActive = true
            } else {
                mediaTopToSelf?.isActive = true
            }

            mediaContainerView.isHidden = false

            // Configure pure UIKit media grid
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
                captionTopConstraint?.isActive = true
                isCaptionVisible = true
            } else {
                captionLabel.isHidden = true
                captionLabel.text = nil
                isCaptionVisible = false
            }
        } else {
            mediaContainerView.isHidden = true
            mediaHeightConstraint?.constant = 0
            mediaHeightConstraint?.isActive = true
            captionLabel.isHidden = true

            if hasText {
                mediaTopToContent?.constant = 2
                mediaTopToContent?.isActive = true
            } else {
                mediaTopToSelf?.isActive = true
            }
        }

        // --- Documents ---
        // Choose correct document-top anchor based on caption visibility
        if captionLabel.isHidden {
            // No caption: document anchors to media container bottom
            documentTopToMedia?.constant = hasDocuments ? (hasMedia ? 8 : (hasText ? 4 : 0)) : 0
            documentTopToMedia?.isActive = true
        } else {
            // Caption visible: document anchors to caption label bottom
            documentTopToCaption?.constant = hasDocuments ? (hasMedia ? 8 : (hasText ? 4 : 0)) : 0
            documentTopToCaption?.isActive = true
        }

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
        } else {
            documentContainerView.isHidden = true
            documentHeightConstraint?.isActive = true  // Force zero height when no documents
        }
    }

    func prepareForReuse() {
        currentTweetId = nil
        contentLabel.text = nil
        captionLabel.text = nil
        captionLabel.isHidden = true
        isCaptionVisible = false
        onTweetBodyTap = nil
        mediaGridView.prepareForReuse()
        removeDocumentHosting()
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
}
