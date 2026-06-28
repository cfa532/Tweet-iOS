//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/6/4.
//

import AVFoundation
import UIKit

private actor PageZeroFetchGate {
    private var isInFlight = false

    func tryBegin(page: UInt) -> Bool {
        guard page == 0 else { return true }
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    func end(page: UInt) {
        guard page == 0 else { return }
        isInFlight = false
    }
}

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    private static let followingTweetsBannerEntry = "update_following_tweets"

    @Published var tweets: [Tweet] = []     // tweet list to be displayed on screen.
    @Published var isLoading: Bool = false
    @Published var isPeriodicFeedRefreshActive: Bool = false
    @Published var showTweetDetail: Bool = false
    @Published var selectedTweet: Tweet?
    @Published var pendingNewTweets: [Tweet] = []
    @Published var showNewTweetsBanner: Bool = false
    let hproseInstance: HproseInstance
    private let pageZeroFetchGate = PageZeroFetchGate()
    private var isMainFeedAtTop: Bool = true
    private var isMainFeedScrollInteractionActive: Bool = false
    
    // Shared instance to keep tweets in memory across navigation
    static let shared = FollowingsTweetViewModel(hproseInstance: HproseInstance.shared)
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }

    func performForegroundFeedRefresh() async {
        await performFeedRefreshPair(
            reason: "foreground feed refresh",
            pageSize: 5,
            renderGetTweetFeedUsingScrollState: true
        )
    }

    func performBackgroundFeedCheck() async {
        await performFeedRefreshPair(
            reason: "background main feed check",
            pageSize: 5,
            renderGetTweetFeedUsingScrollState: false
        )
    }

    private func performFeedRefreshPair(
        reason: String,
        pageSize: UInt,
        renderGetTweetFeedUsingScrollState: Bool
    ) async {
        let didBegin = await MainActor.run {
            guard !isPeriodicFeedRefreshActive else { return false }
            isPeriodicFeedRefreshActive = true
            return true
        }
        guard didBegin else {
            print("DEBUG: [FollowingsTweetViewModel] Skipping duplicate \(reason)")
            return
        }
        defer {
            Task { @MainActor [weak self] in
                self?.isPeriodicFeedRefreshActive = false
            }
        }

        print("DEBUG: [FollowingsTweetViewModel] \(reason) via get_tweet_feed + update_following_tweets")
        guard await waitForAppInitializationIfNeeded(reason: reason) else {
            return
        }
        guard !hproseInstance.appUser.isGuest else {
            await MainActor.run {
                pendingNewTweets.removeAll()
                showNewTweetsBanner = false
            }
            print("DEBUG: [FollowingsTweetViewModel] Skipping \(reason) for guest user")
            return
        }

        do {
            let freshTweets = try await fetchForegroundMainFeedTweets(pageSize: pageSize)
            await MainActor.run {
                processForegroundMainFeedTweets(
                    freshTweets,
                    renderImmediately: renderGetTweetFeedUsingScrollState && shouldRenderForegroundMainFeedTweetsImmediately(),
                    reason: "\(reason) get_tweet_feed"
                )
            }
        } catch {
            print("ERROR: [FollowingsTweetViewModel] \(reason) get_tweet_feed failed: \(error)")
        }

        do {
            let followingTweets = try await fetchFollowingTweetsForBanner(pageSize: pageSize)
            await MainActor.run {
                updateNewTweetsSnapshot(followingTweets)
            }
        } catch {
            print("ERROR: [FollowingsTweetViewModel] \(reason) update_following_tweets failed: \(error)")
        }
    }

    private func waitForAppInitializationIfNeeded(reason: String) async -> Bool {
        guard !hproseInstance.isAppInitialized else { return true }

        print("DEBUG: [FollowingsTweetViewModel] Waiting for app initialization before \(reason)")
        var waitCount = 0
        while !hproseInstance.isAppInitialized && waitCount < 100 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }

        if hproseInstance.isAppInitialized {
            print("DEBUG: [FollowingsTweetViewModel] App initialization ready after \(waitCount * 100)ms for \(reason)")
            return true
        }

        print("ERROR: [FollowingsTweetViewModel] Skipping \(reason) because app initialization did not finish")
        return false
    }

    private func beginPageZeroFetchIfNeeded(page: UInt, isPeriodicRefresh: Bool) async -> Bool {
        guard page == 0 else { return true }

        while !Task.isCancelled {
            if await pageZeroFetchGate.tryBegin(page: page) {
                return true
            }

            if isPeriodicRefresh {
                print("DEBUG: [FollowingsTweetViewModel] Skipping duplicate periodic page 0 fetch")
                return false
            }

            print("DEBUG: [FollowingsTweetViewModel] Waiting for in-flight page 0 fetch before direct refresh")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return false
    }

    private func endPageZeroFetchIfNeeded(page: UInt) {
        guard page == 0 else { return }

        let gate = pageZeroFetchGate
        Task {
            await gate.end(page: page)
        }
    }

    @MainActor
    var visiblePendingNewTweets: [Tweet] {
        let visibleTweetIds = Set(tweets.map(\.mid))
        return pendingNewTweets.filter { tweet in
            isPendingNewFeedTweet(tweet, visibleTweetIds: visibleTweetIds)
        }
    }

    @MainActor
    private func isNewerThanCurrentFeedTop(_ tweet: Tweet) -> Bool {
        guard let topTweet = tweets.first else { return true }
        if tweet.timestamp == topTweet.timestamp {
            return tweet.mid > topTweet.mid
        }
        return tweet.timestamp > topTweet.timestamp
    }

    @MainActor
    private func isPendingNewFeedTweet(_ tweet: Tweet, visibleTweetIds: Set<String>) -> Bool {
        !(tweet.isPrivate ?? false)
        && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
        && !visibleTweetIds.contains(tweet.mid)
        && isNewerThanCurrentFeedTop(tweet)
    }

    @MainActor
    func updateMainFeedScrollState(isAtTop: Bool, isInteracting: Bool) {
        isMainFeedAtTop = isAtTop
        isMainFeedScrollInteractionActive = isInteracting
    }

    @MainActor
    private func shouldRenderForegroundMainFeedTweetsImmediately() -> Bool {
        !isMainFeedScrollInteractionActive && isMainFeedAtTop
    }

    @MainActor
    private func processForegroundMainFeedTweets(
        _ incomingTweets: [Tweet],
        renderImmediately: Bool,
        reason: String
    ) {
        var seenIncomingTweetIds = Set<String>()
        let uniqueIncomingTweets = incomingTweets.filter { tweet in
            seenIncomingTweetIds.insert(tweet.mid).inserted
        }
        let visibleIncomingTweets = uniqueIncomingTweets.filter { tweet in
            !(tweet.isPrivate ?? false) && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
        }

        let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
        for tweet in visibleIncomingTweets {
            TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
        }

        let visibleTweetIds = Set(tweets.map(\.mid))
        let newTweets = visibleIncomingTweets
            .filter { tweet in isPendingNewFeedTweet(tweet, visibleTweetIds: visibleTweetIds) }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.mid > rhs.mid
                }
                return lhs.timestamp > rhs.timestamp
            }

        guard !newTweets.isEmpty else {
            print("DEBUG: [FollowingsTweetViewModel] No foreground main feed tweets to render/banner during \(reason)")
            return
        }

        if renderImmediately {
            tweets.mergeTweets(newTweets)
            pendingNewTweets.removeAll { pending in
                newTweets.contains(where: { $0.mid == pending.mid })
            }
            showNewTweetsBanner = !visiblePendingNewTweets.isEmpty
            print("DEBUG: [FollowingsTweetViewModel] Rendered \(newTweets.count) foreground main feed tweet(s) immediately")
        } else {
            let combinedPendingTweets = pendingNewTweets + newTweets
            var seenPendingTweetIds = Set<String>()
            pendingNewTweets = combinedPendingTweets
                .filter { tweet in seenPendingTweetIds.insert(tweet.mid).inserted }
                .sorted { lhs, rhs in
                    if lhs.timestamp == rhs.timestamp {
                        return lhs.mid > rhs.mid
                    }
                    return lhs.timestamp > rhs.timestamp
                }
            showNewTweetsBanner = !visiblePendingNewTweets.isEmpty
            print("DEBUG: [FollowingsTweetViewModel] Staged \(newTweets.count) foreground main feed tweet(s) behind banner")
        }
    }

    @MainActor
    private func updateNewTweetsSnapshot(_ incomingTweets: [Tweet]) {
        var seenIncomingTweetIds = Set<String>()
        let uniqueIncomingTweets = incomingTweets.filter { tweet in
            seenIncomingTweetIds.insert(tweet.mid).inserted
        }
        let visibleTweetIds = Set(tweets.map(\.mid))
        let newTweets = uniqueIncomingTweets.filter { tweet in
            isPendingNewFeedTweet(tweet, visibleTweetIds: visibleTweetIds)
        }
        let snapshot = newTweets.sorted { $0.timestamp > $1.timestamp }

        pendingNewTweets = snapshot
        showNewTweetsBanner = !snapshot.isEmpty

        let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
        for tweet in snapshot {
            TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
        }
        print("DEBUG: [FollowingsTweetViewModel] New tweet banner snapshot: \(snapshot.count) unrendered candidate(s)")
    }

    @MainActor
    func applyPendingNewTweets() {
        let pendingTweets = visiblePendingNewTweets
        guard !pendingTweets.isEmpty else {
            showNewTweetsBanner = false
            return
        }

        let visibleTweetIds = Set(tweets.map(\.mid))
        let tweetsToApply = pendingTweets.filter { tweet in
            isPendingNewFeedTweet(tweet, visibleTweetIds: visibleTweetIds)
        }
        let staleCount = pendingTweets.count - tweetsToApply.count

        if !tweetsToApply.isEmpty {
            tweets.mergeTweets(tweetsToApply)
        }
        pendingNewTweets.removeAll()
        showNewTweetsBanner = false
        print("DEBUG: [FollowingsTweetViewModel] Applied \(tweetsToApply.count) pending main feed tweet(s), dropped \(staleCount) stale")
    }

    @MainActor
    func dismissNewTweetsBanner() {
        showNewTweetsBanner = false
    }

    @MainActor
    func clearPendingNewTweetsBanner(reason: String) {
        guard showNewTweetsBanner || !pendingNewTweets.isEmpty else { return }
        pendingNewTweets.removeAll()
        showNewTweetsBanner = false
        print("DEBUG: [FollowingsTweetViewModel] Cleared pending new tweets banner: \(reason)")
    }

    private func fetchFollowingTweetsForBanner(pageSize: UInt) async throws -> [Tweet] {
        guard !hproseInstance.appUser.isGuest else { return [] }

        let hproseInstance = hproseInstance
        let appUser = hproseInstance.appUser
        let followingTweets = try await Task.detached(priority: .utility) {
            try await hproseInstance.fetchTweetFeed(
                user: appUser,
                pageNumber: 0,
                pageSize: pageSize,
                entry: Self.followingTweetsBannerEntry
            )
        }.value
        let updatedFollowingTweets = followingTweets.compactMap { $0 }
        print("DEBUG: [FollowingsTweetViewModel] Banner candidates from \(Self.followingTweetsBannerEntry)=\(updatedFollowingTweets.count)")
        return updatedFollowingTweets
    }

    private func fetchForegroundMainFeedTweets(pageSize: UInt) async throws -> [Tweet] {
        let hproseInstance = hproseInstance
        let appUser = hproseInstance.appUser
        let serverTweets = try await Task.detached(priority: .utility) {
            try await hproseInstance.fetchTweetFeed(
                user: appUser,
                pageNumber: 0,
                pageSize: pageSize
            )
        }.value
        let filteredTweets = serverTweets.compactMap { $0 }
        print("DEBUG: [FollowingsTweetViewModel] Foreground get_tweet_feed returned \(filteredTweets.count) valid tweet(s)")
        return filteredTweets
    }
    
    func fetchTweets(page: UInt, pageSize: UInt, isPeriodicRefresh: Bool = false) async throws -> [Tweet?] {
        guard await beginPageZeroFetchIfNeeded(page: page, isPeriodicRefresh: isPeriodicRefresh) else {
            return []
        }
        defer {
            endPageZeroFetchIfNeeded(page: page)
        }

        let startTime = Date()
        print("🌐 [SERVER FETCH] fetchTweets START - page: \(page), pageSize: \(pageSize)")
        
        // Wait for app initialization with timeout — don't block forever when server is unreachable.
        // fetchTweetFeed has a built-in cache fallback for !isInitializationComplete,
        // so proceeding after timeout still returns cached tweets instead of hanging.
        if !hproseInstance.isAppInitialized {
            print("⏳ [SERVER FETCH] Waiting for app initialization (max 10s)...")
            var waitCount = 0
            while !hproseInstance.isAppInitialized && waitCount < 100 { // 100 × 100ms = 10s
                try? await Task.sleep(nanoseconds: 100_000_000) // Check every 100ms
                waitCount += 1
            }
            if hproseInstance.isAppInitialized {
                print("✅ [SERVER FETCH] App initialization complete, proceeding with fetch")
            } else {
                print("⚠️ [SERVER FETCH] Timed out waiting for app initialization, proceeding with cache fallback")
            }
        }
        
        // fetch tweets from server
        // Load tweets of alphaId if appUser is a guest user
        if hproseInstance.appUser.isGuest {
            do {
                print("[HproseInstance] Loading tweets for guest user from alphaId")
                let hproseInstance = hproseInstance
                let adminUser = try await Task.detached(priority: .utility) {
                    try await hproseInstance.fetchUser(Gadget.getAlphaIds().first ?? "")
                }.value
                if let adminUser {
                    let serverTweets = try await Task.detached(priority: .utility) {
                        try await hproseInstance.fetchUserTweets(user: adminUser, pageNumber: page, pageSize: pageSize)
                    }.value
                    print("[HproseInstance] Loaded \(serverTweets.compactMap { $0 }.count) tweets for guest user")
                    return serverTweets
                }
            } catch {
                print("[HproseInstance] Error loading tweets for guest user: \(error)")
                throw error
            }
            return []
        }
        
        do {
            /// The backend may return an array containing nils. If the returned array size is less than pageSize, it means there are no more tweets on the backend.
            /// This function accumulates only non-nil tweets and stops fetching when the backend returns fewer than pageSize items.
            print("🌐 [API CALL] fetchTweetFeed - userId: \(hproseInstance.appUser.mid), page: \(page), pageSize: \(pageSize)")
            let hproseInstance = hproseInstance
            let appUser = hproseInstance.appUser
            let serverTweets = try await Task.detached(priority: .utility) {
                try await hproseInstance.fetchTweetFeed(
                    user: appUser,
                    pageNumber: page,
                    pageSize: pageSize
                )
            }.value
            print("🌐 [API RESPONSE] Received \(serverTweets.count) items (including nils)")
            let filteredTweets = serverTweets.compactMap{ $0 }
            print("🌐 [API RESPONSE] After filtering: \(filteredTweets.count) valid tweets")
            
            // Check for any private tweets that might have slipped through
            for tweet in filteredTweets {
                if tweet.isPrivate == true {
                    print("WARNING: [FollowingsTweetViewModel] Private tweet found in feed: \(tweet.mid) by user: \(tweet.authorId)")
                }
            }
            
            // Cache main feed tweets under an explicit list key for efficient loading.
            let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
            for tweet in serverTweets.compactMap({ $0 }) {
                TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
            }
            if page == 0 {
                if isPeriodicRefresh {
                    await refreshFollowingTweetsAsync(pageSize: pageSize)
                } else {
                    refreshFollowingTweets(pageSize: pageSize)
                }
            }
            
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("✅ [SERVER FETCH] fetchTweets COMPLETE - loaded \(serverTweets.compactMap{$0}.count) tweets in \(String(format: "%.1f", elapsed))ms")
            return serverTweets     // including nil
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("❌ [SERVER FETCH] fetchTweets FAILED in \(String(format: "%.1f", elapsed))ms: \(error)")
            throw error
        }
    }

    private func refreshFollowingTweets(pageSize: UInt) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.refreshFollowingTweetsAsync(pageSize: pageSize)
        }
    }

    private func refreshFollowingTweetsAsync(pageSize: UInt) async {
        do {
            let hproseInstance = hproseInstance
            let appUser = hproseInstance.appUser
            let newTweets = try await Task.detached(priority: .utility) {
                try await hproseInstance.fetchTweetFeed(
                    user: appUser,
                    pageNumber: 0,
                    pageSize: pageSize,
                    entry: Self.followingTweetsBannerEntry
                )
            }.value
            let filteredTweets = newTweets.compactMap { $0 }
            guard !filteredTweets.isEmpty else { return }

            await MainActor.run {
                updateNewTweetsSnapshot(filteredTweets)
            }

            let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
            for tweet in filteredTweets {
                TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
            }
            print("DEBUG: [FollowingsTweetViewModel] Staged \(filteredTweets.count) newly synced following tweet(s) behind banner")
        } catch {
            print("ERROR: [FollowingsTweetViewModel] update_following_tweets failed: \(error)")
        }
    }
    
    // optimistic UI update
    func handleNewTweet(_ tweet: Tweet?) {
        print("DEBUG: [FollowingsTweetViewModel] handleNewTweet called - tweet: \(tweet?.mid ?? "nil")")
        if let tweet = tweet {
            print("DEBUG: [FollowingsTweetViewModel] Tweet isPrivate: \(tweet.isPrivate ?? false), authorId: \(tweet.authorId)")
            // Don't show private tweets in the home feed
            if !(tweet.isPrivate ?? false) {
                let countBefore = tweets.count
                // For new tweets, use mergeTweets (with sorting) since they should appear at the top
                tweets.mergeTweets([tweet])
                let countAfter = tweets.count
                print("DEBUG: [FollowingsTweetViewModel] Added new tweet to main feed - count: \(countBefore) -> \(countAfter), tweetId: \(tweet.mid)")
                
                // Cache new tweets in the main feed list.
                TweetCacheManager.shared.saveTweet(
                    tweet,
                    userId: TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
                )
            } else {
                print("DEBUG: [FollowingsTweetViewModel] Skipped private tweet: \(tweet.mid)")
            }
        } else {
            print("DEBUG: [FollowingsTweetViewModel] handleNewTweet received nil tweet")
        }
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        TweetDeletionRegistry.shared.markDeleted(tweetId)
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
        // Also remove from main feed cache if it exists there
        // Note: deleteTweet removes by tweet ID, so it will remove from all caches
    }
    
    // Remove all tweets from a specific user (e.g., when unfollowing)
    func removeTweetsFromUser(_ userId: MimeiId) {
        let removedCount = tweets.filter { $0.authorId == userId }.count
        print("[FollowingsTweetViewModel] Removing \(removedCount) tweets from user \(userId)")
        
        // Remove from displayed tweets array
        tweets.removeAll { $0.authorId == userId }
        
        // Remove from local cache
        TweetCacheManager.shared.deleteTweetsFromUser(
            userId: userId,
            cacheKey: TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
        )
    }
    
    // Fetch and add recent tweets from a newly followed user
    func addTweetsFromNewlyFollowedUser(_ user: User) async {
        do {
            print("[FollowingsTweetViewModel] Fetching recent tweets from newly followed user: \(user.mid)")
            
            // Fetch first page of user's tweets (10 tweets should be enough for initial display)
            let hproseInstance = hproseInstance
            let userTweets = try await Task.detached(priority: .utility) {
                try await hproseInstance.fetchUserTweets(
                    user: user,
                    pageNumber: 0,
                    pageSize: 10
                )
            }.value
            
            // Filter out nils and private tweets
            let validTweets = userTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
            
            print("[FollowingsTweetViewModel] Got \(validTweets.count) valid tweets from newly followed user \(user.mid)")
            
            if !validTweets.isEmpty {
                await MainActor.run {
                    // Add tweets to the feed (mergeTweets will sort them by timestamp)
                    tweets.mergeTweets(validTweets)
                }
                
                // Cache newly followed user's tweets in the main feed list.
                let cacheKey = TweetCacheManager.mainFeedCacheKey(appUserId: hproseInstance.appUser.mid)
                for tweet in validTweets {
                    TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
                }
                
                print("[FollowingsTweetViewModel] Added and cached \(validTweets.count) tweets from newly followed user")
            }
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets from newly followed user \(user.mid): \(error)")
        }
    }
    
    func showTweetDetail(_ tweet: Tweet) {
        selectedTweet = tweet
        showTweetDetail = true
    }
    
    // Method to clear tweets when user logs in/out
    func clearTweets() {
        tweets.removeAll()
        // Don't clear cache on logout - cache persists per user and is cleared periodically or manually
    }
}
