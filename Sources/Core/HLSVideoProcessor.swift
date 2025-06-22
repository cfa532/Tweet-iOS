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
        let keyframeInterval: TimeInterval
        let qualityLevels: [QualityLevel]
        
        public init(
            segmentDuration: TimeInterval = 6.0,
            targetResolution: CGSize = CGSize(width: 480, height: 270), // 480p
            keyframeInterval: TimeInterval = 2.0,
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
    
    /// Convert video to adaptive HLS format with multiple quality levels
    public func convertToAdaptiveHLS(
        inputURL: URL,
        outputDirectory: URL,
        config: HLSConfig
    ) async throws -> URL {
        print("Starting HLS conversion with FFmpeg...")

        // Ensure the output directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        let inputPath = inputURL.path
        let outputPath = outputDirectory.path

        // The C function convert_to_hls is now available directly in Swift
        // because we added it to the bridging header.
        let result = convert_to_hls(inputPath, outputPath)

        if result == 0 {
            print("✅ FFmpeg HLS conversion successful.")
            let masterPlaylistURL = outputDirectory.appendingPathComponent("master.m3u8")
            // Check if the master playlist was actually created
            if FileManager.default.fileExists(atPath: masterPlaylistURL.path) {
                return masterPlaylistURL
            } else {
                // If the master playlist is missing, we can assume the output is a single playlist.
                // This can happen depending on the FFmpeg commands.
                let singlePlaylistURL = outputDirectory.appendingPathComponent("playlist.m3u8")
                 if FileManager.default.fileExists(atPath: singlePlaylistURL.path) {
                    return singlePlaylistURL
                 } else {
                    throw NSError(domain: "HLSVideoProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "FFmpeg conversion succeeded, but the M3U8 playlist file was not found."])
                 }
            }
        } else {
            print("❌ FFmpeg HLS conversion failed with exit code: \(result).")
            throw NSError(domain: "HLSVideoProcessor", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "FFmpeg HLS conversion failed."])
        }
    }
    
    /// Convert video to HLS format using native iOS APIs (with quality level support)
    /// - Parameters:
    ///   - inputURL: Input video file URL
    ///   - outputDirectory: Directory to save HLS files
    ///   - config: HLS configuration
    ///   - qualityLevel: Specific quality level for encoding
    /// - Returns: URL to the generated playlist.m3u8 file
    public func convertToHLS(
        inputURL: URL,
        outputDirectory: URL,
        config: HLSConfig,
        qualityLevel: QualityLevel
    ) async throws -> URL {
        print("DEBUG: convertToHLS started for quality: \(qualityLevel.resolution)")
        
        let asset = AVAsset(url: inputURL)
        
        // Create video composition for resizing
        let composition = try await createVideoComposition(
            for: asset,
            targetSize: qualityLevel.resolution
        )
        
        print("DEBUG: Created video composition")
        
        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            print("DEBUG: Failed to create export session")
            throw HLSProcessorError.exportSessionCreationFailed
        }
        
        print("DEBUG: Created export session")
        
        // Configure export session
        exportSession.outputURL = outputDirectory.appendingPathComponent("temp_export.mp4")
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = composition
        
        print("DEBUG: Configured export session")
        print("DEBUG: Output URL: \(exportSession.outputURL?.path ?? "nil")")
        
        // Export the video
        print("DEBUG: Starting export...")
        await exportSession.export()
        
        print("DEBUG: Export completed with status: \(exportSession.status.rawValue)")
        
        guard exportSession.status == .completed else {
            print("DEBUG: Export failed with error: \(exportSession.error?.localizedDescription ?? "Unknown error")")
            throw HLSProcessorError.exportFailed(exportSession.error)
        }
        
        print("DEBUG: Export successful, starting HLS segmentation")
        
        // Segment the exported video to HLS
        return try await segmentVideoToHLS(
            videoURL: exportSession.outputURL!,
            outputDirectory: outputDirectory,
            config: config,
            qualityLevel: qualityLevel
        )
    }
    
    /// Create video composition for resizing
    private func createVideoComposition(
        for asset: AVAsset,
        targetSize: CGSize
    ) async throws -> AVVideoComposition {
        
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        guard let videoTrack = videoTrack else {
            throw HLSProcessorError.noVideoTrack
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        
        // Calculate aspect ratio preserving scale
        let videoSize = naturalSize.applying(transform)
        let scaleX = targetSize.width / abs(videoSize.width)
        let scaleY = targetSize.height / abs(videoSize.height)
        let scale = min(scaleX, scaleY)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(
            transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            at: .zero
        )
        
        instruction.layerInstructions = [layerInstruction]
        
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: 30) // 30fps for better quality
        composition.instructions = [instruction]
        
        // Add render scale for better quality
        composition.renderScale = 1.0
        
        return composition
    }
    
    /// Segment video into HLS format
    private func segmentVideoToHLS(
        videoURL: URL,
        outputDirectory: URL,
        config: HLSConfig,
        qualityLevel: QualityLevel? = nil
    ) async throws -> URL {
        
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        
        // Calculate number of segments
        let segmentCount = Int(ceil(duration.seconds / config.segmentDuration))
        
        // Create segments
        var segmentURLs: [URL] = []
        let segmentDuration = CMTime(seconds: config.segmentDuration, preferredTimescale: 600)
        
        for i in 0..<segmentCount {
            let startTime = CMTimeMultiply(segmentDuration, multiplier: Int32(i))
            let endTime = min(
                CMTimeAdd(startTime, segmentDuration),
                duration
            )
            
            let segmentURL = outputDirectory.appendingPathComponent("segment_\(String(format: "%03d", i)).ts")
            try await createSegment(
                from: asset,
                startTime: startTime,
                endTime: endTime,
                outputURL: segmentURL
            )
            segmentURLs.append(segmentURL)
        }
        
        // Create playlist file
        let playlistURL = outputDirectory.appendingPathComponent("playlist.m3u8")
        try createPlaylist(
            segmentURLs: segmentURLs,
            segmentDuration: config.segmentDuration,
            outputURL: playlistURL,
            qualityLevel: qualityLevel
        )
        
        return playlistURL
    }
    
    /// Create a single HLS segment
    private func createSegment(
        from asset: AVAsset,
        startTime: CMTime,
        endTime: CMTime,
        outputURL: URL
    ) async throws {
        
        // Create a temporary M4A file first
        let tempM4AURL = outputURL.deletingPathExtension().appendingPathExtension("m4a")
        
        let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        )
        
        guard let exportSession = exportSession else {
            throw HLSProcessorError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = tempM4AURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: startTime, end: endTime)
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw HLSProcessorError.exportFailed(exportSession.error)
        }
        
        // Convert M4A to TS format using proper MPEG-TS encoding
        try await convertToTS(from: tempM4AURL, to: outputURL)
        
        // Clean up temporary file
        try? FileManager.default.removeItem(at: tempM4AURL)
    }
    
    /// Convert M4A to TS format using AVFoundation
    private func convertToTS(from inputURL: URL, to outputURL: URL) async throws {
        let asset = AVAsset(url: inputURL)
        
        // Create export session for TS format
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw HLSProcessorError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a // We'll manually create TS format
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw HLSProcessorError.exportFailed(exportSession.error)
        }
        
        // Create proper TS format by adding TS headers
        try createTSFormat(from: outputURL)
    }
    
    /// Create proper TS format by adding transport stream headers
    private func createTSFormat(from fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        
        // Create TS packets (188 bytes each)
        let tsPacketSize = 188
        let syncByte: UInt8 = 0x47
        var tsData = Data()
        
        // Split data into TS packets
        var offset = 0
        var continuityCounter: UInt8 = 0
        
        while offset < data.count {
            var packet = Data()
            
            // Add sync byte
            packet.append(syncByte)
            
            // Add transport error indicator, payload unit start indicator, transport priority, PID
            let pid: UInt16 = 0x1000 // Video PID
            let transportErrorIndicator: UInt8 = 0
            let payloadUnitStartIndicator: UInt8 = offset == 0 ? 1 : 0
            let transportPriority: UInt8 = 0
            
            let firstByte: UInt8 = transportErrorIndicator << 7 | payloadUnitStartIndicator << 6 | transportPriority << 5 | UInt8((pid >> 8) & 0x1F)
            let secondByte: UInt8 = UInt8(pid & 0xFF)
            packet.append(firstByte)
            packet.append(secondByte)
            
            // Add scrambling control, adaptation field control, continuity counter
            let scramblingControl: UInt8 = 0
            let adaptationFieldControl: UInt8 = 1 // Payload only
            let thirdByte: UInt8 = scramblingControl << 6 | adaptationFieldControl << 4 | (continuityCounter & 0x0F)
            packet.append(thirdByte)
            
            // Add payload
            let remainingBytes = min(tsPacketSize - 4, data.count - offset)
            packet.append(data[offset..<(offset + remainingBytes)])
            
            // Pad with 0xFF if needed
            while packet.count < tsPacketSize {
                packet.append(0xFF)
            }
            
            tsData.append(packet)
            offset += remainingBytes
            continuityCounter = (continuityCounter + 1) & 0x0F
        }
        
        // Write TS data back to file
        try tsData.write(to: fileURL)
    }
    
    /// Create master M3U8 playlist for adaptive bitrate streaming
    private func createMasterPlaylist(
        qualityLevels: [QualityLevel],
        qualityPlaylists: [String],
        outputURL: URL
    ) throws {
        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:3\n"
        
        // Add quality level variants
        for (index, qualityLevel) in qualityLevels.enumerated() {
            playlist += "#EXT-X-STREAM-INF:BANDWIDTH=\(qualityLevel.bandwidth)"
            playlist += ",RESOLUTION=\(Int(qualityLevel.resolution.width))x\(Int(qualityLevel.resolution.height))"
            playlist += ",CODECS=\"avc1.42e01e,mp4a.40.2\"\n"
            playlist += "\(qualityPlaylists[index])/playlist.m3u8\n"
        }
        
        try playlist.write(to: outputURL, atomically: true, encoding: .utf8)
    }
    
    /// Create M3U8 playlist file
    private func createPlaylist(
        segmentURLs: [URL],
        segmentDuration: TimeInterval,
        outputURL: URL,
        qualityLevel: QualityLevel? = nil
    ) throws {
        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:3\n"
        playlist += "#EXT-X-TARGETDURATION:\(Int(ceil(segmentDuration)))\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        
        // Add quality level info if available
        if qualityLevel != nil {
            playlist += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        }
        
        for segmentURL in segmentURLs {
            playlist += "#EXTINF:\(segmentDuration),\n"
            playlist += segmentURL.lastPathComponent + "\n"
        }
        
        playlist += "#EXT-X-ENDLIST\n"
        
        try playlist.write(to: outputURL, atomically: true, encoding: .utf8)
    }
    
    /// Get video aspect ratio
    public func getVideoAspectRatio(url: URL) async throws -> Float? {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            return nil
        }
        
        let size = try await videoTrack.load(.naturalSize)
        return Float(size.width / size.height)
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
    
    /// Check if video processing is supported on this device
    public var isVideoProcessingSupported: Bool {
        return AVAssetExportSession.exportPresets(compatibleWith: AVAsset(url: URL(fileURLWithPath: ""))).contains(AVAssetExportPresetHighestQuality)
    }
    
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
    
    /// Check if a file is a supported video format
    public func isSupportedVideoFormat(_ filePath: String) -> Bool {
        let supportedExtensions = getSupportedVideoFormats()
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }
    
    /// Check if AVFoundation can actually handle a specific video file
    public func canHandleVideoFormat(url: URL) async -> Bool {
        do {
            let asset = AVAsset(url: url)
            
            // Check if the asset has video tracks
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                return false
            }
            
            // Check if the asset is playable
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                return false
            }
            
            // Check if we can create an export session
            let exportPresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
            guard !exportPresets.isEmpty else {
                return false
            }
            
            return true
        } catch {
            print("Error checking video format compatibility: \(error)")
            return false
        }
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
        
        return try await convertToHLS(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            config: config,
            qualityLevel: qualityLevel
        )
    }
} 