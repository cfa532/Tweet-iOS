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
        print("DEBUG: [MemoryWarningManager] System memory warning received")
        
        // Check if memory usage exceeds 1GB before taking action
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        print("DEBUG: [MemoryWarningManager] Current memory usage: \(memoryUsageMB)MB")
        
        // Only release caches if memory usage exceeds 1GB
        if memoryUsageMB > 1024 {
            print("DEBUG: [MemoryWarningManager] Memory usage exceeds 1GB, releasing 20% of caches")
            
            // Release 20% of all caches to free memory (less aggressive)
            Task {
                await releaseMemoryCaches()
            }
        } else {
            print("DEBUG: [MemoryWarningManager] Memory usage under 1GB, no action needed")
        }
    }
    
    /// Release 20% of video and image caches to free memory
    private func releaseMemoryCaches() async {
        print("DEBUG: [MemoryWarningManager] Releasing 20% of memory caches...")
        
        // Release 20% of video caches (preserve current playing videos)
        SharedAssetCache.shared.releasePartialCache(percentage: 20)
        
        // Release 20% of image caches
        ImageCacheManager.shared.releasePartialCache(percentage: 20)
        
        // Release 20% of tweet caches
        TweetCacheManager.shared.releasePartialCache(percentage: 20)
        
        print("DEBUG: [MemoryWarningManager] Memory cache release completed")
    }
    
    /// Get current memory usage in bytes
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return info.resident_size
        } else {
            return 0
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

