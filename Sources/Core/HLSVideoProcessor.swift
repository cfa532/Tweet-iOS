//
//  HLSVideoProcessor.swift
//  Tweet
//
//  Created by Your Name on YYYY/MM/DD.
//

import Foundation
import AVFoundation
import UIKit

/// HLSVideoProcessor provides video metadata extraction for backend-based video processing
/// Since video conversion is now handled on the backend, this class focuses on aspect ratio detection
public class HLSVideoProcessor {
    
    public static let shared = HLSVideoProcessor()
    
    private init() {}
    
    /// Get video aspect ratio with multiple fallback approaches
    public func getVideoAspectRatio(url: URL) async throws -> Float? {
        print("DEBUG: Getting video aspect ratio for URL: \(url)")
        
        // First, check if the file exists and is readable
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("DEBUG: Video file does not exist at path: \(url.path)")
            return nil
        }
        
        // Get file size to ensure it's not empty
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? UInt64 ?? 0
            if fileSize == 0 {
                print("DEBUG: Video file is empty")
                return nil
            }
        } catch {
            print("DEBUG: Could not get file attributes: \(error)")
            return nil
        }
        
        // Try multiple approaches to get the aspect ratio
        
        // Approach 1: Use AVURLAsset with better error handling
        do {
            let asset = AVURLAsset(url: url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            
            // Check if the asset is playable first
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                print("DEBUG: Video asset is not playable")
                throw NSError(domain: "AVFoundationErrorDomain", code: -11828, userInfo: [NSLocalizedDescriptionKey: "Video is not playable"])
            }
            
            // Load tracks with better error handling
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                print("DEBUG: No video track found")
                return nil
            }
            
            // Load size with timeout
            let size = try await withTimeout(seconds: 5.0) {
                try await track.load(.naturalSize)
            }
            
            print("DEBUG: Video dimensions: \(size.width) x \(size.height)")
            
            // Calculate aspect ratio with safety check
            guard size.height > 0 else {
                print("DEBUG: Invalid video height (0), cannot calculate aspect ratio")
                return nil
            }
            
            let aspectRatio = Float(size.width / size.height)
            print("DEBUG: Calculated aspect ratio: \(aspectRatio)")
            return aspectRatio
            
        } catch {
            print("DEBUG: AVURLAsset approach failed: \(error)")
        }
        
        // Approach 2: Try with AVAsset instead of AVURLAsset
        do {
            let asset = AVAsset(url: url)
            
            // Check if the asset is playable
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                print("DEBUG: Video asset is not playable (AVAsset approach)")
                return nil
            }
            
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                print("DEBUG: No video track found (AVAsset approach)")
                return nil
            }
            
            let size = try await withTimeout(seconds: 5.0) {
                try await track.load(.naturalSize)
            }
            
            guard size.height > 0 else {
                print("DEBUG: Invalid video height (0) in AVAsset approach")
                return nil
            }
            
            let aspectRatio = Float(size.width / size.height)
            print("DEBUG: Calculated aspect ratio (AVAsset approach): \(aspectRatio)")
            return aspectRatio
            
        } catch {
            print("DEBUG: AVAsset approach also failed: \(error)")
        }
        
        // Approach 3: Try to get dimensions using getVideoDimensions method
        let dimensions = await getVideoDimensions(url: url)
        if dimensions.height > 0 {
            let aspectRatio = Float(dimensions.width / dimensions.height)
            print("DEBUG: Calculated aspect ratio (getVideoDimensions approach): \(aspectRatio)")
            return aspectRatio
        }
        
        // If all approaches fail, return nil
        print("DEBUG: All aspect ratio detection approaches failed")
        return nil
    }
    
    /// Helper function to add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Get video dimensions (width and height) from a video file
    public func getVideoDimensions(url: URL) async -> CGSize {
        print("DEBUG: Getting video dimensions for URL: \(url)")
        
        // Create a strong reference to the asset to prevent deallocation during async operations
        let asset = AVAsset(url: url)
        
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            print("DEBUG: Found \(tracks.count) video tracks")
            guard let videoTrack = tracks.first else {
                print("DEBUG: No video track found, using default fallback")
                return CGSize(width: 480, height: 270) // Default fallback
            }
            
            let size = try await videoTrack.load(.naturalSize)
            print("DEBUG: Loaded video dimensions: \(size)")
            return size
        } catch {
            print("DEBUG: Error getting video dimensions: \(error)")
            return CGSize(width: 480, height: 270) // Default fallback
        }
    }
    
    /// Check if video format is supported based on file extension
    public func isSupportedVideoFormat(_ fileName: String) -> Bool {
        let supportedExtensions = [
            // Common formats
            "mp4", "mov", "m4v", "3gp",
            
            // Windows formats
            "avi", "wmv", "asf",
            
            // Web formats
            "flv", "f4v", "webm",
            
            // Linux/Open formats
            "mkv", "ogv", "ogg",
            
            // Other formats
            "ts", "mts", "m2ts", "vob", "dat"
        ]
        let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
        return fileExtension != nil && supportedExtensions.contains(fileExtension!)
    }
} 