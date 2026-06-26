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
    @Published var tweets: [Tweet] = []     // tweet list to be displayed on screen.
    @Published var isLoading: Bool = false
    @Published var isPeriodicFeedRefreshActive: Bool = false
    @Published var showTweetDetail: Bool = false
    @Published var selectedTweet: Tweet?
    @Published var pendingNewTweets: [Tweet] = []
    @Published var showNewTweetsBanner: Bool = false
    let hproseInstance: HproseInstance
    private let pageZeroFetchGate = PageZeroFetchGate()
    
    // Shared instance to keep tweets in memory across navigation
    static let shared = FollowingsTweetViewModel(hproseInstance: HproseInstance.shared)
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }

    func performForegroundFeedRefresh() async {
        await performPeriodicFeedRefresh(reason: "foreground feed refresh", pageSize: 10)
    }

    func performBackgroundFeedCheck() async {
        await performPeriodicFeedRefresh(reason: "background main feed check", pageSize: 10)
    }

    private func performPeriodicFeedRefresh(reason: String, pageSize: UInt) async {
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

        do {
            print("DEBUG: [FollowingsTweetViewModel] \(reason)")
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
            let freshTweets = try await fetchTopMainFeedTweetsForBanner(pageSize: pageSize)
            await MainActor.run {
                updateNewTweetsSnapshot(freshTweets)
            }
        } catch {
            print("ERROR: [FollowingsTweetViewModel] \(reason) failed: \(error)")
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
            !(tweet.isPrivate ?? false)
            && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
            && !visibleTweetIds.contains(tweet.mid)
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
            !(tweet.isPrivate ?? false)
            && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
            && !visibleTweetIds.contains(tweet.mid)
        }
        let snapshot = newTweets.sorted { $0.timestamp > $1.timestamp }

        pendingNewTweets = snapshot
        showNewTweetsBanner = !snapshot.isEmpty

        let cacheKey = hproseInstance.appUser.mid
        for tweet in snapshot {
            TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
        }
        print("DEBUG: [FollowingsTweetViewModel] New tweet banner snapshot: \(snapshot.count) unrendered candidate(s)")
    }

    @MainActor
    private func deferNewTopPageTweetsBehindBannerIfNeeded(_ incomingTweets: [Tweet], reason: String) -> (tweetsToMerge: [Tweet], deferredTweetIds: Set<String>) {
        let shouldDeferNewTweets = isPeriodicFeedRefreshActive
        guard shouldDeferNewTweets else {
            return (incomingTweets, [])
        }

        let visibleTweetIds = Set(tweets.map(\.mid))
        let deferrableTweets = incomingTweets.filter { tweet in
            !(tweet.isPrivate ?? false)
            && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
            && !visibleTweetIds.contains(tweet.mid)
        }

        updateNewTweetsSnapshot(deferrableTweets)

        let pendingTweetIds = Set(pendingNewTweets.map(\.mid))
        let deferredTweetIds = Set(deferrableTweets.map(\.mid)).intersection(pendingTweetIds)
        guard !deferredTweetIds.isEmpty else {
            return (incomingTweets, [])
        }

        let tweetsToMerge = incomingTweets.filter { tweet in
            !deferredTweetIds.contains(tweet.mid)
        }
        print("DEBUG: [FollowingsTweetViewModel] Deferred \(deferredTweetIds.count) top-page tweet(s) behind banner during \(reason)")
        return (tweetsToMerge, deferredTweetIds)
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
            !(tweet.isPrivate ?? false)
            && !TweetDeletionRegistry.shared.isDeleted(tweet.mid)
            && !visibleTweetIds.contains(tweet.mid)
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

    private func fetchTopMainFeedTweetsForBanner(pageSize: UInt) async throws -> [Tweet] {
        guard !hproseInstance.appUser.isGuest else { return [] }

        let serverTweets = try await hproseInstance.fetchTweetFeed(
            user: hproseInstance.appUser,
            pageNumber: 0,
            pageSize: pageSize
        )
        let feedTweets = serverTweets.compactMap { $0 }

        let followingTweets = try await hproseInstance.fetchTweetFeed(
            user: hproseInstance.appUser,
            pageNumber: 0,
            pageSize: pageSize,
            entry: "update_following_tweets"
        )
        let updatedFollowingTweets = followingTweets.compactMap { $0 }
        print("DEBUG: [FollowingsTweetViewModel] Banner check candidates: get_tweet_feed=\(feedTweets.count), update_following_tweets=\(updatedFollowingTweets.count)")
        return feedTweets + updatedFollowingTweets
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
                if let adminUser = try await hproseInstance.fetchUser(Gadget.getAlphaIds().first ?? "") {
                    let serverTweets = try await hproseInstance.fetchUserTweets(user: adminUser, pageNumber: page, pageSize: pageSize)
                    print("[HproseInstance] Loaded \(serverTweets.compactMap { $0 }.count) tweets for guest user")
                    await MainActor.run {
                        tweets.mergeTweets(serverTweets.compactMap{ $0 })
                    }
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
            let serverTweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser,
                pageNumber: page,
                pageSize: pageSize
            )
            print("🌐 [API RESPONSE] Received \(serverTweets.count) items (including nils)")
            let filteredTweets = serverTweets.compactMap{ $0 }
            print("🌐 [API RESPONSE] After filtering: \(filteredTweets.count) valid tweets")
            
            // Check for any private tweets that might have slipped through
            for tweet in filteredTweets {
                if tweet.isPrivate == true {
                    print("WARNING: [FollowingsTweetViewModel] Private tweet found in feed: \(tweet.mid) by user: \(tweet.authorId)")
                }
            }
            
            let responseTweets = await MainActor.run { () -> [Tweet?] in
                let split: (tweetsToMerge: [Tweet], deferredTweetIds: Set<String>)
                if page == 0 {
                    split = deferNewTopPageTweetsBehindBannerIfNeeded(filteredTweets, reason: "server page 0 refresh")
                } else {
                    split = (filteredTweets, [])
                }

                if !split.tweetsToMerge.isEmpty {
                    tweets.mergeTweets(split.tweetsToMerge)
                }

                guard !split.deferredTweetIds.isEmpty else {
                    return serverTweets
                }

                return serverTweets.map { tweet in
                    guard let tweet else { return nil }
                    return split.deferredTweetIds.contains(tweet.mid) ? nil : tweet
                }
            }
            
            // Cache main feed tweets under appUser.mid for efficient loading
            let cacheKey = hproseInstance.appUser.mid
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
            return responseTweets     // including nil
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            print("❌ [SERVER FETCH] fetchTweets FAILED in \(String(format: "%.1f", elapsed))ms: \(error)")
            throw error
        }
    }

    private func refreshFollowingTweets(pageSize: UInt) {
        Task { [weak self] in
            guard let self = self else { return }
            await self.refreshFollowingTweetsAsync(pageSize: pageSize)
        }
    }

    private func refreshFollowingTweetsAsync(pageSize: UInt) async {
        do {
            let newTweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser,
                pageNumber: 0,
                pageSize: pageSize,
                entry: "update_following_tweets"
            )
            let filteredTweets = newTweets.compactMap { $0 }
            guard !filteredTweets.isEmpty else { return }

            await MainActor.run {
                let split = deferNewTopPageTweetsBehindBannerIfNeeded(filteredTweets, reason: "update_following_tweets")
                if !split.tweetsToMerge.isEmpty {
                    tweets.mergeTweets(split.tweetsToMerge)
                }
            }

            let cacheKey = hproseInstance.appUser.mid
            for tweet in filteredTweets {
                TweetCacheManager.shared.saveTweet(tweet, userId: cacheKey)
            }
            print("DEBUG: [FollowingsTweetViewModel] Merged \(filteredTweets.count) newly synced following tweets")
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
                
                // Cache new tweets in main feed under appUser.mid
                TweetCacheManager.shared.saveTweet(tweet, userId: hproseInstance.appUser.mid)
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
        TweetCacheManager.shared.deleteTweetsFromUser(userId: userId, cacheKey: hproseInstance.appUser.mid)
    }
    
    // Fetch and add recent tweets from a newly followed user
    func addTweetsFromNewlyFollowedUser(_ user: User) async {
        do {
            print("[FollowingsTweetViewModel] Fetching recent tweets from newly followed user: \(user.mid)")
            
            // Fetch first page of user's tweets (10 tweets should be enough for initial display)
            let userTweets = try await hproseInstance.fetchUserTweets(
                user: user,
                pageNumber: 0,
                pageSize: 10
            )
            
            // Filter out nils and private tweets
            let validTweets = userTweets.compactMap { $0 }.filter { !($0.isPrivate ?? false) }
            
            print("[FollowingsTweetViewModel] Got \(validTweets.count) valid tweets from newly followed user \(user.mid)")
            
            if !validTweets.isEmpty {
                await MainActor.run {
                    // Add tweets to the feed (mergeTweets will sort them by timestamp)
                    tweets.mergeTweets(validTweets)
                }
                
                // Cache newly followed user's tweets under appUser.mid for main feed
                let cacheKey = hproseInstance.appUser.mid
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
