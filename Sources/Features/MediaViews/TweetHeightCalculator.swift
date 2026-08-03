//
//  TweetHeightCalculator.swift
//  Tweet
//
//  Pre-calculate tweet heights to eliminate scroll jumps during fast scrolling
//  Heights are calculated based on tweet content without requiring view rendering
//

import UIKit
import SwiftUI

/// Tweet height calculator that pre-calculates heights from main-actor Tweet models.
@MainActor
final class TweetHeightCalculator {
    static let shared = TweetHeightCalculator()
    
    // Cache of calculated heights
    private var heightCache: [String: CGFloat] = [:]
    private let cacheLock = NSLock()
    
    // Screen width for calculations (accounting for padding)
    private let screenWidth = UIScreen.main.bounds.width
    private let horizontalPadding: CGFloat = 16 // Leading + trailing padding from TweetTableViewController
    
    // Constants matching TweetRowView layout (approximate values)
    private let avatarSize: CGFloat = 48
    private let avatarToContentSpacing: CGFloat = 12
    private let verticalPadding: CGFloat = 12
    private let contentTopPadding: CGFloat = 4
    private let contentBottomPadding: CGFloat = 4
    private let actionButtonsHeight: CGFloat = 44
    private let retweetHeaderHeight: CGFloat = 20
    
    private init() {}
    
    /// Get cached height or calculate it
    func getHeight(for tweet: Tweet, leadingPadding: CGFloat = 8, trailingPadding: CGFloat = 8) -> CGFloat {
        // Check cache first (thread-safe)
        cacheLock.lock()
        if let cached = heightCache[tweet.mid] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        // Calculate and cache
        let height = calculateHeight(for: tweet, leadingPadding: leadingPadding, trailingPadding: trailingPadding)
        
        cacheLock.lock()
        heightCache[tweet.mid] = height
        cacheLock.unlock()
        
        return height
    }
    
    /// Pre-calculate heights for multiple tweets
    func precalculateHeights(for tweets: [Tweet], leadingPadding: CGFloat = 8, trailingPadding: CGFloat = 8) {
        for tweet in tweets {
            cacheLock.lock()
            let needsCalculation = heightCache[tweet.mid] == nil
            cacheLock.unlock()
            
            if needsCalculation {
                let height = calculateHeight(for: tweet, leadingPadding: leadingPadding, trailingPadding: trailingPadding)
                
                cacheLock.lock()
                heightCache[tweet.mid] = height
                cacheLock.unlock()
            }
        }
    }
    
    /// Clear cache for specific tweets
    func clearCache(for tweetIds: [String]) {
        cacheLock.lock()
        for id in tweetIds {
            heightCache.removeValue(forKey: id)
        }
        cacheLock.unlock()
    }
    
    /// Clear entire cache
    func clearAllCache() {
        cacheLock.lock()
        heightCache.removeAll()
        cacheLock.unlock()
    }
    
    /// Calculate height for a tweet based on its content
    private func calculateHeight(for tweet: Tweet, leadingPadding: CGFloat, trailingPadding: CGFloat) -> CGFloat {
        var totalHeight: CGFloat = 0
        
        // Top padding
        totalHeight += verticalPadding
        
        // Main content area width (screen width - horizontal padding - avatar - spacing)
        let contentWidth = screenWidth - horizontalPadding - leadingPadding - trailingPadding - avatarSize - avatarToContentSpacing
        
        // Author name + username line (~20pt for single line)
        totalHeight += 20 + contentTopPadding
        
        // Tweet text (using content property)
        if let text = tweet.content, !text.isEmpty {
            let textHeight = calculateTextHeight(text: text, maxWidth: contentWidth, fontSize: 15)
            totalHeight += textHeight + 8 // 8pt spacing after text
        }
        
        // Title if present
        if let title = tweet.title, !title.isEmpty {
            let titleHeight = calculateTextHeight(text: title, maxWidth: contentWidth, fontSize: 17, weight: .semibold)
            totalHeight += titleHeight + 8
        }
        
        // Media attachments
        if let attachments = tweet.attachments, !attachments.isEmpty {
            let mediaAttachments = attachments.filter { 
                $0.type == .image || $0.type == .video || $0.type == .hls_video 
            }
            if !mediaAttachments.isEmpty {
                let mediaHeight = calculateMediaHeight(attachments: mediaAttachments, maxWidth: contentWidth)
                totalHeight += mediaHeight + 8 // 8pt spacing after media
            }
            
            // Document attachments (PDFs, Word, Excel, etc.)
            let documentCount = attachments.filter { 
                $0.type == .pdf || $0.type == .word || $0.type == .excel || 
                $0.type == .ppt || $0.type == .zip || $0.type == .txt || $0.type == .html
            }.count
            if documentCount > 0 {
                let documentHeight: CGFloat = CGFloat(documentCount) * 60 // ~60pt per document
                totalHeight += documentHeight + 8
            }
        }
        
        // Action buttons
        totalHeight += actionButtonsHeight
        
        // Bottom padding
        totalHeight += contentBottomPadding + verticalPadding
        
        // Round up to avoid fractional pixels
        return ceil(totalHeight)
    }
    
    /// Calculate height for text content
    private func calculateTextHeight(text: String, maxWidth: CGFloat, fontSize: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        
        return ceil(boundingRect.height)
    }
    
    /// Calculate height for media grid
    private func calculateMediaHeight(attachments: [MimeiFileType], maxWidth: CGFloat) -> CGFloat {
        guard !attachments.isEmpty else { return 0 }
        
        // Use MediaGridViewModel logic to calculate aspect ratio (matches actual rendering)
        let aspectRatio = MediaGridViewModel.aspectRatio(for: attachments)
        
        // Height = width / aspectRatio
        let height = maxWidth / aspectRatio
        
        return ceil(height)
    }
}
