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
    /// Formula: UIScreen.main.bounds.width - leadingPadding - trailingPadding - 3 - 42 - 4
    ///          = screenWidth - 65 (assuming default 8+8 cell padding).
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
        }
    }

    // MARK: - Internal

    func set(_ height: CGFloat, tweetId: String, width: CGFloat) {
        let key = cacheKey(tweetId: tweetId, width: width)
        lock.lock(); defer { lock.unlock() }
        cache[key] = height
    }

    private func cacheKey(tweetId: String, width: CGFloat) -> String {
        "\(tweetId):\(Int(width))"
    }

    private func isCached(tweetId: String, width: CGFloat) -> Bool {
        let key = cacheKey(tweetId: tweetId, width: width)
        lock.lock(); defer { lock.unlock() }
        return cache[key] != nil
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
        guard !isCached(tweetId: mid, width: width) else { return }

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
            cache.set(ceil(bounds.height), tweetId: mid, width: width)
        }
    }
}
