//
//  HLSVideoProcessor.swift
//  Tweet
//
//  Created by Your Name on YYYY/MM/DD.
//

import Foundation
import AVFoundation
import UIKit

/// HLSVideoProcessor provides native iOS video processing for HLS streaming
/// Uses AVFoundation for video encoding and manual HLS segmentation
public class HLSVideoProcessor {
    
    public static let shared = HLSVideoProcessor()
    
    private init() {}
    
    /// Configuration for HLS video processing
    public struct HLSConfig {
        let segmentDuration: TimeInterval
        let targetResolution: CGSize
        let keyframeInterval: Float
        let qualityLevels: [QualityLevel]
        
        public init(
            segmentDuration: TimeInterval = 6.0,
            targetResolution: CGSize = CGSize(width: 480, height: 270), // 480p
            keyframeInterval: Float = 2.0,
            qualityLevels: [QualityLevel] = []
        ) {
            self.segmentDuration = segmentDuration
            self.targetResolution = targetResolution
            self.keyframeInterval = keyframeInterval
            self.qualityLevels = qualityLevels.isEmpty ? [QualityLevel.medium] : qualityLevels
        }
    }
    
    /// Quality level configuration for medium quality HLS transcoding
    public struct QualityLevel {
        let name: String
        let resolution: CGSize
        let videoBitrate: Int
        let audioBitrate: Int
        let bandwidth: Int
        
        public init(
            name: String,
            resolution: CGSize,
            videoBitrate: Int,
            audioBitrate: Int = 128000,
            bandwidth: Int? = nil
        ) {
            self.name = name
            self.resolution = resolution
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.bandwidth = bandwidth ?? (videoBitrate + audioBitrate)
        }
        
        /// Medium quality level (480p) - default for HLS transcoding
        public static let medium = QualityLevel(
            name: "480p",
            resolution: CGSize(width: 480, height: 270),
            videoBitrate: 1000000,
            audioBitrate: 128000
        )
    }
    
    /// Check if video format is supported based on file extension
    public func isSupportedVideoFormat(_ fileName: String) -> Bool {
        let supportedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf"]
        let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
        return fileExtension != nil && supportedExtensions.contains(fileExtension!)
    }
    
    /// Convert video to medium quality HLS format with proper transcoding
    public func convertToAdaptiveHLS(
        inputURL: URL,
        outputDirectory: URL,
        config: HLSConfig
    ) async throws -> URL {
        print("Starting medium quality HLS conversion with FFmpeg transcoding...")

        // Ensure the output directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        let inputPath = inputURL.path
        let outputPath = outputDirectory.path

        // Use the new FFmpegManager for transcoding with target resolution
        let targetWidth = Int32(config.targetResolution.width)
        let targetHeight = Int32(config.targetResolution.height)
        let result = FFmpegManager.shared.convertToHLS(
            inputPath: inputPath, 
            outputDirectory: outputPath,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        
        switch result {
        case .success(let playlistPath):
            print("✅ FFmpeg medium quality HLS conversion successful.")
            let playlistURL = URL(fileURLWithPath: playlistPath)
            
            if FileManager.default.fileExists(atPath: playlistURL.path) {
                return playlistURL
            } else {
                throw HLSProcessorError.exportFailed(NSError(domain: "HLSVideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "FFmpeg conversion succeeded, but the M3U8 playlist file was not found."]))
            }
            
        case .failure(let error):
            print("❌ FFmpeg HLS conversion failed: \(error.localizedDescription)")
            throw HLSProcessorError.exportFailed(error)
        }
    }
    
    /// Get video aspect ratio
    public func getVideoAspectRatio(url: URL) async throws -> Float? {
        print("DEBUG: Getting video aspect ratio for URL: \(url)")
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("DEBUG: No video track found in getVideoAspectRatio")
            return nil
        }
        let size = try await track.load(.naturalSize)
        print("DEBUG: Video dimensions: \(size.width) x \(size.height)")
        let aspectRatio = size.height == 0 ? nil : Float(size.width / size.height)
        print("DEBUG: Calculated aspect ratio: \(aspectRatio ?? 0)")
        return aspectRatio
    }

    func canHandleVideoFormat(url: URL) async -> Bool {
        let asset = AVAsset(url: url)
        do {
            return try await asset.load(.isPlayable)
        } catch {
            print("Error checking if video is playable: \(error)")
            return false
        }
    }

    /// Check if video processing is supported on this device
    public func isVideoProcessingSupported() -> Bool {
        // Check if the device supports video export by trying to create an export session
        // This is a more reliable approach than checking deprecated export presets
        let dummyURL = URL(fileURLWithPath: "")
        let dummyAsset = AVAsset(url: dummyURL)
        
        // Try to create an export session with a common preset
        // If this succeeds, video processing is supported
        guard let exportSession = AVAssetExportSession(
            asset: dummyAsset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            return false
        }
        
        // Clean up
        exportSession.outputURL = nil
        return true
    }

    /// Get video dimensions (width and height) from a video file
    public func getVideoDimensions(url: URL) async -> CGSize {
        print("DEBUG: Getting video dimensions for URL: \(url)")
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
}

// MARK: - Error Types

public enum HLSProcessorError: Error, LocalizedError {
    case exportSessionCreationFailed
    case exportFailed(Error?)
    case noVideoTrack
    case invalidVideoFormat
    
    public var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let error):
            return "Export failed: \(error?.localizedDescription ?? "Unknown error")"
        case .noVideoTrack:
            return "No video track found in asset"
        case .invalidVideoFormat:
            return "Invalid video format"
        }
    }
}

// MARK: - Convenience Extensions

extension HLSVideoProcessor {
    
    /// Get supported video formats
    public func getSupportedVideoFormats() -> [String] {
        return [
            // Common formats
            "mp4", "mov", "m4v", "3gp",
            
            // Windows formats
            "avi", "wmv", "asf",
            
            // Web formats
            "flv", "f4v", "webm",
            
            // Linux/Open formats
            "mkv", "ogv", "ogg",
            
            // Other formats
            "ts", "mts", "m2ts", "vob", "dat",
            
            // Audio formats (for video with audio)
            "mp3", "aac", "wav", "flac", "m4a"
        ]
    }
    
    /// Create medium quality HLS (main method for video uploads)
    public func createMediumQualityHLS(
        inputURL: URL,
        outputDirectory: URL
    ) async throws -> URL {
        let config = HLSConfig(
            segmentDuration: 6.0,
            targetResolution: CGSize(width: 480, height: 270),
            keyframeInterval: 2.0,
            qualityLevels: [QualityLevel.medium]
        )
        
        return try await convertToAdaptiveHLS(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            config: config
        )
    }
} 