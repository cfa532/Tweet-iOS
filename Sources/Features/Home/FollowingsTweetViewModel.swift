//
//  FollowingsTweetViewModel.swift
//  Tweet
//
//  Created by 超方 on 2025/6/4.
//

import AVFoundation
import UIKit

@available(iOS 16.0, *)
class FollowingsTweetViewModel: ObservableObject {
    @Published var tweets: [Tweet] = []     // tweet list to be displayed on screen.
    @Published var isLoading: Bool = false
    @Published var showTweetDetail: Bool = false
    @Published var selectedTweet: Tweet?
    private let hproseInstance: HproseInstance
    
    init(hproseInstance: HproseInstance) {
        self.hproseInstance = hproseInstance
    }
    
    func fetchTweets(page: UInt, pageSize: UInt) async -> [Tweet?] {
        // fetch tweets from server
        do {
            let serverTweets = try await hproseInstance.fetchTweetFeed(
                user: hproseInstance.appUser,
                pageNumber: page,
                pageSize: pageSize
            )
            await MainActor.run {
                tweets.mergeTweets(serverTweets.compactMap{ $0 })
            }
            // Preload video snapshots for tweets with video attachments
            Task {
                for tweet in serverTweets.compactMap({ $0 }) {
                    if let attachments = tweet.attachments {
                        for attachment in attachments where attachment.type.lowercased().contains("video") {
                            await VideoSnapshotPreloader.preloadSnapshot(for: attachment)
                        }
                    }
                }
            }
            Task {
                let newTweets = try await hproseInstance.fetchTweetFeed(
                    user: hproseInstance.appUser,
                    pageNumber: page,
                    pageSize: pageSize,
                    entry: "update_following_tweets"
                )
                await MainActor.run {
                    tweets.mergeTweets(newTweets.compactMap{ $0 })
                }
                // Preload video snapshots for new tweets as well
                for tweet in newTweets.compactMap({ $0 }) {
                    if let attachments = tweet.attachments {
                        for attachment in attachments where attachment.type.lowercased().contains("video") {
                            await VideoSnapshotPreloader.preloadSnapshot(for: attachment)
                        }
                    }
                }
            }
            return serverTweets     // including nil
        } catch {
            print("[FollowingsTweetViewModel] Error fetching tweets: \(error)")
            return []
        }
    }
    
    // optimistic UI update
    func handleNewTweet(_ tweet: Tweet?) {
        if let tweet = tweet {
            tweets.insert(tweet, at: 0)
        }
    }
    
    func handleDeletedTweet(_ tweetId: String) {
        tweets.removeAll { $0.mid == tweetId }
        TweetCacheManager.shared.deleteTweet(mid: tweetId)
    }
    
    func showTweetDetail(_ tweet: Tweet) {
        selectedTweet = tweet
        showTweetDetail = true
    }
}

class VideoSnapshotPreloader {
    static func preloadSnapshot(for attachment: MimeiFileType) async {
        let key = attachment.mid
        let baseUrl = HproseInstance.baseUrl
        print("[Snapshot] Preloading snapshot for mid=\(key)")
        if ImageCacheManager.shared.getCompressedImage(for: MimeiFileType(mid: key, type: "video"), baseUrl: baseUrl) == nil,
           let url = attachment.getUrl(baseUrl) {
            print("[Snapshot] Generating snapshot for url: \(url)")
            let asset = AVAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                let thumbnail = UIImage(cgImage: cgImage)
                if let data = thumbnail.jpegData(compressionQuality: 0.8) {
                    let cacheAttachment = MimeiFileType(mid: key, type: "video")
                    ImageCacheManager.shared.cacheImageData(data, for: cacheAttachment, baseUrl: baseUrl)
                    print("[Snapshot] Snapshot cached for mid=\(key)")
                }
            } catch {
                print("[Snapshot] Failed to generate video snapshot for mid=\(key): \(error)")
            }
        } else {
            print("[Snapshot] Snapshot already cached for mid=\(key)")
        }
    }
}
