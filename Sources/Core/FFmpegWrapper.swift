import Foundation
import AVFoundation

#if canImport(FFmpegSupport)
import FFmpegSupport
#endif

/// FFmpegWrapper provides a Swift-native interface for FFmpeg functionality
/// Uses FFmpeg-iOS Swift Package for video processing
public class FFmpegWrapper {
    
    public static let shared = FFmpegWrapper()
    
    private init() {}
    
    /// Check if FFmpeg-iOS Swift Package is available
    public var isFFmpegIOSAvailable: Bool {
        #if canImport(FFmpegSupport)
        return true
        #else
        return false
        #endif
    }
    
    /// Execute FFmpeg command using FFmpeg-iOS Swift Package
    /// - Parameter arguments: FFmpeg command arguments
    /// - Returns: Success status
    public func executeFFmpegCommand(_ arguments: [String]) -> Bool {
        #if canImport(FFmpegSupport)
        return ffmpeg(arguments) == 0
        #else
        print("FFmpeg-iOS Swift Package not available")
        return false
        #endif
    }
    
    /// Convert video format using FFmpeg
    /// - Parameters:
    ///   - inputPath: Input video file path
    ///   - outputPath: Output video file path
    ///   - format: Target format (e.g., "mp4", "mov")
    /// - Returns: Success status
    public func convertVideo(inputPath: String, outputPath: String, format: String) -> Bool {
        let arguments = [
            "ffmpeg",
            "-i", inputPath,
            "-c:v", "libx264",
            "-c:a", "aac",
            "-preset", "medium",
            "-crf", "23",
            outputPath
        ]
        
        return executeFFmpegCommand(arguments)
    }
    
    /// Extract audio from video
    /// - Parameters:
    ///   - inputPath: Input video file path
    ///   - outputPath: Output audio file path
    ///   - format: Audio format (e.g., "mp3", "aac")
    /// - Returns: Success status
    public func extractAudio(inputPath: String, outputPath: String, format: String) -> Bool {
        let arguments = [
            "ffmpeg",
            "-i", inputPath,
            "-vn",
            "-acodec", format == "mp3" ? "libmp3lame" : "aac",
            "-ab", "192k",
            outputPath
        ]
        
        return executeFFmpegCommand(arguments)
    }
    
    /// Compress video
    /// - Parameters:
    ///   - inputPath: Input video file path
    ///   - outputPath: Output video file path
    ///   - quality: Compression quality (0-51, lower is better)
    /// - Returns: Success status
    public func compressVideo(inputPath: String, outputPath: String, quality: Int = 23) -> Bool {
        let arguments = [
            "ffmpeg",
            "-i", inputPath,
            "-c:v", "libx264",
            "-c:a", "aac",
            "-preset", "medium",
            "-crf", String(quality),
            "-movflags", "+faststart",
            outputPath
        ]
        
        return executeFFmpegCommand(arguments)
    }
    
    /// Create video thumbnail
    /// - Parameters:
    ///   - inputPath: Input video file path
    ///   - outputPath: Output thumbnail image path
    ///   - time: Time position in seconds (default: 1.0)
    /// - Returns: Success status
    public func createThumbnail(inputPath: String, outputPath: String, time: Double = 1.0) -> Bool {
        let arguments = [
            "ffmpeg",
            "-i", inputPath,
            "-ss", String(time),
            "-vframes", "1",
            "-q:v", "2",
            outputPath
        ]
        
        return executeFFmpegCommand(arguments)
    }
}

// MARK: - Convenience Extensions

extension FFmpegWrapper {
    
    /// Check if a file is a supported video format
    /// - Parameter filePath: File path to check
    /// - Returns: True if supported video format
    public func isSupportedVideoFormat(_ filePath: String) -> Bool {
        let supportedExtensions = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "3gp"]
        let fileExtension = (filePath as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }
    
    /// Get supported video formats
    /// - Returns: Array of supported video format extensions
    public func getSupportedVideoFormats() -> [String] {
        return ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "3gp"]
    }
} 