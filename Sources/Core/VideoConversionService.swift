import Foundation
import ffmpegkit
import UIKit

struct HLSConversionResult {
    let success: Bool
    let hlsDirectoryURL: URL?
    let errorMessage: String?
}

struct VideoInfo {
    let width: Int
    let height: Int
    let duration: Double?
}

struct ConversionProgress {
    let stage: String
    let progress: Int // 0-100
    let estimatedTimeRemaining: TimeInterval?
}

class VideoConversionService {
    static let shared = VideoConversionService()
    
    private var currentConversion: Task<Void, Never>?
    private var progressCallback: ((ConversionProgress) -> Void)?

    private init() {
        // FFmpegKit configuration
    }
    
    func convertVideoToHLS(
        inputURL: URL,
        outputDirectory: URL,
        fileSizeBytes: Int64,
        aspectRatio: Float? = nil,
        singleVariant480p: Bool = false,
        sourceVideoResolution: Int,
        isNormalized: Bool = false,
        progressCallback: @escaping (ConversionProgress) -> Void,
        completion: @escaping (HLSConversionResult) -> Void
    ) {
        print("DEBUG: [VIDEO CONVERSION] Starting foreground conversion for \(inputURL.lastPathComponent)")
        
        // Cancel any existing conversion
        cancelCurrentConversion()
        
        // Store progress callback
        self.progressCallback = progressCallback
        
        // OPTIMIZATION: Force memory cleanup before starting conversion
        // This ensures we have maximum available memory for FFmpeg
        logMemoryUsage("before pre-conversion cleanup")
        forceMemoryCleanup()
        logMemoryUsage("after pre-conversion cleanup")

        // HLS conversion configuration:
        // Single variant: 480p (600kb) only
        // Dual variant: high-quality (proportional bitrate) + 480p (600kb)
        // High-quality variant uses actual source resolution (capped at 720p)
        let lowerResolution = 480
        let highQualityResolution = min(sourceVideoResolution, 720) // Cap at 720p
        
        // Create HLS directory structure
        // Single variant: playlist.m3u8 at root (hls/playlist.m3u8)
        // Dual variant: master.m3u8 at root with subdirectories (hls/master.m3u8, hls/720p/, hls/480p/)
        let hlsDirectory = outputDirectory.appendingPathComponent("hls")
        let hls720pDir = hlsDirectory.appendingPathComponent("720p")
        let lowerResDir = hlsDirectory.appendingPathComponent("\(lowerResolution)p")
        
        // Create directories based on variant mode
        if singleVariant480p {
            // Single variant: no subdirectories needed, playlist goes at root
            try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
        } else {
            // Dual variant: create subdirectories for variants
            try? FileManager.default.createDirectory(at: hls720pDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: lowerResDir, withIntermediateDirectories: true)
        }
        
        // Create output URLs
        // For single variant: playlist at root
        // For dual variant: playlists in subdirectories + master at root
        let hls720pURL = hls720pDir.appendingPathComponent("playlist.m3u8")
        let lowerResURL = singleVariant480p ? hlsDirectory.appendingPathComponent("playlist.m3u8") : lowerResDir.appendingPathComponent("playlist.m3u8")
        let masterPlaylistURL = hlsDirectory.appendingPathComponent("master.m3u8")
        
        // Log initial memory usage
        logMemoryUsage("before conversion")
        
        // OPTIMIZATION: Use lower priority to reduce CPU/memory contention
        // High priority was causing excessive memory pressure and breaking video players
        // Using .userInitiated instead of .high reduces resource competition
        currentConversion = Task(priority: .userInitiated) { [weak self] in
            // Get source video info for resolution detection
            let videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
            
            // Calculate target bitrates based on actual resolution
            // High-quality variant: proportional bitrate (1000k for 720p, scaled down for lower resolutions)
            // Lower variant: always 600k for 480p
            let targetHighQualityKbps = Int(1000.0 * Double(highQualityResolution) / 720.0)
            let targetLowerKbps = 600  // Always use 600k for 480p
            
            let highQualityBitrate = "\(targetHighQualityKbps)k"
            let lowerResolutionBitrate = "\(targetLowerKbps)k"
            
            if !singleVariant480p {
                print("📊 Using calculated bitrates: \(highQualityResolution)p=\(highQualityBitrate), 480p=\(lowerResolutionBitrate)")
            } else {
                print("📊 Using calculated bitrate: 480p=\(lowerResolutionBitrate)")
            }
            
            await self?.performConversion(
                inputURL: inputURL,
                hls720pURL: hls720pURL,
                lowerResURL: lowerResURL,
                masterPlaylistURL: masterPlaylistURL,
                hlsDirectory: hlsDirectory,
                aspectRatio: aspectRatio,
                highQualityResolution: highQualityResolution,
                highQualityBitrate: highQualityBitrate,
                lowerResolution: lowerResolution,
                lowerResolutionBitrate: lowerResolutionBitrate,
                videoInfo: videoInfo,
                singleVariant480p: singleVariant480p,
                isNormalized: isNormalized,
                completion: completion
            )
        }
    }
    
    
    // MARK: - Memory Management
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // Use phys_footprint for accurate measurement
            var vmInfo = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
            let vmKerr = withUnsafeMutablePointer(to: &vmInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            
            if vmKerr == KERN_SUCCESS {
                return Double(vmInfo.phys_footprint) / 1024.0 / 1024.0 // Convert to MB
            } else {
                return Double(info.resident_size) / 1024.0 / 1024.0 // Fallback
            }
        } else {
            return 0.0
        }
    }
    
    func logMemoryUsage(_ context: String) {
        let memory = getMemoryUsage()
        print("DEBUG: [VIDEO CONVERSION] Memory usage \(context): \(String(format: "%.1f", memory)) MB")

        // Warn if memory usage is getting high (>200MB)
        let highMemoryThreshold: Double = 200.0
        if memory > highMemoryThreshold {
            print("WARNING: [VIDEO CONVERSION] High memory usage detected: \(String(format: "%.1f", memory)) MB")
        }
    }
    
    private func forceMemoryCleanup() {
        // Force garbage collection
        autoreleasepool {
            // This will help release any autoreleased objects
        }

        // Log memory after cleanup
        logMemoryUsage("after cleanup")

        // If memory is still high after cleanup, warn
        let memory = getMemoryUsage()
        let criticalMemoryThreshold: Double = 300.0 // 300MB
        if memory > criticalMemoryThreshold {
            print("CRITICAL: [VIDEO CONVERSION] Memory usage still high after cleanup: \(String(format: "%.1f", memory)) MB")
        }
    }
    
    func cancelCurrentConversion() {
        currentConversion?.cancel()
        currentConversion = nil
    }
    
    // MARK: - Async Conversion
    
    private func performConversion(
        inputURL: URL,
        hls720pURL: URL,
        lowerResURL: URL,
        masterPlaylistURL: URL,
        hlsDirectory: URL,
        aspectRatio: Float?,
        highQualityResolution: Int,
        highQualityBitrate: String,
        lowerResolution: Int,
        lowerResolutionBitrate: String,
        videoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?,
        singleVariant480p: Bool,
        isNormalized: Bool,
        completion: @escaping (HLSConversionResult) -> Void
    ) async {
        // Calculate actual resolutions based on source video and aspect ratio
        // If source resolution is lower than target, preserve it
        var finalWidthHighQuality: Int
        var finalHeightHighQuality: Int
        var finalWidthLower: Int
        var finalHeightLower: Int
        
        if let videoInfo = videoInfo {
            let sourceWidth = videoInfo.displayWidth
            let sourceHeight = videoInfo.displayHeight
            let sourceMaxDimension = max(sourceWidth, sourceHeight)
            
            // For high-quality stream (actual resolution, capped at 720p)
            if sourceMaxDimension < highQualityResolution {
                // Preserve original resolution
                finalWidthHighQuality = sourceWidth
                finalHeightHighQuality = sourceHeight
                print("DEBUG: [MASTER PLAYLIST] Preserving original resolution for \(highQualityResolution)p stream: \(finalWidthHighQuality)x\(finalHeightHighQuality)")
            } else {
                // Calculate scaled resolution
                let calculated = calculateActualResolution(targetResolution: highQualityResolution, aspectRatio: aspectRatio)
                let components = calculated.components(separatedBy: "x")
                finalWidthHighQuality = Int(components[0]) ?? (highQualityResolution == 720 ? 1280 : Int(Double(highQualityResolution) * 16.0 / 9.0))
                finalHeightHighQuality = Int(components[1]) ?? highQualityResolution
            }
            
            // For lower resolution stream
            if sourceMaxDimension < lowerResolution {
                // Preserve original resolution
                finalWidthLower = sourceWidth
                finalHeightLower = sourceHeight
                print("DEBUG: [MASTER PLAYLIST] Preserving original resolution for \(lowerResolution)p stream: \(finalWidthLower)x\(finalHeightLower)")
            } else {
                // Calculate scaled resolution
                let calculated = calculateActualResolution(targetResolution: lowerResolution, aspectRatio: aspectRatio)
                let components = calculated.components(separatedBy: "x")
                finalWidthLower = Int(components[0]) ?? (lowerResolution == 480 ? 854 : 640)
                finalHeightLower = Int(components[1]) ?? lowerResolution
            }
        } else {
            // Fallback to calculated resolutions
            let actualHighQualityResolution = calculateActualResolution(targetResolution: highQualityResolution, aspectRatio: aspectRatio)
            let actualLowerResResolution = calculateActualResolution(targetResolution: lowerResolution, aspectRatio: aspectRatio)
            let componentsHighQuality = actualHighQualityResolution.components(separatedBy: "x")
            let componentsLower = actualLowerResResolution.components(separatedBy: "x")
            finalWidthHighQuality = Int(componentsHighQuality[0]) ?? (highQualityResolution == 720 ? 1280 : Int(Double(highQualityResolution) * 16.0 / 9.0))
            finalHeightHighQuality = Int(componentsHighQuality[1]) ?? highQualityResolution
            finalWidthLower = Int(componentsLower[0]) ?? (lowerResolution == 480 ? 854 : 640)
            finalHeightLower = Int(componentsLower[1]) ?? lowerResolution
        }
        
        let actualHighQualityResolution = "\(finalWidthHighQuality)x\(finalHeightHighQuality)"
        let actualLowerResResolution = "\(finalWidthLower)x\(finalHeightLower)"
        
        if !singleVariant480p {
            print("DEBUG: [MASTER PLAYLIST] Final \(highQualityResolution)p resolution: \(actualHighQualityResolution)")
        }
        print("DEBUG: [MASTER PLAYLIST] Final \(lowerResolution)p resolution: \(actualLowerResResolution)")
        
        var resultHighQuality = true
        
        // Step 1: Convert to high-quality HLS (if dual variant mode)
        if !singleVariant480p {
            await updateProgress(stage: "Converting to \(highQualityResolution)p HLS...", progress: 10)
            logMemoryUsage("before \(highQualityResolution)p conversion")
            
            resultHighQuality = await convertToHLSAsync(
                inputURL: inputURL,
                outputURL: hls720pURL,
                resolution: "\(highQualityResolution)",
                bitrate: highQualityBitrate,
                aspectRatio: aspectRatio,
                cachedVideoInfo: videoInfo,
                isNormalized: isNormalized
            )
            
            logMemoryUsage("after \(highQualityResolution)p conversion")
            
            // OPTIMIZATION: Force memory cleanup between conversions
            // This is critical to prevent memory accumulation during dual-variant encoding
            forceMemoryCleanup()
            
            // OPTIMIZATION: Yield to allow system to reclaim memory
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second pause
            logMemoryUsage("after cleanup pause")
            
            guard resultHighQuality else {
                await MainActor.run {
                    completion(HLSConversionResult(
                        success: false,
                        hlsDirectoryURL: nil,
                        errorMessage: "Failed to convert to \(highQualityResolution)p HLS"
                    ))
                }
                return
            }
        }
        
        // Step 2: Convert to lower resolution HLS
        let progressStart = singleVariant480p ? 10 : 60
        await updateProgress(stage: "Converting to \(lowerResolution)p HLS...", progress: progressStart)
        logMemoryUsage("before \(lowerResolution)p conversion")
        
        let resultLowerRes = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: lowerResURL,
            resolution: "\(lowerResolution)",
            bitrate: lowerResolutionBitrate,
            aspectRatio: aspectRatio,
            cachedVideoInfo: videoInfo,
            isNormalized: false  // Lower resolution is never normalized
        )
        
        logMemoryUsage("after \(lowerResolution)p conversion")
        
        // OPTIMIZATION: Force memory cleanup after lower resolution conversion
        forceMemoryCleanup()
        
        // OPTIMIZATION: Yield to allow system to reclaim memory
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second pause
        logMemoryUsage("after final cleanup pause")
        
        guard resultLowerRes else {
            await MainActor.run {
                completion(HLSConversionResult(
                    success: false,
                    hlsDirectoryURL: nil,
                    errorMessage: "Failed to convert to \(lowerResolution)p HLS"
                ))
            }
            return
        }
        
        // Step 3: Create master playlist (dual variant) or use root playlist (single variant)
        if singleVariant480p {
            // Single variant: playlist.m3u8 is already created at root, no master needed
            await updateProgress(stage: "Conversion completed!", progress: 100)
            logMemoryUsage("after conversion")
        } else {
            // Dual variant: create master playlist
            await updateProgress(stage: "Creating master playlist...", progress: 90)
            logMemoryUsage("before master playlist creation")
            
            let masterPlaylistCreated = await createMasterPlaylist(
                masterPlaylistURL: masterPlaylistURL,
                hls720pURL: hls720pURL,
                lowerResURL: lowerResURL,
                actualHighQualityResolution: actualHighQualityResolution,
                actualLowerResResolution: actualLowerResResolution,
                highQualityBitrate: highQualityBitrate,
                lowerResolution: lowerResolution,
                lowerResolutionBitrate: lowerResolutionBitrate,
                singleVariant480p: singleVariant480p
            )
            
            logMemoryUsage("after master playlist creation")
            
            guard masterPlaylistCreated else {
                await MainActor.run {
                    completion(HLSConversionResult(
                        success: false,
                        hlsDirectoryURL: nil,
                        errorMessage: "Failed to create master playlist"
                    ))
                }
                return
            }
        }
        
        await updateProgress(stage: "Conversion completed!", progress: 100)
        
        // Force memory cleanup
        await Task.yield()
        logMemoryUsage("final")
        
        await MainActor.run {
            completion(HLSConversionResult(
                success: resultLowerRes,
                hlsDirectoryURL: resultLowerRes ? hlsDirectory : nil,
                errorMessage: resultLowerRes ? nil : "Failed to convert to \(lowerResolution)p HLS"
            ))
        }
    }
    
    private func updateProgress(stage: String, progress: Int) async {
        await MainActor.run {
            self.progressCallback?(ConversionProgress(
                stage: stage,
                progress: progress,
                estimatedTimeRemaining: nil
            ))
        }
    }
    
    private func createMasterPlaylist(
        masterPlaylistURL: URL,
        hls720pURL: URL,
        lowerResURL: URL,
        actualHighQualityResolution: String,
        actualLowerResResolution: String,
        highQualityBitrate: String,
        lowerResolution: Int,
        lowerResolutionBitrate: String,
        singleVariant480p: Bool
    ) async -> Bool {
        // Convert bitrate strings (e.g., "3000k") to bandwidth integers (e.g., 3000000)
        let bandwidthHighQuality = Int(highQualityBitrate.replacingOccurrences(of: "k", with: "")) ?? 2000
        let bandwidthLowerRes = Int(lowerResolutionBitrate.replacingOccurrences(of: "k", with: "")) ?? 1000
        
        let masterPlaylistContent: String
        if singleVariant480p {
            // Single variant: 480p only
            masterPlaylistContent = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidthLowerRes * 1000),RESOLUTION=\(actualLowerResResolution)
            \(lowerResolution)p/playlist.m3u8
            """
        } else {
            // Dual variant: high-quality + 480p
            // Note: Directory name is "720p" for compatibility, but actual resolution may be lower
            masterPlaylistContent = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidthHighQuality * 1000),RESOLUTION=\(actualHighQualityResolution)
            720p/playlist.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidthLowerRes * 1000),RESOLUTION=\(actualLowerResResolution)
            \(lowerResolution)p/playlist.m3u8
            """
        }
        
        do {
            try masterPlaylistContent.write(to: masterPlaylistURL, atomically: true, encoding: .utf8)
            print("DEBUG: [VIDEO CONVERSION] Master playlist created at: \(masterPlaylistURL.path)")
            print("DEBUG: [MASTER PLAYLIST] Content: \(masterPlaylistContent)")
            return true
        } catch {
            print("DEBUG: [VIDEO CONVERSION] Failed to create master playlist: \(error)")
            return false
        }
    }
    
    private func calculateActualResolution(targetResolution: Int, aspectRatio: Float?) -> String {
        guard let aspectRatio = aspectRatio else {
            // Default to landscape if no aspect ratio
            if targetResolution == 720 {
                return "1280x720"
            } else if targetResolution == 480 {
                return "854x480"
            } else if targetResolution == 360 {
                return "640x360"
            } else {
                return "\(targetResolution * 16 / 9)x\(targetResolution)"
            }
        }

        // Validate aspect ratio is finite and reasonable
        guard aspectRatio.isFinite, aspectRatio > 0, aspectRatio < 100 else {
            print("DEBUG: [VIDEO CONVERSION] Invalid aspect ratio: \(aspectRatio), using default resolution")
            return "\(targetResolution * 16 / 9)x\(targetResolution)"
        }

        if aspectRatio < 1.0 {
            // Portrait: scale to target width, calculate height
            let width = targetResolution
            let heightFloat = Float(targetResolution) / aspectRatio

            // Ensure height calculation is valid
            guard heightFloat.isFinite, heightFloat > 0, heightFloat < 10000 else {
                print("DEBUG: [VIDEO CONVERSION] Invalid height calculation: \(heightFloat), using default")
                return "\(width)x\(targetResolution)"
            }

            let height = Int(heightFloat)
            // Ensure height is even and reasonable
            let evenHeight = height % 2 == 0 ? height : height - 1
            let clampedHeight = max(1, min(evenHeight, targetResolution * 4)) // Reasonable bounds
            return "\(width)x\(clampedHeight)"
        } else {
            // Landscape: scale to target height, calculate width
            let height = targetResolution
            let widthFloat = Float(targetResolution) * aspectRatio

            // Ensure width calculation is valid
            guard widthFloat.isFinite, widthFloat > 0, widthFloat < 10000 else {
                print("DEBUG: [VIDEO CONVERSION] Invalid width calculation: \(widthFloat), using default")
                return "\(targetResolution * 16 / 9)x\(height)"
            }

            let width = Int(widthFloat)
            // Ensure width is even and reasonable
            let evenWidth = width % 2 == 0 ? width : width - 1
            let clampedWidth = max(1, min(evenWidth, targetResolution * 4)) // Reasonable bounds
            return "\(clampedWidth)x\(height)"
        }
    }
    
    // MARK: - Async HLS Conversion
    
    private func convertToHLSAsync(
        inputURL: URL,
        outputURL: URL,
        resolution: String,
        bitrate: String,
        aspectRatio: Float?,
        cachedVideoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?,
        isNormalized: Bool
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            convertToHLS(
                inputURL: inputURL,
                outputURL: outputURL,
                resolution: resolution,
                bitrate: bitrate,
                aspectRatio: aspectRatio,
                cachedVideoInfo: cachedVideoInfo,
                isNormalized: isNormalized
            ) { success in
                continuation.resume(returning: success)
            }
        }
    }
    
    // MARK: - Convert to HLS with specific resolution
    
    /// Legacy function - kept for reference, no longer used in main conversion logic
    /// Previously used COPY if source resolution is <= target
    private func shouldUseCopyPreset(
        inputURL: URL,
        aspectRatio: Float?,
        targetResolution: Int,
        cachedVideoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?
    ) async -> Bool {
        // Use cached video info if available, otherwise fetch it
        let videoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?
        if let cached = cachedVideoInfo {
            videoInfo = cached
        } else {
            videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
        }
        
        if let videoInfo = videoInfo {
            let displayWidth = videoInfo.displayWidth
            let displayHeight = videoInfo.displayHeight

            print("DEBUG: [VIDEO CONVERSION] Original video dimensions: \(displayWidth)x\(displayHeight)")

            // Determine the larger dimension based on orientation
            let maxDimension: Int
            if let aspectRatio = aspectRatio {
                if aspectRatio < 1.0 {
                    // Portrait: check height (y-dimension)
                    maxDimension = displayHeight
                } else {
                    // Landscape: check width (x-dimension)
                    maxDimension = displayWidth
                }
            } else {
                // Fallback: use the larger dimension
                maxDimension = max(displayWidth, displayHeight)
            }

            // Only use COPY if source is <= target (never upscale)
            let shouldUseCopy = maxDimension <= targetResolution
            print("DEBUG: [VIDEO CONVERSION] Max dimension: \(maxDimension), target: \(targetResolution), should use COPY preset: \(shouldUseCopy)")
            return shouldUseCopy
        }

        // Fallback: if we can't get video info, don't use copy
        print("DEBUG: [VIDEO CONVERSION] Could not get video info, using libx264")
        return false
    }
    
    private func convertToHLS(
        inputURL: URL,
        outputURL: URL,
        resolution: String,
        bitrate: String,
        aspectRatio: Float?,
        cachedVideoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?,
        isNormalized: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            let targetResolution = Int(resolution) ?? 720
            
            // Determine if COPY can be used: normalized videos that are exactly 720p targeting 720p
            let shouldUseCopy = isNormalized && targetResolution == 720 && {
                if let videoInfo = cachedVideoInfo {
                    let maxDimension = max(videoInfo.displayWidth, videoInfo.displayHeight)
                    return maxDimension == 720
                }
                return false
            }()

            if shouldUseCopy {
                print("DEBUG: [VIDEO CONVERSION] Using COPY codec for normalized 720p video: \(resolution)")

                // COPY codec - no re-encoding needed for already normalized 720p video
                let copyCommand = buildCopyCommand(
                    inputURL: inputURL,
                    outputURL: outputURL
                )

                await MainActor.run {
                    self.executeFFmpegCommand(command: copyCommand, outputURL: outputURL, resolution: resolution, completion: completion)
                }
            } else {
                // Use libx264 for all other cases (compatibility and proper normalization)
                print("DEBUG: [VIDEO CONVERSION] Using libx264 codec for resolution: \(resolution) (compatibility and normalization)")

                // Determine scaling based on orientation and source resolution
                // Never upscale - if source resolution is lower than target, keep original
                let scaleFilter: String
                if let videoInfo = cachedVideoInfo {
                    let displayWidth = videoInfo.displayWidth
                    let displayHeight = videoInfo.displayHeight

                    // Calculate source video resolution (height for landscape, width for portrait)
                    let sourceResolution: Int
                    if let aspectRatio = aspectRatio {
                        if aspectRatio < 1.0 {
                            // Portrait: resolution is width
                            sourceResolution = displayWidth
                        } else {
                            // Landscape: resolution is height
                            sourceResolution = displayHeight
                        }
                    } else {
                        // Fallback: use height
                        sourceResolution = displayHeight
                    }

                    // If source resolution is lower than target, don't scale (keep original)
                    if sourceResolution < targetResolution {
                        print("DEBUG: [VIDEO CONVERSION] Source resolution (\(displayWidth)x\(displayHeight), \(sourceResolution)p) is lower than target (\(targetResolution)p), keeping original resolution")
                        scaleFilter = ""  // No scaling - will keep original dimensions
                    } else {
                        // Scale down to target resolution
                        if let aspectRatio = aspectRatio {
                            if aspectRatio < 1.0 {
                                // Portrait: scale to target width
                                scaleFilter = "scale=\(resolution):-2"
                            } else {
                                // Landscape: scale to target height
                                scaleFilter = "scale=-2:\(resolution)"
                            }
                        } else {
                            scaleFilter = "scale=-2:\(resolution)"
                        }
                        print("DEBUG: [VIDEO CONVERSION] Scaling \(displayWidth)x\(displayHeight) (\(sourceResolution)p) down to \(targetResolution)p")
                    }
                } else {
                    // Fallback: use standard scaling
                    if let aspectRatio = aspectRatio {
                        if aspectRatio < 1.0 {
                            scaleFilter = "scale=\(resolution):-2"
                        } else {
                            scaleFilter = "scale=-2:\(resolution)"
                        }
                    } else {
                        scaleFilter = "scale=-2:\(resolution)"
                    }
                }

                let libx264Command = buildLibx264Command(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    resolution: resolution,
                    bitrate: bitrate,
                    scaleFilter: scaleFilter
                )

                await MainActor.run {
                    self.executeFFmpegCommand(command: libx264Command, outputURL: outputURL, resolution: resolution, completion: completion)
                }
            }
        }
    }
    
    /// Builds FFmpeg command for libx264 codec - standard HLS configuration
    private func buildLibx264Command(
        inputURL: URL,
        outputURL: URL,
        resolution: String,
        bitrate: String,
        scaleFilter: String
    ) -> String {
        // Build video filter - only include scale if needed
        var videoFilter = ""
        if !scaleFilter.isEmpty {
            videoFilter = "-vf \"\(scaleFilter)\""
        }
        
        // OPTIMIZATION: Reduce memory usage during encoding
        // - Use "veryfast" preset (already set) for speed and lower memory
        // - Limit threads to 4 instead of auto (0) to reduce memory footprint
        // - Use smaller bufsize to reduce memory buffer requirements
        let threadCount = min(4, ProcessInfo.processInfo.activeProcessorCount)
        let bufferSize = Int(bitrate.replacingOccurrences(of: "k", with: "")) ?? 2000
        let optimizedBufferSize = "\(bufferSize / 2)k" // Half the bitrate for buffer
        
        // Build command as a single line to avoid multiline string issues
        var commandParts: [String] = [
            "-i \"\(inputURL.path)\"",
            "-c:v libx264",
            "-profile:v main",
            "-level 4.0",
            "-pix_fmt yuv420p",
            "-c:a aac",
            "-ar 44100",
            "-b:v \(bitrate)",
            "-maxrate \(bitrate)",
            "-bufsize \(optimizedBufferSize)", // OPTIMIZED: Smaller buffer
            "-b:a 128k",
            "-preset veryfast",
            "-g 48",
            "-keyint_min 48",
            "-sc_threshold 0",
            "-threads \(threadCount)" // OPTIMIZED: Limited threads
        ]
        
        if !videoFilter.isEmpty {
            commandParts.append(videoFilter)
        }
        
        commandParts.append(contentsOf: [
            "-f hls",
            "-hls_time 10",
            "-hls_list_size 0",
            "-hls_segment_filename \"\(outputURL.deletingLastPathComponent().path)/segment%03d.ts\"",
            "-hls_playlist_type vod",
            "-start_number 0",
            "\"\(outputURL.path)\""
        ])
        
        return commandParts.joined(separator: " ")
    }

    /// Builds FFmpeg command for COPY codec - fast HLS conversion for already normalized videos
    private func buildCopyCommand(
        inputURL: URL,
        outputURL: URL
    ) -> String {
        // Build command for COPY codec - no re-encoding, just remux to HLS
        let commandParts: [String] = [
            "-i \"\(inputURL.path)\"",
            "-c:v copy",
            "-c:a aac",
            "-b:a 128k",
            "-f hls",
            "-hls_time 10",
            "-hls_list_size 0",
            "-hls_segment_filename \"\(outputURL.deletingLastPathComponent().path)/segment%03d.ts\"",
            "-hls_playlist_type vod",
            "-start_number 0",
            "\"\(outputURL.path)\""
        ]

        return commandParts.joined(separator: " ")
    }

    private func executeFFmpegCommand(
        command: String,
        outputURL: URL,
        resolution: String,
        completion: @escaping (Bool) -> Void
    ) {
        FFmpegKit.executeAsync(command) { session in
            guard let session = session else {
                print("DEBUG: [VIDEO CONVERSION] Failed to create FFmpeg session")
                completion(false)
                return
            }
            
            let returnCode = session.getReturnCode()
            let logs = session.getLogs()
            
            print("DEBUG: [VIDEO CONVERSION] Conversion completed with return code: \(String(describing: returnCode))")
            
            // Log FFmpeg output for debugging
            if let logs = logs {
                for log in logs {
                    if let logObj = log as? Log, let message = logObj.getMessage() {
                        print("DEBUG: [FFMPEG LOG] \(message)")
                    }
                }
            }
            
            let success = ReturnCode.isSuccess(returnCode)
            
            if success {
                // Verify output file exists
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                    print("DEBUG: [VIDEO CONVERSION] Successfully converted to \(resolution)")
                    print("DEBUG: [VIDEO CONVERSION] Output file exists: \(outputURL.lastPathComponent), size: \(fileSize) bytes")
                    completion(true)
                } else {
                    print("DEBUG: [VIDEO CONVERSION] Output file does not exist: \(outputURL.path)")
                    completion(false)
                }
            } else {
                print("DEBUG: [VIDEO CONVERSION] Conversion failed for \(resolution)")
                completion(false)
            }
        }
    }
    
    func getVideoInfo(
        inputURL: URL,
        completion: @escaping (VideoInfo?) -> Void
    ) {
        let command = "-i \"\(inputURL.path)\" -f null -"
        
        FFmpegKit.executeAsync(command) { session in
            guard let session = session else {
                completion(nil)
                return
            }
            
            let logs = session.getLogs()
            let videoInfo = self.parseVideoInfo(from: logs?.compactMap { $0 as? Log } ?? [])
            completion(videoInfo)
        }
    }
    
    private func parseVideoInfo(from logs: [Log]) -> VideoInfo? {
        var width: Int = 0
        var height: Int = 0
        var duration: Double?
        
        for log in logs {
            guard let message = log.getMessage() else { continue }
            
            // Parse resolution from stream info
            if message.contains("Stream #0:0") && message.contains("Video:") {
                let components = message.components(separatedBy: ",")
                for component in components {
                    let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("x") && trimmed.allSatisfy({ $0.isNumber || $0 == "x" }) {
                        let dimensions = trimmed.components(separatedBy: "x")
                        if dimensions.count == 2,
                           let w = Int(dimensions[0]),
                           let h = Int(dimensions[1]) {
                            width = w
                            height = h
                        }
                    }
                }
            }
            
            // Parse duration
            if message.contains("Duration:") {
                let components = message.components(separatedBy: " ")
                for component in components {
                    if component.contains(":") && component.contains(".") {
                        let timeComponents = component.components(separatedBy: ":")
                        if timeComponents.count == 3 {
                            let seconds = timeComponents[2].components(separatedBy: ".")[0]
                            if let secs = Double(seconds) {
                                let minutes = Double(timeComponents[1]) ?? 0
                                let hours = Double(timeComponents[0]) ?? 0
                                duration = hours * 3600 + minutes * 60 + secs
                            }
                        }
                    }
                }
            }
        }
        
        return VideoInfo(width: width, height: height, duration: duration)
    }
}
