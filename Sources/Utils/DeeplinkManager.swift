import Foundation
import SwiftUI

/// Delivers deeplinks to ContentView without losing cold-start URLs posted before the view exists.
final class DeeplinkDelivery: @unchecked Sendable {
    static let shared = DeeplinkDelivery()

    enum Completion {
        case succeeded
        case retryScheduled
        case failed
    }

    private let lock = NSLock()
    private var pendingURLStrings: [String] = []
    private var inFlightURLStrings: Set<String> = []
    private var recentlyHandledURLStrings: [String: Date] = [:]
    private var failedOpenCounts: [String: Int] = [:]
    private let duplicateSuppressionInterval: TimeInterval = 3
    private let maxFailedOpenRetries = 1

    private init() {}

    func deliver(_ url: URL, delay: TimeInterval = 0) {
        guard enqueue(url) else {
            print("[DeeplinkDelivery] Skipping recently handled deeplink: \(url.absoluteString)")
            return
        }

        schedulePendingDelivery(url, delay: delay)
    }

    func consumePendingURLs() -> [URL] {
        lock.lock()
        pruneRecentlyHandledURLs()
        let urlStrings = pendingURLStrings.filter {
            recentlyHandledURLStrings[$0] == nil && !inFlightURLStrings.contains($0)
        }
        pendingURLStrings.removeAll()
        for urlString in urlStrings {
            inFlightURLStrings.insert(urlString)
        }
        lock.unlock()

        return urlStrings.compactMap { URL(string: $0) }
    }

    func startHandling(_ url: URL) -> Bool {
        lock.lock()
        pruneRecentlyHandledURLs()
        let urlString = url.absoluteString
        if recentlyHandledURLStrings[urlString] != nil || inFlightURLStrings.contains(urlString) {
            pendingURLStrings.removeAll { $0 == urlString }
            lock.unlock()
            return false
        }

        pendingURLStrings.removeAll { $0 == urlString }
        inFlightURLStrings.insert(urlString)
        lock.unlock()
        return true
    }

    @discardableResult
    func finishHandling(_ url: URL, succeeded: Bool) -> Completion {
        let shouldRetry: Bool
        lock.lock()
        pruneRecentlyHandledURLs()
        let urlString = url.absoluteString
        inFlightURLStrings.remove(urlString)
        if succeeded {
            pendingURLStrings.removeAll { $0 == urlString }
            recentlyHandledURLStrings[urlString] = Date()
            failedOpenCounts[urlString] = nil
            shouldRetry = false
        } else if recentlyHandledURLStrings[urlString] == nil && !pendingURLStrings.contains(urlString) {
            let failedCount = (failedOpenCounts[urlString] ?? 0) + 1
            failedOpenCounts[urlString] = failedCount
            guard failedCount <= maxFailedOpenRetries else {
                recentlyHandledURLStrings[urlString] = Date()
                lock.unlock()
                print("[DeeplinkDelivery] Deeplink failed after retries; giving up: \(url.absoluteString)")
                return .failed
            }

            pendingURLStrings.append(urlString)
            shouldRetry = true
        } else {
            shouldRetry = false
        }
        lock.unlock()

        if shouldRetry {
            print("[DeeplinkDelivery] Deeplink did not open; retrying shortly: \(url.absoluteString)")
            schedulePendingDelivery(url, delay: 2)
            return .retryScheduled
        }

        return succeeded ? .succeeded : .failed
    }

    private func enqueue(_ url: URL) -> Bool {
        lock.lock()
        pruneRecentlyHandledURLs()
        let urlString = url.absoluteString
        if recentlyHandledURLStrings[urlString] != nil || inFlightURLStrings.contains(urlString) {
            lock.unlock()
            return false
        }

        if !pendingURLStrings.contains(urlString) {
            pendingURLStrings.append(urlString)
        }
        lock.unlock()
        return true
    }

    private func schedulePendingDelivery(_ url: URL, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isPending(url) else { return }
            NotificationCenter.default.post(
                name: .deeplinkReceived,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    private func isPending(_ url: URL) -> Bool {
        lock.lock()
        pruneRecentlyHandledURLs()
        let result = pendingURLStrings.contains(url.absoluteString)
        lock.unlock()
        return result
    }

    private func pruneRecentlyHandledURLs() {
        let now = Date()
        recentlyHandledURLStrings = recentlyHandledURLStrings.filter { entry in
            let shouldKeep = now.timeIntervalSince(entry.value) < duplicateSuppressionInterval
            if !shouldKeep {
                failedOpenCounts[entry.key] = nil
            }
            return shouldKeep
        }
    }
}

/// Manages deeplink parsing and navigation
@MainActor
class DeeplinkManager: ObservableObject {
    static let shared = DeeplinkManager()
    
    enum DeeplinkType {
        case tweet(tweetId: String, authorId: String)
        case user(userId: String)
        case unknown
    }
    
    /// Parse a URL and extract deeplink information
    func parseURL(_ url: URL) -> DeeplinkType {
        print("[DeeplinkManager] Parsing URL: \(url.absoluteString)")
        
        // Handle custom URL scheme: tweet://tweet/{tweetId}/{authorId}
        if url.scheme == "tweet" {
            return parseCustomScheme(url)
        }
        
        // Handle HTTP/HTTPS URLs
        if url.scheme == "http" || url.scheme == "https" {
            return parseHTTPURL(url)
        }
        
        return .unknown
    }
    
    /// Parse custom tweet:// scheme URLs
    private func parseCustomScheme(_ url: URL) -> DeeplinkType {
        print("[DeeplinkManager] Parsing custom scheme - host: \(url.host ?? "nil"), path: \(url.path)")
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        print("[DeeplinkManager] Path components: \(pathComponents)")
        
        // Handle format: tweet://tweet/{tweetId}/{authorId}
        // Note: For custom schemes, the host can be "tweet" and path is "/{tweetId}/{authorId}"
        // OR the path can be "/tweet/{tweetId}/{authorId}"
        if let host = url.host, host == "tweet" {
            // Format: tweet://tweet/{tweetId}/{authorId}
            if pathComponents.count >= 2 {
                let tweetId = pathComponents[0]
                let authorId = pathComponents.count >= 2 ? pathComponents[1] : ""
                print("[DeeplinkManager] ✅ Parsed custom scheme tweet - tweetId: \(tweetId), authorId: \(authorId)")
                return .tweet(tweetId: tweetId, authorId: authorId)
            }
        } else if pathComponents.count >= 2 && pathComponents[0] == "tweet" {
            // Format: tweet:///tweet/{tweetId}/{authorId} (no host)
            let tweetId = pathComponents[1]
            let authorId = pathComponents.count >= 3 ? pathComponents[2] : ""
            print("[DeeplinkManager] ✅ Parsed custom scheme tweet (no host) - tweetId: \(tweetId), authorId: \(authorId)")
            return .tweet(tweetId: tweetId, authorId: authorId)
        } else if pathComponents.count >= 1 && pathComponents[0] == "user" {
            let userId = pathComponents.count >= 2 ? pathComponents[1] : ""
            print("[DeeplinkManager] ✅ Parsed custom scheme user - userId: \(userId)")
            return .user(userId: userId)
        }
        
        print("[DeeplinkManager] ⚠️ Could not parse custom scheme URL")
        return .unknown
    }
    
    /// Parse HTTP/HTTPS URLs
    private func parseHTTPURL(_ url: URL) -> DeeplinkType {
        print("[DeeplinkManager] Parsing HTTP URL - scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil"), path: \(url.path)")
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        print("[DeeplinkManager] Path components: \(pathComponents)")
        
        // Handle format: /tweet/{tweetId}/{authorId}
        if pathComponents.count >= 2 && pathComponents[0] == "tweet" {
            let tweetId = pathComponents[1]
            let authorId = pathComponents.count >= 3 ? pathComponents[2] : ""
            print("[DeeplinkManager] ✅ Parsed tweet deeplink - tweetId: \(tweetId), authorId: \(authorId)")
            return .tweet(tweetId: tweetId, authorId: authorId)
        }
        
        // Handle hash fragment formats such as #tweet/{tweetId}/{authorId}
        // and #author/{userId}.
        if let fragment = url.fragment {
            let fragmentComponents = fragment.components(separatedBy: "/").filter { !$0.isEmpty }
            if fragmentComponents.count >= 2 && fragmentComponents[0] == "tweet" {
                let tweetId = fragmentComponents[1]
                let authorId = fragmentComponents.count >= 3
                    ? fragmentComponents[2].components(separatedBy: "?")[0]
                    : ""
                return .tweet(tweetId: tweetId, authorId: authorId)
            }
            if fragmentComponents.count >= 2 && fragmentComponents[0] == "author" {
                return .user(userId: fragmentComponents[1].components(separatedBy: "?")[0])
            }
        }
        
        // Handle user profile URLs: /author/{userId}
        if pathComponents.count >= 2 && pathComponents[0] == "author" {
            let userId = pathComponents[1]
            print("[DeeplinkManager] ✅ Parsed user deeplink - userId: \(userId)")
            return .user(userId: userId)
        }
        
        print("[DeeplinkManager] ⚠️ Could not parse HTTP URL - unknown format")
        return .unknown
    }
    
    /// Handle deeplink navigation
    func handleDeeplink(_ deeplink: DeeplinkType, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async -> Bool {
        // Wait for app initialization if needed
        if !hproseInstance.isAppInitialized {
            print("[DeeplinkManager] App not initialized, waiting...")
            // Wait up to 10 seconds for initialization
            var waitCount = 0
            while !hproseInstance.isAppInitialized && waitCount < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                waitCount += 1
            }
            
            if !hproseInstance.isAppInitialized {
                print("[DeeplinkManager] App initialization timeout, proceeding anyway")
            }
        }
        
        switch deeplink {
        case .tweet(let tweetId, let authorId):
            return await navigateToTweet(tweetId: tweetId, authorId: authorId, navigationPath: navigationPath, hproseInstance: hproseInstance)
            
        case .user(let userId):
            return await navigateToUser(userId: userId, navigationPath: navigationPath, hproseInstance: hproseInstance)
            
        case .unknown:
            print("[DeeplinkManager] Unknown deeplink type")
            return false
        }
    }
    
    /// Navigate to a tweet
    private func navigateToTweet(tweetId: String, authorId: String, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async -> Bool {
        print("[DeeplinkManager] Navigating to tweet: \(tweetId), author: \(authorId)")
        
        // First try to fetch from cache
        if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: tweetId) {
            print("[DeeplinkManager] ✅ Found tweet in cache")
            return await replaceNavigationPath(with: cachedTweet, navigationPath: navigationPath)
        }
        
        // If not in cache and we have authorId, fetch from server
        if !authorId.isEmpty {
            // A tweet is read from its author's node, so that is the route to keep
            // honest between attempts.
            guard let tweet = await resolveWithRouteRepair(
                routeOwnerId: authorId,
                hproseInstance: hproseInstance,
                label: "tweet \(tweetId)",
                fetch: {
                    await self.fetchDeeplinkTweet(tweetId: tweetId, authorId: authorId, hproseInstance: hproseInstance)
                }
            ) else {
                print("[DeeplinkManager] ⚠️ Tweet not found on server after deeplink retries")
                return false
            }

            print("[DeeplinkManager] ✅ Successfully fetched tweet for deeplink")
            return await replaceNavigationPath(with: tweet, navigationPath: navigationPath)
        } else {
            print("[DeeplinkManager] ⚠️ Cannot fetch tweet: missing authorId")
            return false
        }
    }

    /// Fetch tweet data for deeplink navigation using normal read first, then explicit recovery.
    private func fetchDeeplinkTweet(tweetId: String, authorId: String, hproseInstance: HproseInstance) async -> Tweet? {
        // Try getTweet first (faster, uses current provider). It throws when the
        // author's node can't be resolved — don't let that skip the refreshTweet
        // fallback, which can still sync via the app user's own node.
        do {
            if let tweet = try await hproseInstance.getTweet(tweetId: tweetId, authorId: authorId) {
                return tweet
            }
        } catch {
            print("[DeeplinkManager] ⚠️ getTweet failed (\(error)), trying refreshTweet...")
        }

        do {
            // refreshTweet syncs from the author's host and falls back to the
            // app user's node when the author's baseUrl is unknown.
            return try await hproseInstance.refreshTweet(tweetId: tweetId, authorId: authorId)
        } catch {
            print("[DeeplinkManager] ❌ refreshTweet failed: \(error)")
            return nil
        }
    }
    
    /// Navigate to a user profile
    private func navigateToUser(userId: String, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async -> Bool {
        print("[DeeplinkManager] Navigating to user: \(userId)")

        guard let user = await resolveWithRouteRepair(
            routeOwnerId: userId,
            hproseInstance: hproseInstance,
            label: "user \(userId)",
            fetch: {
                do {
                    return try await hproseInstance.fetchUser(userId)
                } catch {
                    print("[DeeplinkManager] Error fetching user: \(error)")
                    return nil
                }
            }
        ) else {
            print("[DeeplinkManager] User not found")
            return false
        }

        print("[DeeplinkManager] Successfully fetched user")
        return await replaceNavigationPath(with: user, navigationPath: navigationPath)
    }

    /// Universal links can arrive while provider/bootstrap state is still settling, so
    /// give transient startup failures a short bounded retry window.
    private static let retryDelays: [UInt64] = [
        0,
        300_000_000,
        1_000_000_000,
        2_000_000_000
    ]

    /// Runs `fetch` against the node cached for `routeOwnerId`, repairing that route
    /// between attempts the way the rest of the app does.
    ///
    /// Both deeplink destinations are read from one user's node — a profile from the
    /// user's own route, a tweet from its author's `baseUrl` — and a link can be opened
    /// long after that cached route stopped serving. Two different failures need two
    /// different repairs, so both run:
    ///
    /// - `validateAndRepairProfileRoute` before each attempt, the same check `ProfileView`
    ///   runs on open: probe the current route and, when it is dead, move to the access
    ///   node's next address and then down the provider list until one answers.
    /// - `switchToAlternateRoute` after a failed attempt, the same step `fetchUserTweets`
    ///   takes: a route that passes the probe but still cannot serve the read is only
    ///   detectable by the read failing, and the probe above will keep clearing it.
    ///
    /// Without the second step the retries re-hit the same probe-healthy address every
    /// time and the deeplink fails with the node right there in the pool.
    private func resolveWithRouteRepair<T>(
        routeOwnerId: String,
        hproseInstance: HproseInstance,
        label: String,
        fetch: () async -> T?
    ) async -> T? {
        guard !routeOwnerId.isEmpty, routeOwnerId != Constants.GUEST_ID else { return nil }

        for (attemptIndex, delay) in Self.retryDelays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return nil }

            let user = await TweetCacheManager.shared.fetchUser(mid: routeOwnerId)
            if !(await hproseInstance.validateAndRepairProfileRoute(for: user)) {
                print("[DeeplinkManager] ⚠️ No healthy route for \(routeOwnerId); trying the cached one anyway")
            }
            guard !Task.isCancelled else { return nil }

            let attemptedRoute = user.baseUrl?.absoluteString
            print("[DeeplinkManager] Fetching \(label) (attempt \(attemptIndex + 1)/\(Self.retryDelays.count)) via \(attemptedRoute ?? "nil")")

            if let value = await fetch() {
                return value
            }
            guard !Task.isCancelled, attemptIndex < Self.retryDelays.count - 1 else { return nil }

            // The read failed on an address the probe just cleared, so the probe cannot
            // condemn it. Move off it before the next attempt; a false return leaves the
            // route alone and the next attempt's probe can still widen to discovery.
            _ = await hproseInstance.switchToAlternateRoute(
                for: user,
                attemptedBaseUrl: attemptedRoute,
                logPrefix: "deeplink"
            )
        }

        return nil
    }

    private func replaceNavigationPath<T: Hashable>(with value: T, navigationPath: Binding<NavigationPath>) async -> Bool {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        if !navigationPath.wrappedValue.isEmpty {
            // SwiftUI can retain a same-depth destination when a path changes directly
            // from one Tweet/User value to another. Commit the removal first; the
            // full-screen deeplink placeholder hides both non-animated mutations.
            withTransaction(transaction) {
                navigationPath.wrappedValue = NavigationPath()
            }

            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }

        guard !Task.isCancelled else { return false }

        var newPath = NavigationPath()
        newPath.append(value)
        withTransaction(transaction) {
            navigationPath.wrappedValue = newPath
        }
        return true
    }
}
