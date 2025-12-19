//
//  HLSVideoProcessor.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/06/25.
//

import Foundation
import AVFoundation
import UIKit
import ffmpegkit

/// HLSVideoProcessor provides video metadata extraction for backend-based video processing
/// Since video conversion is now handled on the backend, this class focuses on aspect ratio detection
public class HLSVideoProcessor {
    
    public static let shared = HLSVideoProcessor()
    
    private init() {}
    
    /// Get video aspect ratio with multiple fallback approaches
    public func getVideoAspectRatio(filePath: String) async throws -> Float? {
        print("DEBUG: Getting video aspect ratio for file: \(filePath)")

        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }

        let size = try await track.load(.naturalSize)

        // Validate dimensions are reasonable (allow small videos but reject impossible values)
        guard size.width >= 1, size.height >= 1,
              size.width.isFinite, size.height.isFinite,
              size.width < 100000, size.height < 100000 else {
            print("DEBUG: Unreasonable video dimensions: width=\(size.width), height=\(size.height), using fallback")
            // For truly invalid dimensions, return a standard aspect ratio instead of failing
            return 16.0/9.0 // Standard widescreen fallback
        }

        // Get comprehensive video parameters
        await printVideoParameters(filePath: filePath, track: track, size: size)

        // Calculate display aspect ratio that accounts for rotation
        let displayAspectRatio = await getDisplayAspectRatio(track: track, naturalSize: size)

        // Validate and clamp the calculated aspect ratio to reasonable bounds
        let clampedAspectRatio: Float
        if displayAspectRatio.isFinite && displayAspectRatio > 0 {
            // Clamp to reasonable bounds (0.1:1 to 10:1 aspect ratios)
            clampedAspectRatio = max(0.1, min(10.0, displayAspectRatio))
        } else {
            print("DEBUG: Invalid calculated aspect ratio: \(displayAspectRatio), using fallback")
            clampedAspectRatio = 16.0/9.0 // Standard widescreen fallback
        }

        print("DEBUG: Display aspect ratio: \(clampedAspectRatio)")
        return clampedAspectRatio
    }
    
    /// Calculate display aspect ratio accounting for video rotation
    private func getDisplayAspectRatio(track: AVAssetTrack, naturalSize: CGSize) async -> Float {
        do {
            let preferredTransform = try await track.load(.preferredTransform)

            // Calculate rotation from transform
            let angle = atan2(preferredTransform.b, preferredTransform.a) * 180 / .pi
            let rotation = Int(round(angle))

            // Check if dimensions should be swapped for display
            let isRotated90or270 = rotation == 90 || rotation == 270 ||
                                  (abs(preferredTransform.a) < 0.1 && abs(preferredTransform.d) < 0.1)

            let aspectRatio: Float
            if isRotated90or270 {
                // For 90° or 270° rotation, swap width and height
                // Use max() to avoid division by zero, but allow very small dimensions
                let safeWidth = max(Float(naturalSize.width), 1.0)
                aspectRatio = Float(naturalSize.height) / safeWidth
            } else {
                // For 0° or 180° rotation, use normal dimensions
                // Use max() to avoid division by zero, but allow very small dimensions
                let safeHeight = max(Float(naturalSize.height), 1.0)
                aspectRatio = Float(naturalSize.width) / safeHeight
            }

            // Ensure aspect ratio is reasonable (clamp to valid range or use fallback)
            if !aspectRatio.isFinite || aspectRatio <= 0 {
                print("DEBUG: Invalid aspect ratio calculated: \(aspectRatio), using fallback")
                return 16.0/9.0 // Standard widescreen fallback
            }

            return aspectRatio
        } catch {
            print("DEBUG: Error getting preferred transform, using natural aspect ratio: \(error)")
            // Fallback to natural aspect ratio if transform loading fails
            // Use max() to avoid division by zero
            let safeHeight = max(Float(naturalSize.height), 1.0)
            let fallbackRatio = Float(naturalSize.width) / safeHeight

            if !fallbackRatio.isFinite || fallbackRatio <= 0 {
                print("DEBUG: Invalid fallback aspect ratio: \(fallbackRatio), using standard fallback")
                return 16.0/9.0 // Standard widescreen fallback
            }
            return fallbackRatio
        }
    }
    
    /// Get video dimensions (width and height) from a video file
    public func getVideoDimensions(filePath: String) async -> CGSize {
        print("DEBUG: Getting video dimensions for file: \(filePath)")
        
        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            print("DEBUG: Found \(tracks.count) video tracks")
            guard let videoTrack = tracks.first else {
                print("DEBUG: No video track found, using default fallback")
                return CGSize(width: 480, height: 270) // Default fallback
            }
            
            let size = try await videoTrack.load(.naturalSize)
            
            // Get comprehensive video parameters
            await printVideoParameters(filePath: filePath, track: videoTrack, size: size)
            
            print("DEBUG: Loaded video dimensions: \(size)")
            return size
        } catch {
            print("DEBUG: Error getting video dimensions: \(error)")
            return CGSize(width: 480, height: 270) // Default fallback
        }
    }
    
    /// Get source video bitrate in kbps
    public func getSourceVideoBitrate(filePath: String) async throws -> Int? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return nil }
        
        do {
            let bitRate = try await track.load(.estimatedDataRate)
            // Convert from bps to kbps
            let bitRateKbps = Int(bitRate / 1000)
            return bitRateKbps
        } catch {
            print("❌ Error getting source video bitrate: \(error)")
            return nil
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
    
    /// Print comprehensive video parameters for uploaded files
    private func printVideoParameters(filePath: String, track: AVAssetTrack, size: CGSize) async {
        print("=== VIDEO PARAMETERS FOR: \(filePath) ===")
        
        // Basic file info
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        print("📁 File Name: \(fileName)")
        
        // File size
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let fileSizeMB = Double(fileSize) / (1024 * 1024)
            print("📏 File Size: \(fileSize) bytes (\(String(format: "%.2f", fileSizeMB)) MB)")
        } catch {
            print("❌ Error getting file size: \(error)")
        }
        
        // Video dimensions
        print("📐 Natural Dimensions: \(size.width) x \(size.height)")
        print("📐 Aspect Ratio: \(size.width / size.height)")
        
        // Get preferred transform and rotation
        do {
            let preferredTransform = try await track.load(.preferredTransform)
            print("🔄 Preferred Transform: \(preferredTransform)")
            
            // Calculate rotation from transform
            let angle = atan2(preferredTransform.b, preferredTransform.a) * 180 / .pi
            let rotation = Int(round(angle))
            print("🔄 Calculated Rotation: \(rotation)°")
            
            // Check if dimensions should be swapped for display
            let isRotated90or270 = rotation == 90 || rotation == 270 || 
                                  (abs(preferredTransform.a) < 0.1 && abs(preferredTransform.d) < 0.1)
            
            if isRotated90or270 {
                let displaySize = CGSize(width: size.height, height: size.width)
                print("🔄 Display Dimensions (rotated): \(displaySize.width) x \(displaySize.height)")
                print("🔄 Display Aspect Ratio (rotated): \(displaySize.width / displaySize.height)")
            } else {
                print("🔄 Display Dimensions: \(size.width) x \(size.height)")
                print("🔄 Display Aspect Ratio: \(size.width / size.height)")
            }
        } catch {
            print("❌ Error getting preferred transform: \(error)")
        }
        
        // Get format descriptions and side data
        do {
            let formatDescriptions = try await track.load(.formatDescriptions)
            print("📋 Format Descriptions Count: \(formatDescriptions.count)")
            
            for (index, formatDescription) in formatDescriptions.enumerated() {
                print("📋 Format Description \(index + 1):")
                
                let videoFormatDescription = formatDescription 
                let extensions = CMFormatDescriptionGetExtensions(videoFormatDescription) as? [String: Any]
                
                if let extensions = extensions {
                    print("📋 Extensions: \(extensions)")
                    
                    // Check for Display Matrix
                    if let displayMatrix = extensions["DisplayMatrix"] as? [String: Any] {
                        print("🔄 Display Matrix: \(displayMatrix)")
                        if let rotation = displayMatrix["Rotation"] as? Int {
                            print("🔄 Rotation from Display Matrix: \(rotation)°")
                        }
                    }
                    
                    // Check for other rotation metadata
                    if let rotation = extensions["Rotation"] as? Int {
                        print("🔄 Rotation from Extensions: \(rotation)°")
                    }
                    
                    // Check for codec info
                    if let codec = extensions["VideoCodecType"] {
                        print("🎬 Codec: \(codec)")
                    }
                    
                    // Check for bitrate
                    if let bitrate = extensions["BitRate"] {
                        print("📊 Bitrate: \(bitrate)")
                    }
                    
                    // Check for frame rate
                    if let frameRate = extensions["FrameRate"] {
                        print("🎞️ Frame Rate: \(frameRate)")
                    }
                } else {
                    print("📋 No extensions found")
                }
            }
        } catch {
            print("❌ Error getting format descriptions: \(error)")
        }
        
        // Get additional track properties
        do {
            let frameRate = try await track.load(.nominalFrameRate)
            print("🎞️ Nominal Frame Rate: \(frameRate) fps")
        } catch {
            print("❌ Error getting frame rate: \(error)")
        }
        
        do {
            let bitRate = try await track.load(.estimatedDataRate)
            let bitRateMbps = bitRate / 1_000_000
            print("📊 Estimated Data Rate: \(String(format: "%.2f", bitRateMbps)) Mbps")
        } catch {
            print("❌ Error getting bit rate: \(error)")
        }
        
        // Get track format
        do {
            let formatDescriptions = try await track.load(.formatDescriptions)
            if let firstFormat = formatDescriptions.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(firstFormat)
                let mediaSubTypeString = String(describing: mediaSubType)
                print("🎬 Media Sub Type: \(mediaSubTypeString)")
            }
        } catch {
            print("❌ Error getting media sub type: \(error)")
        }
        
        print("=== END VIDEO PARAMETERS ===")
    }
    
    /// Get video info using FFmpeg (like the server does)
    public func getVideoInfoWithFFmpeg(filePath: String) async -> (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)? {
        return await withCheckedContinuation { continuation in
            let command = "ffprobe -v quiet -print_format json -show_format -show_streams \"\(filePath)\""
            print("DEBUG: [FFMPEG PROBE] Running command: \(command)")
            
            FFmpegKit.executeAsync(command) { session in
                guard let session = session else {
                    print("DEBUG: [FFMPEG PROBE] Failed to create session")
                    continuation.resume(returning: nil)
                    return
                }
                
                let returnCode = session.getReturnCode()
                print("DEBUG: [FFMPEG PROBE] Return code: \(String(describing: returnCode))")
                
                if ReturnCode.isSuccess(returnCode) {
                    if let logs = session.getLogs() as? [Log] {
                        var output = ""
                        for log in logs {
                            output += log.getMessage()
                        }
                        print("DEBUG: [FFMPEG PROBE] Raw output: \(output)")
                        
                        // Parse JSON output
                        if let data = output.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let streams = json["streams"] as? [[String: Any]] {
                            
                            print("DEBUG: [FFMPEG PROBE] Found \(streams.count) streams")
                            
                            for stream in streams {
                                if stream["codec_type"] as? String == "video" {
                                    let width = stream["width"] as? Int ?? 0
                                    let height = stream["height"] as? Int ?? 0
                                    
                                    var rotation = 0
                                    if let sideDataList = stream["side_data_list"] as? [[String: Any]] {
                                        print("DEBUG: [FFMPEG PROBE] Found side_data_list with \(sideDataList.count) items")
                                        for sideData in sideDataList {
                                            if sideData["side_data_type"] as? String == "Display Matrix" {
                                                if let matrix = sideData["rotation"] as? Int {
                                                    rotation = matrix
                                                }
                                                break
                                            }
                                        }
                                    } else {
                                        print("DEBUG: [FFMPEG PROBE] No side_data_list found")
                                    }
                                    
                                    var displayWidth = width
                                    var displayHeight = height
                                    
                                    if rotation == 90 || rotation == -90 {
                                        displayWidth = height
                                        displayHeight = width
                                    }
                                    
                                    print("DEBUG: [FFMPEG PROBE] Video dimensions: \(width)x\(height)")
                                    print("DEBUG: [FFMPEG PROBE] Display dimensions (after rotation): \(displayWidth)x\(displayHeight)")
                                    print("DEBUG: [FFMPEG PROBE] Rotation: \(rotation) degrees")
                                    
                                    continuation.resume(returning: (width, height, displayWidth, displayHeight, rotation))
                                    return
                                }
                            }
                            print("DEBUG: [FFMPEG PROBE] No video stream found")
                        } else {
                            print("DEBUG: [FFMPEG PROBE] Failed to parse JSON")
                        }
                    } else {
                        print("DEBUG: [FFMPEG PROBE] No logs found")
                    }
                    continuation.resume(returning: nil)
                } else {
                    print("DEBUG: [FFMPEG PROBE] Command failed with return code: \(String(describing: returnCode))")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
} 
