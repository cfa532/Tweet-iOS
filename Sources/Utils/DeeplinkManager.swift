import Foundation
import SwiftUI

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
        
        // Handle hash fragment format: /entry?aid=...&ver=last#/tweet/{tweetId}/{authorId}
        if let fragment = url.fragment, fragment.hasPrefix("/tweet/") {
            let fragmentComponents = fragment.components(separatedBy: "/").filter { !$0.isEmpty }
            if fragmentComponents.count >= 2 && fragmentComponents[0] == "tweet" {
                let tweetId = fragmentComponents[1]
                let authorId = fragmentComponents.count >= 3 ? fragmentComponents[2] : ""
                return .tweet(tweetId: tweetId, authorId: authorId)
            }
        }
        
        // Handle user profile URLs if they exist
        // Format: /user/{userId} or /profile/{userId}
        if pathComponents.count >= 2 {
            if pathComponents[0] == "user" || pathComponents[0] == "profile" {
                let userId = pathComponents[1]
                print("[DeeplinkManager] ✅ Parsed user deeplink - userId: \(userId)")
                return .user(userId: userId)
            }
        }
        
        print("[DeeplinkManager] ⚠️ Could not parse HTTP URL - unknown format")
        return .unknown
    }
    
    /// Handle deeplink navigation
    func handleDeeplink(_ deeplink: DeeplinkType, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async {
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
            await navigateToTweet(tweetId: tweetId, authorId: authorId, navigationPath: navigationPath, hproseInstance: hproseInstance)
            
        case .user(let userId):
            await navigateToUser(userId: userId, navigationPath: navigationPath, hproseInstance: hproseInstance)
            
        case .unknown:
            print("[DeeplinkManager] Unknown deeplink type")
        }
    }
    
    /// Navigate to a tweet
    private func navigateToTweet(tweetId: String, authorId: String, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async {
        print("[DeeplinkManager] Navigating to tweet: \(tweetId), author: \(authorId)")
        
        // First try to fetch from cache
        if let cachedTweet = await TweetCacheManager.shared.fetchTweet(mid: tweetId) {
            print("[DeeplinkManager] ✅ Found tweet in cache")
            await MainActor.run {
                navigationPath.wrappedValue.append(cachedTweet)
            }
            return
        }
        
        // If not in cache and we have authorId, fetch from server
        if !authorId.isEmpty {
            do {
                print("[DeeplinkManager] Fetching tweet from server...")
                
                // Try getTweet first (faster, uses current provider)
                if let tweet = try await hproseInstance.getTweet(tweetId: tweetId, authorId: authorId) {
                    print("[DeeplinkManager] ✅ Successfully fetched tweet from server")
                    await MainActor.run {
                        navigationPath.wrappedValue.append(tweet)
                    }
                    return
                }
                
                // If getTweet returns nil, try refreshTweet (syncs from author's host)
                print("[DeeplinkManager] Tweet not found with getTweet, trying refreshTweet...")
                if let tweet = try await hproseInstance.refreshTweet(tweetId: tweetId, authorId: authorId) {
                    print("[DeeplinkManager] ✅ Successfully fetched tweet with refreshTweet")
                    await MainActor.run {
                        navigationPath.wrappedValue.append(tweet)
                    }
                    return
                }
                
                // Both methods failed
                print("[DeeplinkManager] ⚠️ Tweet not found on server")
                await showTweetNotFoundError()
                
            } catch {
                print("[DeeplinkManager] ❌ Error fetching tweet: \(error)")
                await showTweetNotFoundError()
            }
        } else {
            print("[DeeplinkManager] ⚠️ Cannot fetch tweet: missing authorId")
            await showTweetNotFoundError()
        }
    }
    
    /// Show error notification when tweet is not found
    private func showTweetNotFoundError() async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .deeplinkTweetNotFound,
                object: nil,
                userInfo: ["message": NSLocalizedString("Tweet not found. It may have been deleted or the link is invalid.", comment: "Deeplink tweet not found error")]
            )
        }
    }
    
    /// Navigate to a user profile
    private func navigateToUser(userId: String, navigationPath: Binding<NavigationPath>, hproseInstance: HproseInstance) async {
        print("[DeeplinkManager] Navigating to user: \(userId)")
        
        do {
            if let user = try await hproseInstance.fetchUser(userId) {
                print("[DeeplinkManager] Successfully fetched user")
                navigationPath.wrappedValue.append(user)
            } else {
                print("[DeeplinkManager] User not found")
            }
        } catch {
            print("[DeeplinkManager] Error fetching user: \(error)")
        }
    }
}

