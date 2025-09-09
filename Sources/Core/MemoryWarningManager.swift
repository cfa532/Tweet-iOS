//
//  MemoryWarningManager.swift
//  Tweet
//
//  Manages system memory warnings and coordinates cache cleanup across all cache managers
//

import Foundation
import UIKit

@MainActor
class MemoryWarningManager: ObservableObject {
    static let shared = MemoryWarningManager()
    
    private init() {
        setupMemoryWarningObserver()
    }
    
    // MARK: - Memory Warning Handling
    
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        print("DEBUG: [MemoryWarningManager] System memory warning received - releasing 30% of caches")
        
        // Release 30% of all caches to free memory
        Task {
            await releaseMemoryCaches()
        }
    }
    
    /// Release 30% of video and image caches to free memory
    private func releaseMemoryCaches() async {
        print("DEBUG: [MemoryWarningManager] Releasing 30% of memory caches...")
        
        // Release 30% of video caches (preserve current playing videos)
        SharedAssetCache.shared.releasePartialCache(percentage: 30)
        
        // Release 30% of image caches
        ImageCacheManager.shared.releasePartialCache(percentage: 30)
        
        // Release 30% of tweet caches
        TweetCacheManager.shared.releasePartialCache(percentage: 30)
        
        print("DEBUG: [MemoryWarningManager] Memory cache release completed")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

