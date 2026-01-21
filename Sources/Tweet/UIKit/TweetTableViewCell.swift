//
//  TweetTableViewCell.swift
//  Tweet
//
//  UIKit-based tweet cell to replace SwiftUI LazyVStack
//  Eliminates SwiftUI's GraphHost.flushTransactions() bottleneck
//
import UIKit
import SwiftUI

/// Cache for SwiftUI views to reduce recreation during scrolling
/// MEMORY FIX: Added LRU eviction and size limits to prevent unbounded growth
class SwiftUIViewCache {
    static let shared = SwiftUIViewCache()
    private var viewCache: [String: AnyView] = [:]
    private var accessOrder: [String] = [] // LRU tracking
    private let maxCacheSize = 50 // Cache up to 50 views (~5-10MB depending on view complexity)
    private let lock = NSLock() // Thread safety

    private init() {}

    func getView(for key: String) -> AnyView? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let view = viewCache[key] else {
            return nil
        }
        
        // Update LRU order
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
        
        return view
    }

    func setView(_ view: AnyView, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // If already in cache, update and refresh LRU
        if viewCache[key] != nil {
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            accessOrder.append(key)
            viewCache[key] = view
            return
        }
        
        // Evict oldest entry if at capacity
        if viewCache.count >= maxCacheSize {
            if let oldestKey = accessOrder.first {
                viewCache.removeValue(forKey: oldestKey)
                accessOrder.removeFirst()
            }
        }
        
        // Add new entry
        viewCache[key] = view
        accessOrder.append(key)
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        
        viewCache.removeAll()
        accessOrder.removeAll()
    }
}

class TweetTableViewCell: UITableViewCell {
    static let reuseIdentifier = "TweetTableViewCell"

    private var hostingController: UIHostingController<AnyView>?
    private var currentTweetId: String?
    private var lastViewKey: String?
    
    // MEMORY FIX: Track constraints so we can remove them during reuse
    private var activeConstraints: [NSLayoutConstraint] = []

    /// Publicly accessible tweet ID for video orchestration
    var tweetId: String? {
        return currentTweetId
    }

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
        parentViewController: UIViewController,
        leadingPadding: CGFloat = 8,
        trailingPadding: CGFloat = 8
    ) {
        // Create a cache key based on tweet data that affects visual appearance
        let viewKey = "\(tweet.mid)_\(tweet.author?.username ?? "nil")_\(tweet.content ?? "")_\(tweet.timestamp.timeIntervalSince1970)"

        // Check if we can reuse existing hosting controller
        if currentTweetId == tweet.mid && hostingController != nil {
            // Same tweet - check if view content changed
            if lastViewKey != viewKey {
                lastViewKey = viewKey
                // Try to get cached view first
                if let cachedView = SwiftUIViewCache.shared.getView(for: viewKey) {
                    hostingController?.rootView = cachedView
                } else {
                    let swiftUIView = rowView(tweet)
                    hostingController?.rootView = swiftUIView
                    SwiftUIViewCache.shared.setView(swiftUIView, for: viewKey)
                }
            }
            // Same tweet and same view content - no update needed
            return
        }

        // Tweet changed - need new hosting controller
        currentTweetId = tweet.mid
        lastViewKey = viewKey

        // MEMORY FIX: Remove old hosting controller if it exists
        // This must be done carefully to avoid leaks
        if let oldHostingController = hostingController {
            // Deactivate and clear old constraints first
            NSLayoutConstraint.deactivate(activeConstraints)
            activeConstraints.removeAll()
            
            // Properly remove from hierarchy
            oldHostingController.willMove(toParent: nil)
            oldHostingController.view.removeFromSuperview()
            oldHostingController.removeFromParent()
            
            // Clear reference
            self.hostingController = nil
        }

        // Try to get cached view first to avoid recreation
        let swiftUIView: AnyView
        if let cachedView = SwiftUIViewCache.shared.getView(for: viewKey) {
            swiftUIView = cachedView
        } else {
            swiftUIView = rowView(tweet)
            SwiftUIViewCache.shared.setView(swiftUIView, for: viewKey)
        }

        // Create new hosting controller
        let hostingController = UIHostingController(rootView: swiftUIView)
        hostingController.view.backgroundColor = .clear

        // CRITICAL: Disable safe area to prevent layout loops
        hostingController.view.insetsLayoutMarginsFromSafeArea = false

        // CRITICAL: Set sizing options to prevent constant recalculation
        hostingController.sizingOptions = [.intrinsicContentSize]
        
        // PERFORMANCE: Disable implicit animations during initial layout
        // This prevents expensive CoreAnimation work during cell prefetch/creation
        hostingController.view.layer.allowsEdgeAntialiasing = false
        hostingController.view.layer.shouldRasterize = false

        self.hostingController = hostingController

        // Add to parent
        parentViewController.addChild(hostingController)
        contentView.addSubview(hostingController.view)
        hostingController.didMove(toParent: parentViewController)

        // Layout with constraints (configurable horizontal padding)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        // MEMORY FIX: Store constraints so we can deactivate them during reuse
        let newConstraints = [
            hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leadingPadding),
            hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -trailingPadding),
            hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(newConstraints)
        activeConstraints = newConstraints
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        
        // MEMORY FIX: Deactivate constraints to prevent accumulation
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints.removeAll()
        
        // MEMORY FIX: Remove hosting controller from parent to prevent leak
        // The controller will be reused or replaced in configure()
        if let hostingController = hostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        
        // Clear references
        hostingController = nil
        currentTweetId = nil
        lastViewKey = nil
    }

    deinit {
        // MEMORY FIX: Clean up all resources when cell is deallocated
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints.removeAll()
        
        if let hostingController = hostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
    }
}
