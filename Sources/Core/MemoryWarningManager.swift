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
        
        // CRITICAL: Check if video upload is in progress
        // During FFmpeg video conversion, memory spikes are expected and temporary
        // Clearing video player caches during upload breaks existing players
        if UploadProgressManager.shared.isProcessingVideo {
            print("⚠️ [MemoryWarningManager] Video upload in progress - skipping video cache cleanup to prevent player breakage")
            print("⚠️ [MemoryWarningManager] Memory spike is expected during FFmpeg conversion and will subside after upload")
            
            // Still clean non-video caches to help with memory pressure
            Task {
                await releaseNonVideoCaches()
            }
            return
        }
        
        // Check if memory usage exceeds 1.4GB before taking action
        let memoryUsage = getCurrentMemoryUsage()
        let memoryUsageMB = memoryUsage / (1024 * 1024)
        
        print("DEBUG: [MemoryWarningManager] Current memory usage: \(memoryUsageMB)MB")
        
        // Only release caches if memory usage exceeds 1.4GB (preventive cleanup threshold)
        if memoryUsageMB > 1400 {
            print("DEBUG: [MemoryWarningManager] Memory usage exceeds 1.4GB, releasing 20% of caches")
            
            // Release 20% of all caches to free memory (less aggressive)
            Task {
                await releaseMemoryCaches()
            }
        } else {
            print("DEBUG: [MemoryWarningManager] Memory usage under 1.4GB, no action needed")
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
    
    /// Release only non-video caches during video upload
    /// This helps with memory pressure without breaking video players
    private func releaseNonVideoCaches() async {
        print("DEBUG: [MemoryWarningManager] Releasing non-video caches during upload...")
        
        // SKIP video cache clearing - would break existing players during upload
        // Release image and tweet caches only
        ImageCacheManager.shared.releasePartialCache(percentage: 30)
        TweetCacheManager.shared.releasePartialCache(percentage: 30)
        ChatCacheManager.shared.clearMemoryCache()
        
        print("DEBUG: [MemoryWarningManager] Non-video cache release completed (video players preserved)")
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
            // Use phys_footprint for accurate measurement
            var vmInfo = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
            let vmKerr = withUnsafeMutablePointer(to: &vmInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            
            if vmKerr == KERN_SUCCESS {
                return UInt64(vmInfo.phys_footprint)
            } else {
                return info.resident_size // Fallback
            }
        } else {
            return 0
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
