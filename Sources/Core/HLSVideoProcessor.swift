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
            self.qualityLevels = qualityLevels.isEmpty ? [QualityLevel.default] : qualityLevels
        }
    }
    
    /// Quality level configuration for adaptive bitrate streaming
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
        
        /// Default quality level (480p)
        public static let `default` = QualityLevel(
            name: "480p",
            resolution: CGSize(width: 480, height: 270),
            videoBitrate: 1000000,
            audioBitrate: 128000
        )
        
        /// High quality level (720p)
        public static let high = QualityLevel(
            name: "720p",
            resolution: CGSize(width: 720, height: 405),
            videoBitrate: 2000000,
            audioBitrate: 192000
        )
        
        /// Medium quality level (480p)
        public static let medium = QualityLevel(
            name: "480p",
            resolution: CGSize(width: 480, height: 270),
            videoBitrate: 1000000,
            audioBitrate: 128000
        )
        
        /// Low quality level (360p)
        public static let low = QualityLevel(
            name: "360p",
            resolution: CGSize(width: 360, height: 202),
            videoBitrate: 500000,
            audioBitrate: 96000
        )
        
        /// Ultra low quality level (240p)
        public static let ultraLow = QualityLevel(
            name: "240p",
            resolution: CGSize(width: 240, height: 135),
            videoBitrate: 250000,
            audioBitrate: 64000
        )
    }
    
    /// Check if video format is supported based on file extension
    public func isSupportedVideoFormat(_ fileName: String) -> Bool {
        let supportedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "ts", "mts", "m2ts", "vob", "dat", "ogv", "ogg", "f4v", "asf"]
        let fileExtension = fileName.components(separatedBy: ".").last?.lowercased()
        return fileExtension != nil && supportedExtensions.contains(fileExtension!)
    }
    
    /// Convert video to adaptive HLS format with multiple quality levels
    public func convertToAdaptiveHLS(
        inputURL: URL,
        outputDirectory: URL,
        config: HLSConfig
    ) async throws -> URL {
        print("Starting multi-resolution HLS conversion with FFmpeg...")

        // Ensure the output directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        let inputPath = inputURL.path
        let outputPath = outputDirectory.path

        // Use the new FFmpegManager for better error handling
        let result = FFmpegManager.shared.convertToHLS(inputPath: inputPath, outputDirectory: outputPath)
        
        switch result {
        case .success(let playlistPath):
            print("✅ FFmpeg multi-resolution HLS conversion successful.")
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
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let size = try await track.load(.naturalSize)
        return size.height == 0 ? nil : Float(size.width / size.height)
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
    
    /// Create adaptive HLS with standard quality levels
    public func createStandardAdaptiveHLS(
        inputURL: URL,
        outputDirectory: URL
    ) async throws -> URL {
        let qualityLevels = [
            QualityLevel.high,    // 720p - 2 Mbps
            QualityLevel.medium,  // 480p - 1 Mbps
            QualityLevel.low,     // 360p - 500 Kbps
            QualityLevel.ultraLow // 240p - 250 Kbps
        ]
        
        let config = HLSConfig(
            segmentDuration: 6.0,
            targetResolution: CGSize(width: 480, height: 270),
            keyframeInterval: 2.0,
            qualityLevels: qualityLevels
        )
        
        return try await convertToAdaptiveHLS(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            config: config
        )
    }
    
    /// Create adaptive HLS with custom quality levels
    public func createCustomAdaptiveHLS(
        inputURL: URL,
        outputDirectory: URL,
        qualityLevels: [QualityLevel]
    ) async throws -> URL {
        let config = HLSConfig(
            segmentDuration: 6.0,
            targetResolution: qualityLevels.first?.resolution ?? CGSize(width: 480, height: 270),
            keyframeInterval: 2.0,
            qualityLevels: qualityLevels
        )
        
        return try await convertToAdaptiveHLS(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            config: config
        )
    }
    
    /// Create single quality HLS (for backward compatibility)
    public func createSingleQualityHLS(
        inputURL: URL,
        outputDirectory: URL,
        qualityLevel: QualityLevel = .medium
    ) async throws -> URL {
        let config = HLSConfig(
            segmentDuration: 6.0,
            targetResolution: qualityLevel.resolution,
            keyframeInterval: 2.0,
            qualityLevels: [qualityLevel]
        )
        
        return try await convertToAdaptiveHLS(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            config: config
        )
    }
} 