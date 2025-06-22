import Foundation
import AVFoundation
import UIKit

/// A Swift wrapper for FFmpeg functionality
class FFmpegManager {
    
    static let shared = FFmpegManager()
    
    private init() {}
    
    /// Converts a video file to HLS format
    /// - Parameters:
    ///   - inputPath: Path to the input video file
    ///   - outputDirectory: Directory where HLS files will be saved
    /// - Returns: Result indicating success or failure with error message
    func convertToHLS(inputPath: String, outputDirectory: String) -> Result<String, Error> {
        // Ensure output directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory) {
            do {
                try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            } catch {
                return .failure(FFmpegError.directoryCreationFailed(error))
            }
        }
        
        // Call the C function
        let result = convert_to_hls(inputPath, outputDirectory)
        
        if result == 0 {
            let playlistPath = "\(outputDirectory)/playlist.m3u8"
            return .success(playlistPath)
        } else {
            return .failure(FFmpegError.conversionFailed(result))
        }
    }
    
    /// Gets video information using FFmpeg
    /// - Parameter filePath: Path to the video file
    /// - Returns: Video information or error
    func getVideoInfo(filePath: String) async -> Result<VideoInfo, Error> {
        // This would require additional C functions to be implemented
        // For now, we'll use AVFoundation as a fallback
        let url = URL(fileURLWithPath: filePath)
        
        do {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            
            guard let videoTrack = tracks.first else {
                return .failure(FFmpegError.noVideoTrack)
            }
            
            let size = try await videoTrack.load(.naturalSize)
            let frameRate = try await videoTrack.load(.nominalFrameRate)
            
            let info = VideoInfo(
                duration: duration.seconds,
                width: Int(size.width),
                height: Int(size.height),
                frameRate: frameRate,
                fileSize: try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64 ?? 0
            )
            
            return .success(info)
        } catch {
            return .failure(FFmpegError.videoInfoFailed(error))
        }
    }
    
    /// Extracts thumbnail from video
    /// - Parameters:
    ///   - videoPath: Path to the video file
    ///   - outputPath: Path where thumbnail will be saved
    ///   - time: Time position in seconds (default: 1.0)
    /// - Returns: Result indicating success or failure
    func extractThumbnail(videoPath: String, outputPath: String, time: Double = 1.0) -> Result<Void, Error> {
        // This would require implementing a C function for thumbnail extraction
        // For now, we'll use AVFoundation
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVAsset(url: url)
        
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 320, height: 240)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 1), actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            
            if let data = uiImage.jpegData(compressionQuality: 0.8) {
                try data.write(to: URL(fileURLWithPath: outputPath))
                return .success(())
            } else {
                return .failure(FFmpegError.thumbnailGenerationFailed)
            }
        } catch {
            return .failure(FFmpegError.thumbnailGenerationFailed)
        }
    }
}

// MARK: - Supporting Types

struct VideoInfo {
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Float
    let fileSize: Int64
}

enum FFmpegError: Error, LocalizedError {
    case conversionFailed(Int32)
    case directoryCreationFailed(Error)
    case noVideoTrack
    case videoInfoFailed(Error)
    case thumbnailGenerationFailed
    
    var errorDescription: String? {
        switch self {
        case .conversionFailed(let code):
            return "FFmpeg conversion failed with code: \(code)"
        case .directoryCreationFailed(let error):
            return "Failed to create output directory: \(error.localizedDescription)"
        case .noVideoTrack:
            return "No video track found in the file"
        case .videoInfoFailed(let error):
            return "Failed to get video info: \(error.localizedDescription)"
        case .thumbnailGenerationFailed:
            return "Failed to generate thumbnail"
        }
    }
} 