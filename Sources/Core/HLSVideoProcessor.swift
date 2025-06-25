//
//  HLSVideoProcessor.swift
//  Tweet
//
//  Created by tomas hongo on 2025/06/25.
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
    public func getVideoAspectRatio(filePath: String) async throws -> Float? {
        print("DEBUG: Getting video aspect ratio for file: \(filePath)")
        
        let asset = AVAsset(url: URL(fileURLWithPath: filePath))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        
        let size = try await track.load(.naturalSize)
        guard size.height > 0 else { return nil }
        
        let aspectRatio = Float(size.width / size.height)
        print("DEBUG: Calculated aspect ratio: \(aspectRatio)")
        return aspectRatio
    }
    
    /// Get video dimensions (width and height) from a video file
    public func getVideoDimensions(filePath: String) async -> CGSize {
        print("DEBUG: Getting video dimensions for file: \(filePath)")
        
        let asset = AVAsset(url: URL(fileURLWithPath: filePath))
        
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