//
//  TweetTableViewCell.swift
//  Tweet
//
//  UIKit-based tweet cell to replace SwiftUI LazyVStack
//  Eliminates SwiftUI's GraphHost.flushTransactions() bottleneck
//
import UIKit
import SwiftUI

class TweetTableViewCell: UITableViewCell {
    static let reuseIdentifier = "TweetTableViewCell"
    
    private var hostingController: UIHostingController<AnyView>?
    private var currentTweetId: String?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupCell() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }
    
    func configure(
        with tweet: Tweet,
        rowView: (Tweet) -> AnyView,
        parentViewController: UIViewController
    ) {
        // Only recreate hosting controller if tweet changed
        if currentTweetId != tweet.mid {
            currentTweetId = tweet.mid
            
            // Remove old hosting controller if it exists
            if let oldHostingController = hostingController {
                oldHostingController.willMove(toParent: nil)
                oldHostingController.view.removeFromSuperview()
                oldHostingController.removeFromParent()
            }
            
            // Create new hosting controller with SwiftUI view
            let swiftUIView = rowView(tweet)
            let hostingController = UIHostingController(rootView: swiftUIView)
            hostingController.view.backgroundColor = .clear
            
            // CRITICAL: Disable safe area to prevent layout loops
            hostingController.view.insetsLayoutMarginsFromSafeArea = false
            
            // CRITICAL: Set sizing options to prevent constant recalculation
            hostingController.sizingOptions = [.intrinsicContentSize]
            
            self.hostingController = hostingController
            
            // Add to parent
            parentViewController.addChild(hostingController)
            contentView.addSubview(hostingController.view)
            hostingController.didMove(toParent: parentViewController)
            
            // Layout with constraints
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        } else {
            // Same tweet - just update the root view without recreating
            if let hostingController = hostingController {
                hostingController.rootView = rowView(tweet)
            }
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        // DON'T remove hosting controller here - it causes the loop
        // Just clear the tweet ID
        currentTweetId = nil
    }
    
    deinit {
        // Clean up when cell is deallocated
        if let hostingController = hostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
    }
}

