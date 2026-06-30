//
//  MediaGridView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/20.
//

@preconcurrency import Foundation
import SwiftUI
import UIKit

struct MediaGridView: View, @MainActor Equatable {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let isEmbedded: Bool // Flag to indicate this is an embedded tweet (prevents video loading)
    let maxImages: Int = 4
    let cellTweetId: String? // ID of the tweet user is viewing (retweet ID for retweets, nil = use parentTweet.mid)
    
    // Equatable conformance to help SwiftUI reuse views and prevent unnecessary recomposition
    static func == (lhs: MediaGridView, rhs: MediaGridView) -> Bool {
        return lhs.parentTweet.mid == rhs.parentTweet.mid &&
               lhs.attachments.count == rhs.attachments.count &&
               lhs.attachments.map { $0.mid } == rhs.attachments.map { $0.mid } &&
               lhs.isEmbedded == rhs.isEmbedded &&
               lhs.cellTweetId == rhs.cellTweetId
    }
    @State private var shouldLoadVideo: Bool
    @State private var isVisible = false
    @State private var hasInitialized = false // Track if we've done initial setup
    
    init(parentTweet: Tweet, attachments: [MimeiFileType], isEmbedded: Bool = false, cellTweetId: String? = nil) {
        self.parentTweet = parentTweet
        self.attachments = attachments
        self.isEmbedded = isEmbedded
        self.cellTweetId = cellTweetId
        self._shouldLoadVideo = State(initialValue: true)
    }
    
    var body: some View {
        let gridAspectRatio = MediaGridViewModel.aspectRatio(for: attachments)

        UIKitMediaGridRepresentable(
            parentTweet: parentTweet,
            attachments: attachments,
            isEmbedded: isEmbedded,
            cellTweetId: cellTweetId,
            shouldLoadVideo: shouldLoadVideo,
            isVisible: isVisible
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(gridAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .id("mediagrid_\(parentTweet.mid)")
        .onAppear {
            if hasInitialized {
                isVisible = true
                return
            }

            hasInitialized = true
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopAllVideos)) { _ in
            shouldLoadVideo = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlayCoverageChanged)) { notification in
            guard let isCovered = notification.userInfo?["isCovered"] as? Bool else { return }
            if !isCovered, isVisible {
                shouldLoadVideo = true
            }
        }
    }

}

private struct UIKitMediaGridRepresentable: UIViewRepresentable {
    let parentTweet: Tweet
    let attachments: [MimeiFileType]
    let isEmbedded: Bool
    let cellTweetId: String?
    let shouldLoadVideo: Bool
    let isVisible: Bool

    func makeUIView(context: Context) -> MediaGridUIView {
        let gridView = MediaGridUIView()
        gridView.isUserInteractionEnabled = true
        return gridView
    }

    func updateUIView(_ uiView: MediaGridUIView, context: Context) {
        if let parentViewController = uiView.nearestViewController ?? UIApplication.shared.topMostViewController {
            configure(uiView, parentViewController: parentViewController)
        } else {
            DispatchQueue.main.async {
                guard let parentViewController = uiView.nearestViewController ?? UIApplication.shared.topMostViewController else { return }
                configure(uiView, parentViewController: parentViewController)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MediaGridUIView, context: Context) -> CGSize? {
        let fallbackWidth = MediaGridViewModel.defaultGridWidth(isEmbedded: isEmbedded)
        let width = proposal.width ?? fallbackWidth
        let height = ceil(MediaGridViewModel.calculateHeight(for: attachments, gridWidth: width))
        return CGSize(width: width, height: max(10, height))
    }

    private func configure(_ uiView: MediaGridUIView, parentViewController: UIViewController) {
        uiView.configure(
            tweet: parentTweet,
            attachments: attachments,
            isEmbedded: isEmbedded,
            cellTweetId: cellTweetId,
            shouldLoadVideo: shouldLoadVideo,
            parentViewController: parentViewController
        )
        uiView.isGridVisible = isVisible
        uiView.setNeedsLayout()
    }
}

private extension UIView {
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController
            }
            responder = next
        }
        return nil
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .topMostPresentedViewController
    }
}

private extension UIViewController {
    var topMostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostPresentedViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostPresentedViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topMostPresentedViewController
        }
        return self
    }
}

// MARK: - Zoomable View
struct ZoomableView<Content: View>: View {
    let content: Content
    @Binding var scale: CGFloat
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    init(scale: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._scale = scale
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            content
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                scale = min(max(scale * delta, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                            },
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    let newOffset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                    // Limit the offset based on scale
                                    let maxOffset = (scale - 1) * geometry.size.width / 2
                                    offset = CGSize(
                                        width: min(max(newOffset.width, -maxOffset), maxOffset),
                                        height: min(max(newOffset.height, -maxOffset), maxOffset)
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2
                        }
                    }
                }
                .allowsHitTesting(scale > 1) // Only allow zoom gestures when zoomed in
        }
    }
}

// MARK: - MediaGridViewModel
struct MediaGridViewModel {
    /// Calculate precise height for MediaGrid given attachments and actual grid width
    /// Use this when you know the exact available width (e.g., from view bounds or constraints)
    static func calculateHeight(for attachments: [MimeiFileType], gridWidth: CGFloat) -> CGFloat {
        guard !attachments.isEmpty else { return 0 }

        let gridAspectRatio = aspectRatio(for: attachments)
        let gridHeight = max(10, gridWidth / gridAspectRatio)

        return gridHeight
    }

    /// Calculate precise height for MediaGrid given attachments and whether it's embedded
    /// This uses screen-width-based estimates - prefer the gridWidth variant when actual width is known
    @MainActor
    static func calculateHeight(
        for attachments: [MimeiFileType],
        isEmbedded: Bool,
        cellHorizontalPadding: CGFloat = 16
    ) -> CGFloat {
        guard !attachments.isEmpty else { return 0 }

        return calculateHeight(
            for: attachments,
            gridWidth: defaultGridWidth(
                isEmbedded: isEmbedded,
                cellHorizontalPadding: cellHorizontalPadding
            )
        )
    }

    @MainActor
    static func defaultGridWidth(
        isEmbedded: Bool,
        cellHorizontalPadding: CGFloat = 16
    ) -> CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let regularContentColumnWidth = screenWidth
            - cellHorizontalPadding
            - 3  // mainStack leading
            - 42 // avatar
            - 4  // avatar/content spacing
        let mediaTrailingInset: CGFloat = 2

        if isEmbedded {
            // Embedded media sits inside the embedded tweet content stack:
            // regular content column + embedded wrapper extension (4)
            // - embedded content insets (8 + 8) - media trailing inset.
            return max(10, regularContentColumnWidth + 4 - 16 - mediaTrailingInset)
        }

        return max(10, regularContentColumnWidth - mediaTrailingInset)
    }

    /// Get aspect ratio for an attachment, detecting from cached image if nil
    /// STABILITY: Once aspect ratio is determined, it's cached to prevent layout shifts
    static func getAspectRatio(for attachment: MimeiFileType) -> Float {
        // CRITICAL: Always prefer server-provided aspect ratio to prevent layout shifts
        // Only fall back to detection if absolutely necessary AND only once per attachment
        if let ar = attachment.aspectRatio, ar > 0 {
            return ar
        }
        
        // For images without aspect ratio, use a stable default instead of detecting
        // This prevents layout shifts when images load asynchronously
        // The .fill content mode will handle any aspect ratio differences gracefully
        if attachment.type == .image {
            // Use 1.0 square as default for images without aspect ratio
            return 1.0
        }
        
        // For videos without aspect ratio, default to 16:9 (standard video format)
        if attachment.type == .video || attachment.type == .hls_video {
            return 16.0 / 9.0
        }
        
        // Default square aspect ratio for other media types
        return 1.0
    }
    
    static func aspectRatio(for attachments: [MimeiFileType]) -> CGFloat {
        // Clamp aspect ratios between 0.8 (tallest) and 1.618 (widest, golden ratio)
        // This prevents extreme layouts that are too narrow or too wide
        let minAspectRatio: CGFloat = 0.8
        let maxAspectRatio: CGFloat = 1.618
        
        switch attachments.count {
        case 1:
            let ar = getAspectRatio(for: attachments[0])
            if ar > 0 {
                if ar < 0.9 {
                    return max(minAspectRatio, 0.9) // Portrait aspect ratio
                } else {
                    return min(max(CGFloat(ar), minAspectRatio), maxAspectRatio) // Clamped
                }
            } else {
                return maxAspectRatio // Golden ratio when no aspect ratio is available
            }
        case 2:
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let isPortrait0 = ar0 < 1
            let isPortrait1 = ar1 < 1
            let isLandscape0 = ar0 > 1
            let isLandscape1 = ar1 > 1
            if isPortrait0 && isPortrait1 {
                // Both portrait: horizontal layout, square grid
                return 1.0
            } else if isLandscape0 && isLandscape1 {
                // Both landscape: vertical layout
                return max(0.8, minAspectRatio)  // Clamped to min
            } else {
                // Mixed: one portrait, one landscape
                // Calculate and clamp dynamic aspect ratio
                let totalIdealWidth = ar0 + ar1
                return min(max(CGFloat(totalIdealWidth), minAspectRatio), maxAspectRatio)
            }
        case 4:
            // Get aspect ratios - detect from cached images if nil
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let ar2 = getAspectRatio(for: attachments[2])
            let ar3 = getAspectRatio(for: attachments[3])
            
            // Check orientation: portrait < 1.0, landscape > 1.0
            let allPortrait = ar0 < 1.0 && ar1 < 1.0 && ar2 < 1.0 && ar3 < 1.0
            let allLandscape = ar0 > 1.0 && ar1 > 1.0 && ar2 > 1.0 && ar3 > 1.0
            
            if allLandscape {
                return min(maxAspectRatio, 1.618)  // Clamped
            } else if allPortrait {
                return max(minAspectRatio, 0.8)  // Clamped
            } else {
                return 1.0  // Square for mixed orientations
            }
        default:
            // For 5+ attachments, only show first 4 in grid
            // Use first 4 to determine grid aspect ratio (matches Android behavior)
            guard attachments.count >= 4 else {
                // Case 3 - handled by MediaGridView body separately
                return 1.0
            }
            
            // Get aspect ratios of first 4 items
            let ar0 = getAspectRatio(for: attachments[0])
            let ar1 = getAspectRatio(for: attachments[1])
            let ar2 = getAspectRatio(for: attachments[2])
            let ar3 = getAspectRatio(for: attachments[3])
            
            // Check orientation of first 4: portrait < 1.0, landscape > 1.0
            let allPortrait = ar0 < 1.0 && ar1 < 1.0 && ar2 < 1.0 && ar3 < 1.0
            let allLandscape = ar0 > 1.0 && ar1 > 1.0 && ar2 > 1.0 && ar3 > 1.0
            
            if allLandscape {
                return min(maxAspectRatio, 1.618)  // Clamped golden ratio for all landscape
            } else if allPortrait {
                return max(minAspectRatio, 0.8)  // Clamped tall for all portrait
            } else {
                return 1.0  // Square for mixed orientations
            }
        }
    }
}
