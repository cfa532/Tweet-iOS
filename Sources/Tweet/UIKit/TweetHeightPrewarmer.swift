import UIKit

/// Global singleton that pre-computes tweet text heights as tweets arrive from
/// the network or CoreData cache. Uses TextKit1 (NSLayoutManager + boundingRect)
/// off the main thread — safe and within ~0–1 pt of UILabel/TextKit2.
///
/// Usage:
///   • Set standardContentWidth once at app start (main thread).
///   • Call prewarm(_:) each time a Tweet is decoded from network/cache.
///   • TweetTableViewController.estimatedHeightForRowAt queries get(tweetId:width:).
final class TweetHeightPrewarmer: @unchecked Sendable {
    static let shared = TweetHeightPrewarmer()
    private init() {}

    /// Content width for the standard feed layout.
    /// Formula: UIScreen.main.bounds.width - leadingPadding - trailingPadding - 3 - 46 - 4
    ///          = screenWidth - 69 (assuming default 8+8 cell padding).
    /// Set from the main thread before the first feed render.
    private let lock = NSLock()
    private var _standardContentWidth: CGFloat = 0
    private var cache: [String: CGFloat] = [:]  // "mid:\(Int(width))" → text height
    var standardContentWidth: CGFloat {
        get {
            lock.lock(); defer { lock.unlock() }
            return _standardContentWidth
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _standardContentWidth = newValue
        }
    }

    // MARK: - Public API

    func get(tweetId: String, width: CGFloat) -> CGFloat? {
        let key = cacheKey(tweetId: tweetId, width: width)
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// Called right after a tweet is decoded from network data or CoreData.
    /// Enqueues a background measurement if the text height is not yet cached.
    @MainActor
    func prewarm(_ tweet: Tweet) {
        let width = standardContentWidth
        guard width > 1 else { return }
        prewarm(tweet, width: width, priority: .background)
    }

    /// Called from TweetTableViewController when new tweets arrive while scrolling.
    /// Uses .utility priority so measurements finish before scroll stops.
    @MainActor
    func prewarmFeedTweets(_ tweets: [Tweet], contentWidth: CGFloat) {
        guard contentWidth > 1 else { return }
        for tweet in tweets {
            prewarm(tweet, width: contentWidth, priority: .utility)

            // A quote renders its original below the quoting body at a narrower width. Warm
            // that exact width too; otherwise the outer row has an authoritative estimate
            // while the embedded card changes from a rough guess as it enters the viewport.
            let hasOwnContent = (tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (tweet.attachments?.isEmpty == false)
            if hasOwnContent,
               let originalTweetId = tweet.originalTweetId,
               let embeddedTweet = Tweet.getInstance(for: originalTweetId),
               embeddedTweet.author != nil {
                prewarm(embeddedTweet, width: contentWidth - 12, priority: .utility)
            }
        }
    }

    // MARK: - Internal

    func set(_ height: CGFloat, tweetId: String, width: CGFloat) {
        let key = cacheKey(tweetId: tweetId, width: width)
        lock.lock(); defer { lock.unlock() }
        cache[key] = height
    }

    /// Removes estimates for every width when a tweet's text changes.
    func invalidate(tweetId: String) {
        let prefix = "\(tweetId):"
        lock.lock(); defer { lock.unlock() }
        for key in cache.keys.filter({ $0.hasPrefix(prefix) }) {
            cache.removeValue(forKey: key)
        }
    }

    private func cacheKey(tweetId: String, width: CGFloat) -> String {
        "\(tweetId):\(Int(width))"
    }

    @MainActor
    private func prewarm(_ tweet: Tweet, width: CGFloat, priority: TaskPriority) {
        // Resolve display tweet (pure retweet → measure the original's content).
        let isRetweet = tweet.originalTweetId != nil && tweet.originalAuthorId != nil
        let hasOwnContent = (tweet.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (tweet.attachments?.isEmpty == false)
        let isPureRetweet = isRetweet && !hasOwnContent

        let displayTweet: Tweet
        if isPureRetweet, let oid = tweet.originalTweetId,
           let orig = Tweet.getInstance(for: oid), orig.author != nil {
            displayTweet = orig
        } else {
            displayTweet = tweet
        }

        guard let content = displayTweet.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Skip if UILabel-accurate height already on the tweet (textCacheWarm path is faster).
        if displayTweet.cachedMeasuredTextHeight >= 0,
           displayTweet.cachedMeasuredTextWidth == width { return }

        let mid = displayTweet.mid
        if let cachedHeight = get(tweetId: mid, width: width) {
            // Tweet singletons can be recreated after memory trimming while this global cache
            // survives. Re-publish the authoritative value so the new model does not fall back
            // to a different visible-row measurement during reverse scrolling.
            displayTweet.cachedMeasuredTextHeight = cachedHeight
            displayTweet.cachedMeasuredTextWidth = width
            return
        }

        let cache = self
        Task.detached(priority: priority) {
            let attrStr = TweetBodyUIView.makeContentAttributedStringBackground(
                content: content, availableWidth: width
            )
            let bounds = attrStr.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let height = ceil(bounds.height)

            // Keep the prewarmed height authoritative for both UITableView's estimate and
            // its first displayed height. Publishing only the immutable numeric result avoids
            // sending the background-built attributed string across the actor boundary; the
            // visible cell still builds the final UILabel/"More..." text on the main actor.
            await MainActor.run {
                guard let tweet = Tweet.getInstance(for: mid),
                      tweet.content == content,
                      tweet.cachedMeasuredTextWidth != width || tweet.cachedMeasuredTextHeight < 0 else {
                    return
                }
                tweet.cachedMeasuredTextHeight = height
                tweet.cachedMeasuredTextWidth = width
                cache.set(height, tweetId: mid, width: width)
            }
        }
    }
}
