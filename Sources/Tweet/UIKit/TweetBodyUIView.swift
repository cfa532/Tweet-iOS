//
//  TweetBodyUIView.swift
//  Tweet
//
//  Pure UIKit tweet body replacing SwiftUI TweetItemBodyView.
//  Shows text content and media grid.
//  Phase 1: Media grid uses a small UIHostingController for SwiftUI MediaGridView.
//  Phase 3 will replace that with pure UIKit MediaGridUIView.
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

    // Media hosting controller (Phase 1: hosts SwiftUI MediaGridView)
    private var mediaHostingController: UIHostingController<AnyView>?
    private var mediaContainerView: UIView = {
        let v = UIView()
        v.clipsToBounds = true
        v.layer.cornerRadius = 8
        return v
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

    // Document attachments hosting (Phase 1: hosts SwiftUI DocumentAttachmentsView)
    private var documentHostingController: UIHostingController<AnyView>?
    private let documentContainerView = UIView()

    // Layout constraints that change based on content
    private var contentLabelBottomToMedia: NSLayoutConstraint?
    private var contentLabelBottomToSelf: NSLayoutConstraint?
    private var mediaTopToContent: NSLayoutConstraint?
    private var mediaTopToSelf: NSLayoutConstraint?
    private var mediaHeightConstraint: NSLayoutConstraint?
    private var captionTopConstraint: NSLayoutConstraint?
    private var documentTopConstraint: NSLayoutConstraint?

    var onTweetBodyTap: (() -> Void)?
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

        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        mediaContainerView.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        documentContainerView.translatesAutoresizingMaskIntoConstraints = false

        // Content label constraints
        NSLayoutConstraint.activate([
            contentLabel.topAnchor.constraint(equalTo: topAnchor),
            contentLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Media container constraints
        NSLayoutConstraint.activate([
            mediaContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mediaTopToContent = mediaContainerView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 4)
        mediaTopToSelf = mediaContainerView.topAnchor.constraint(equalTo: topAnchor)
        mediaHeightConstraint = mediaContainerView.heightAnchor.constraint(equalToConstant: 0)

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
        documentTopConstraint = documentContainerView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 0)

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
        documentTopConstraint?.isActive = false

        // Remove old hosting controllers
        removeMediaHosting()
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

        // --- Media grid ---
        if hasMedia {
            let mediaHeight = MediaGridViewModel.calculateHeight(for: mediaAttachments, isEmbedded: isEmbedded)

            mediaHeightConstraint?.constant = mediaHeight
            mediaHeightConstraint?.isActive = true

            if hasText {
                mediaTopToContent?.isActive = true
            } else {
                mediaTopToSelf?.isActive = true
            }

            mediaContainerView.isHidden = false

            // Host SwiftUI MediaGridView (Phase 1 interim)
            let mediaGridView = MediaGridView(
                parentTweet: tweet,
                attachments: mediaAttachments,
                isEmbedded: isEmbedded,
                cellTweetId: cellTweetId
            )
            .environmentObject(HproseInstance.shared)

            let hostingController = UIHostingController(rootView: AnyView(mediaGridView))
            hostingController.view.backgroundColor = .clear
            hostingController.view.insetsLayoutMarginsFromSafeArea = false
            hostingController.sizingOptions = [.intrinsicContentSize]

            parentViewController.addChild(hostingController)
            mediaContainerView.addSubview(hostingController.view)
            hostingController.didMove(toParent: parentViewController)

            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingController.view.topAnchor.constraint(equalTo: mediaContainerView.topAnchor),
                hostingController.view.leadingAnchor.constraint(equalTo: mediaContainerView.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: mediaContainerView.trailingAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: mediaContainerView.bottomAnchor),
            ])

            mediaHostingController = hostingController

            // Caption for single video
            let caption = singleVideoCaption(tweet: tweet, attachments: mediaAttachments)
            if let caption {
                captionLabel.text = caption
                captionLabel.isHidden = false
                captionTopConstraint?.isActive = true
            } else {
                captionLabel.isHidden = true
                captionLabel.text = nil
            }
        } else {
            mediaContainerView.isHidden = true
            mediaHeightConstraint?.constant = 0
            mediaHeightConstraint?.isActive = true
            captionLabel.isHidden = true

            if hasText {
                mediaTopToContent?.constant = 0
                mediaTopToContent?.isActive = true
            } else {
                mediaTopToSelf?.isActive = true
            }
        }

        // --- Documents ---
        if hasDocuments {
            documentContainerView.isHidden = false
            let topPadding: CGFloat = hasMedia ? 8 : (hasText ? 4 : 0)

            if captionLabel.isHidden {
                // Connect to media container bottom
                documentTopConstraint?.isActive = false
                let constraint = documentContainerView.topAnchor.constraint(
                    equalTo: mediaContainerView.bottomAnchor, constant: topPadding)
                constraint.isActive = true
                documentTopConstraint = constraint
            } else {
                documentTopConstraint?.constant = topPadding
                documentTopConstraint?.isActive = true
            }

            // Host SwiftUI DocumentAttachmentsView
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

            // Connect bottom
            if captionLabel.isHidden == false {
                documentTopConstraint?.constant = 0
                documentTopConstraint?.isActive = true
            } else {
                let constraint = documentContainerView.topAnchor.constraint(
                    equalTo: mediaContainerView.bottomAnchor, constant: 0)
                constraint.isActive = true
                documentTopConstraint = constraint
            }
        }
    }

    func prepareForReuse() {
        currentTweetId = nil
        contentLabel.text = nil
        captionLabel.text = nil
        captionLabel.isHidden = true
        onTweetBodyTap = nil
        removeMediaHosting()
        removeDocumentHosting()
    }

    private func removeMediaHosting() {
        if let hc = mediaHostingController {
            hc.willMove(toParent: nil)
            hc.view.removeFromSuperview()
            hc.removeFromParent()
            mediaHostingController = nil
        }
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
