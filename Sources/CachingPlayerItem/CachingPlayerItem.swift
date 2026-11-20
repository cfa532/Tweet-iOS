//
//  CachingPlayerItem.swift
//  CachingPlayerItem
//
//  Created by Gorjan Shukov on 10/24/20.
//

import Foundation
import AVFoundation

/// Convenient delegate methods for `CachingPlayerItem` status updates.
@objc public protocol CachingPlayerItemDelegate {
    // MARK: Downloading delegate methods

    /// Called when the media file is fully downloaded.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, didFinishDownloadingFileAt filePath: String)

    /// Called every time a new portion of data is received.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int)

    /// Called on downloading error.
    @objc optional func playerItem(_ playerItem: CachingPlayerItem, downloadingFailedWith error: Error)

    // MARK: Playing delegate methods

    /// Called after initial prebuffering is finished, means we are ready to play.
    @objc optional func playerItemReadyToPlay(_ playerItem: CachingPlayerItem)

    /// Called when the player is unable to play the data/url.
    @objc optional func playerItemDidFailToPlay(_ playerItem: CachingPlayerItem, withError error: Error?)

    /// Called when the data being downloaded did not arrive in time to continue playback.
    @objc optional func playerItemPlaybackStalled(_ playerItem: CachingPlayerItem)
}

/// AVPlayerItem for HLS videos played through the local caching proxy.
///
/// The asset points at LocalHTTPServer, which serves cached playlists and segments and
/// fetches missing ones upstream. Progressive videos use ProgressiveVideoAsset instead;
/// the original library's progressive resource-loader path and its unused initializers
/// were removed once nothing created them.
public final class CachingPlayerItem: AVPlayerItem {
    /// `delegate` for status updates.
    public weak var delegate: CachingPlayerItemDelegate?

    deinit {
        removeObservers()
    }

    /**
     Play and cache HLS media (M3U8 playlists with TS segments).

     - parameter hlsURL: URL referencing the HLS playlist file (.m3u8).
     - parameter mediaID: Unique identifier for the media (used for cache key).
     - parameter avUrlAssetOptions: A dictionary that contains options used to customize the initialization of the asset.
     */
    public init(hlsURL: URL, mediaID: String, avUrlAssetOptions: [String: Any]? = nil) {
        // AVPlayer requests the localhost URL; LocalHTTPServer maps it back to hlsURL.
        let localhostURL = LocalHTTPServer.shared.registerAndGetURL(for: mediaID, realURL: hlsURL)
        let asset = AVURLAsset(url: localhostURL, options: avUrlAssetOptions)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
        addObservers()
        DiskCacheCleanupManager.shared.noteVideoUsed(mediaID: mediaID)
    }

    // MARK: KVO

    private nonisolated(unsafe) var playerItemContext = 0

    public override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {

        // Only handle observations for the playerItemContext
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        // We are only observing the status keypath
        guard keyPath == #keyPath(AVPlayerItem.status) else { return }

        let status: AVPlayerItem.Status
        if let statusNumber = change?[.newKey] as? NSNumber {
            status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
        } else {
            status = .unknown
        }

        // Switch over status value
        switch status {
        case .readyToPlay:
            // Player item is ready to play.
            AppLogger.info("CachingPlayerItem status: ready to play")
            DispatchQueue.main.async { self.delegate?.playerItemReadyToPlay?(self) }
        case .failed:
            // Player item failed. See error.
            AppLogger.error("CachingPlayerItem status: failed with error: \(String(describing: error))")
            DispatchQueue.main.async { self.delegate?.playerItemDidFailToPlay?(self, withError: self.error) }
        case .unknown:
            // Player item is not yet ready.
            AppLogger.error("CachingPlayerItem status: uknown with error: \(String(describing: error))")
        @unknown default:
            break
        }
    }

    // MARK: Private methods

    private nonisolated func addObservers() {
        addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: .new, context: &playerItemContext)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStalledHandler), name: .AVPlayerItemPlaybackStalled, object: self)
    }

    private nonisolated func removeObservers() {
        removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackStalledHandler() {
        DispatchQueue.main.async { self.delegate?.playerItemPlaybackStalled?(self) }
    }

    /// Generates a file path for HLS playlist in caches directory.
    public nonisolated static func hlsPlaylistPath(for mediaID: String) -> String {
        guard var cachesDirectory = try? FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        else {
            fatalError("CachingPlayerItem error: Can't access default cache directory")
        }
        
        let sanitizedFileName = mediaID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "hls_playlist"
        cachesDirectory.appendPathComponent("\(sanitizedFileName).m3u8")
        
        return cachesDirectory.path
    }
    
    /// Generates a directory path for HLS segments in caches directory.
    public nonisolated static func hlsSegmentsPath(for mediaID: String) -> String {
        guard var cachesDirectory = try? FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        else {
            fatalError("CachingPlayerItem error: Can't access default cache directory")
        }
        
        let sanitizedFileName = mediaID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "hls_segments"
        cachesDirectory.appendPathComponent("\(sanitizedFileName)_segments")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true, attributes: nil)
        
        return cachesDirectory.path
    }
    
    
    /// Clear all cached HLS content for a specific mediaID
    public nonisolated static func clearHLSCache(for mediaID: String) {
        let playlistPath = hlsPlaylistPath(for: mediaID)
        let segmentsPath = hlsSegmentsPath(for: mediaID)
        
        // Remove playlist file
        try? FileManager.default.removeItem(atPath: playlistPath)
        
        // Remove segments directory
        try? FileManager.default.removeItem(atPath: segmentsPath)
        
    }
    
    /// Clear all cached content (both HLS and progressive videos)
    public nonisolated static func clearAllCache() {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            print("DEBUG: [CachingPlayerItem] Failed to access caches directory")
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cachesDirectory, includingPropertiesForKeys: nil)
            
            for url in contents {
                let fileName = url.lastPathComponent
                
                // Remove files that look like cached media (contain mediaID patterns)
                if fileName.hasSuffix(".m3u8") || fileName.hasSuffix("_segments") || fileName.contains("Qm") {
                    try FileManager.default.removeItem(at: url)
                    print("DEBUG: [CachingPlayerItem] Removed cached file: \(fileName)")
                }
            }
            
            print("DEBUG: [CachingPlayerItem] Cleared all cache files")
        } catch {
            print("DEBUG: [CachingPlayerItem] Failed to clear cache: \(error)")
        }
    }
}
