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
        
        // Get comprehensive video parameters
        await printVideoParameters(filePath: filePath, track: track, size: size)
        
        // Calculate display aspect ratio that accounts for rotation
        let displayAspectRatio = await getDisplayAspectRatio(track: track, naturalSize: size)
        print("DEBUG: Display aspect ratio: \(displayAspectRatio)")
        return displayAspectRatio
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
                aspectRatio = Float(naturalSize.height / naturalSize.width)
            } else {
                // For 0° or 180° rotation, use normal dimensions
                aspectRatio = Float(naturalSize.width / naturalSize.height)
            }
            
            return aspectRatio
        } catch {
            print("DEBUG: Error getting preferred transform, using natural aspect ratio: \(error)")
            // Fallback to natural aspect ratio if transform loading fails
            return Float(naturalSize.width / naturalSize.height)
        }
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
            
            // Get comprehensive video parameters
            await printVideoParameters(filePath: filePath, track: videoTrack, size: size)
            
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
} 
