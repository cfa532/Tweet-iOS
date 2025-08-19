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
    ///   - targetWidth: Target width for the HLS stream
    ///   - targetHeight: Target height for the HLS stream
    /// - Returns: Result indicating success or failure with error message
    func convertToHLS(inputPath: String, outputDirectory: String, targetWidth: Int32, targetHeight: Int32) -> Result<String, Error> {
        print("FFmpeg C Wrapper: Starting single-resolution HLS conversion.")
        print("Input file: \(inputPath)")
        print("Output directory: \(outputDirectory)")
        print("Target resolution: \(targetWidth)x\(targetHeight)")
        
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
        let result = create_single_hls_stream_with_resolution(inputPath, outputDirectory, targetWidth, targetHeight)
        
        if result == 0 {
            print("✅ FFmpeg HLS conversion completed successfully")
            let playlistPath = "\(outputDirectory)/playlist.m3u8"
            return .success(playlistPath)
        } else {
            print("❌ FFmpeg HLS conversion failed: FFmpeg conversion failed with code: \(result)")
            return .failure(FFmpegError.conversionFailed(result))
        }
    }
    
    /// Converts a video file to multiple quality HLS streams with adaptive bitrate
    /// - Parameters:
    ///   - inputPath: Path to the input video file
    ///   - outputDirectory: Directory where HLS files will be saved
    /// - Returns: Result indicating success or failure with error message
    func convertToMultiQualityHLS(inputPath: String, outputDirectory: String) -> Result<String, Error> {
        print("FFmpeg C Wrapper: Starting multi-quality HLS conversion.")
        print("Input file: \(inputPath)")
        print("Output directory: \(outputDirectory)")
        
        // Ensure output directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory) {
            do {
                try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            } catch {
                return .failure(FFmpegError.directoryCreationFailed(error))
            }
        }
        
        // Call the C function for multi-quality conversion
        let result = convert_to_multi_quality_hls(inputPath, outputDirectory)
        
        if result == 0 {
            print("✅ FFmpeg multi-quality HLS conversion completed successfully")
            let masterPlaylistPath = "\(outputDirectory)/master.m3u8"
            return .success(masterPlaylistPath)
        } else {
            print("❌ FFmpeg multi-quality HLS conversion failed: FFmpeg conversion failed with code: \(result)")
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
            let asset = AVURLAsset(url: url)
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
        let asset = AVURLAsset(url: url)
        
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 320, height: 240)
        
        // Use a semaphore to make the async call synchronous for this method
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(FFmpegError.thumbnailGenerationFailed)
        
        imageGenerator.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 1)) { cgImage, actualTime, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = .failure(error)
                return
            }
            
            guard let cgImage = cgImage else {
                result = .failure(FFmpegError.thumbnailGenerationFailed)
                return
            }
            
            let uiImage = UIImage(cgImage: cgImage)
            
            if let data = uiImage.jpegData(compressionQuality: 0.8) {
                do {
                    try data.write(to: URL(fileURLWithPath: outputPath))
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(FFmpegError.thumbnailGenerationFailed)
            }
        }
        
        semaphore.wait()
        return result
    }
    
    /// Convert video to medium quality HLS only (for testing)
    func convertToMediumHLS(inputPath: String, outputDirectory: String) -> Result<String, Error> {
        print("🎬 Starting medium-only HLS conversion...")
        
        let result = convert_to_medium_hls(inputPath, outputDirectory)
        
        if result == 0 {
            let masterPlaylistPath = "\(outputDirectory)/playlist.m3u8"
            print("✅ Medium-only HLS conversion successful")
            return .success(masterPlaylistPath)
        } else {
            let error = NSError(domain: "FFmpegManager", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "Medium-only HLS conversion failed with error code: \(result)"
            ])
            print("❌ Medium-only HLS conversion failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
    
    /// Convert video to medium quality HLS with specified resolution
    func convertToMediumHLSWithResolution(inputPath: String, outputDirectory: String, width: Int32, height: Int32) -> Result<String, Error> {
        print("🎬 Starting medium-only HLS conversion with resolution \(width)x\(height)...")
        
        let result = convert_to_medium_hls_with_resolution(inputPath, outputDirectory, width, height)
        
        if result == 0 {
            let masterPlaylistPath = "\(outputDirectory)/playlist.m3u8"
            print("✅ Medium-only HLS conversion with resolution \(width)x\(height) successful")
            return .success(masterPlaylistPath)
        } else {
            let error = NSError(domain: "FFmpegManager", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "Medium-only HLS conversion failed with error code: \(result)"
            ])
            print("❌ Medium-only HLS conversion failed: \(error.localizedDescription)")
            return .failure(error)
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
            return String(format: NSLocalizedString("FFmpeg conversion failed with code: %d", comment: "FFmpeg conversion error"), code)
        case .directoryCreationFailed(let error):
            return String(format: NSLocalizedString("Failed to create output directory: %@", comment: "Directory creation error"), error.localizedDescription)
        case .noVideoTrack:
            return NSLocalizedString("No video track found in the file", comment: "No video track error")
        case .videoInfoFailed(let error):
            return String(format: NSLocalizedString("Failed to get video info: %@", comment: "Video info error"), error.localizedDescription)
        case .thumbnailGenerationFailed:
            return NSLocalizedString("Failed to generate thumbnail", comment: "Thumbnail generation error")
        }
    }
} 