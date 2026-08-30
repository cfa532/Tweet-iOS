//
//  BackgroundTweetPrefetcher.swift
//  Tweet
//
//  Warms the main feed's tweet cache while the user is on it.
//
//  The visible list only fetches the page the user has scrolled to. This walks ahead of
//  them — one page at a time, and only while the network is otherwise quiet — so the
//  pages they have not reached yet are already in Core Data when they get there.
//
//  Cache only. It goes through HproseInstance.cacheMainFeedPage, which decodes to
//  TweetRecord and writes Core Data without creating Tweet or User singletons, so a
//  read-ahead page leaves nothing in memory: no objects pinned in Tweet's instance
//  registry, no @Published churn reaching a visible cell, no growth in the feed's array.
//
//  Read-ahead runs until the backend returns a short page. Cache size is bounded by
//  TweetCacheManager's own row cap and 30-day expiry, not by anything here.
//

import Foundation
import UIKit

@MainActor
final class BackgroundTweetPrefetcher {
    static let shared = BackgroundTweetPrefetcher()

    private static let pageSize: UInt = 20
    /// How often to re-check the network while something else is downloading.
    private static let busyPollInterval: Duration = .seconds(3)
    /// Breathing room between two prefetched pages, so a burst of RPCs can never line
    /// up with the user starting to scroll.
    private static let pageInterval: Duration = .seconds(1)
    private static let maxConsecutiveFailures = 3

    /// Whose feed the cursor below belongs to.
    private var appUserId: String?
    /// How far the read-ahead has reached. Session-scoped: it resumes across visits to
    /// the feed and starts over only on `reset()`.
    private var nextPage: UInt = 0
    /// The backend has run out of pages.
    private var isExhausted = false
    private var task: Task<Void, Never>?

    private init() {}

    /// Warm the app user's following feed. Called when the main feed appears.
    func prefetchMainFeed() {
        let appUser = HproseInstance.shared.appUser
        // A guest's main feed is served by fetchUserTweets against the alpha account,
        // not by get_tweet_feed. Prefetching the feed entry for a guest would cache rows
        // under the main-feed key that the visible list never asked for.
        guard !appUser.isGuest else { return }

        if appUserId != appUser.mid {
            appUserId = appUser.mid
            nextPage = 0
            isExhausted = false
            task?.cancel()
            task = nil
        }

        guard !isExhausted, task == nil else { return }

        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    /// Stop and forget the cursor. Called when the session it belongs to ends (logout),
    /// so the next account does not inherit it.
    func reset() {
        task?.cancel()
        task = nil
        appUserId = nil
        nextPage = 0
        isExhausted = false
    }

    // MARK: - The loop

    private func run() async {
        var consecutiveFailures = 0

        while !Task.isCancelled, !isExhausted {
            guard await waitForQuietNetwork() else { return }

            let page = nextPage
            do {
                let rowCount = try await HproseInstance.shared.cacheMainFeedPage(
                    pageNumber: page,
                    pageSize: Self.pageSize
                )
                nextPage = page + 1
                consecutiveFailures = 0
                // A short page is the backend's end-of-feed signal — the same rule
                // TweetListView's pagination uses.
                if rowCount < Int(Self.pageSize) {
                    isExhausted = true
                    print("🧊 [PREFETCH] main feed page \(page) → \(rowCount) row(s), feed exhausted")
                    return
                }
                print("🧊 [PREFETCH] main feed page \(page) → \(rowCount) row(s) cached")
            } catch {
                guard !Task.isCancelled else { return }
                consecutiveFailures += 1
                print("⚠️ [PREFETCH] main feed page \(page) failed (\(consecutiveFailures)/\(Self.maxConsecutiveFailures)): \(error)")
                guard consecutiveFailures < Self.maxConsecutiveFailures else { return }
            }

            do {
                try await Task.sleep(for: Self.pageInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - Traffic gate

    /// Suspends until nothing else is using the network. Returns false if the task was
    /// cancelled while waiting.
    private func waitForQuietNetwork() async -> Bool {
        while !Task.isCancelled {
            if await isTrafficLow() { return true }
            do {
                try await Task.sleep(for: Self.busyPollInterval)
            } catch {
                return false
            }
        }
        return false
    }

    private func isTrafficLow() async -> Bool {
        // Backgrounded: MemoryCapManager is releasing caches, and the app should not be
        // opening connections the user did not ask for.
        guard UIApplication.shared.applicationState == .active else { return false }
        // Before initialization completes the app user's route is not settled.
        guard HproseInstance.shared.isAppInitialized else { return false }
        // Images the user can actually see come first, as does video player setup.
        guard GlobalImageLoadManager.shared.activeLoadCount == 0 else { return false }
        guard VideoLoadingManager.shared.activeLoadingCount == 0 else { return false }
        // Video is the app's real bandwidth consumer. Defer to the judgement it already
        // makes about its own preloads: bandwidth is spare once the primary and every
        // visible player has the buffer it wants.
        return await NodePoolRegistry.shared.hasSpareBandwidth()
    }
}
