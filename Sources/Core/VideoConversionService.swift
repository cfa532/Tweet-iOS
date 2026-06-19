import Foundation
import UIKit
import Darwin
import ObjectiveC.runtime

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
    
    // Bitrate constants
    static let reference720pBitrate = 2500.0  // Base bitrate for 720p video (in kbps)
    static let minBitrate = 600  // Minimum bitrate in kbps for lower-resolution variants
    
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

        print("📹 [HLS CONVERSION] Configuration:")
        print("  - Source resolution: \(sourceVideoResolution)p")
        print("  - Mode: \(singleVariant480p ? "Single variant (480p only)" : "Dual variant (high-quality + 480p)")")
        print("  - Is normalized: \(isNormalized)")
        print("  - Input file: \(inputURL.lastPathComponent)")
        print("  - File size: \(String(format: "%.1f", Double(fileSizeBytes) / 1024 / 1024))MB")
        
        // HLS conversion configuration:
        // Single variant: 480p (proportional bitrate) only
        // Dual variant: high-quality (proportional bitrate) + 480p (proportional bitrate)
        // High-quality variant uses actual source resolution (capped at 720p)
        let lowerResolution = 480
        let highQualityResolution = min(sourceVideoResolution, 720) // Cap at 720p
        
        print("📹 [HLS CONVERSION] Target resolutions: high-quality=\(highQualityResolution)p, lower=\(lowerResolution)p")
        
        // Create HLS directory structure
        // Single variant: master.m3u8 and playlist.m3u8 at root (hls/master.m3u8, hls/playlist.m3u8)
        // Dual variant: master.m3u8 at root with subdirectories (hls/master.m3u8, hls/720p/, hls/480p/)
        let hlsDirectory = outputDirectory.appendingPathComponent("hls")
        let hls720pDir = hlsDirectory.appendingPathComponent("720p")
        let lowerResDir = hlsDirectory.appendingPathComponent("\(lowerResolution)p")
        
        // Create directories based on variant mode
        print("📹 [HLS CONVERSION] Creating directory structure at: \(hlsDirectory.path)")
        if singleVariant480p {
            // Single variant: no subdirectories needed, playlist goes at root
            try? FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
            print("  ✓ Created single variant directory")
        } else {
            // Dual variant: create subdirectories for variants
            try? FileManager.default.createDirectory(at: hls720pDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: lowerResDir, withIntermediateDirectories: true)
            print("  ✓ Created dual variant directories (720p/ and 480p/)")
        }
        
        // Create output URLs
        // For single variant: master.m3u8 and playlist.m3u8 at root
        // For dual variant: playlists in subdirectories + master.m3u8 at root
        let hls720pURL = hls720pDir.appendingPathComponent("playlist.m3u8")
        let lowerResURL = singleVariant480p ? hlsDirectory.appendingPathComponent("playlist.m3u8") : lowerResDir.appendingPathComponent("playlist.m3u8")
        let masterPlaylistURL = hlsDirectory.appendingPathComponent("master.m3u8")
        
        // Log initial memory usage
        logMemoryUsage("before conversion")
        
        // OPTIMIZATION: Use lower priority to reduce CPU/memory contention
        // High priority was causing excessive memory pressure and breaking video players
        // Using .userInitiated instead of .high reduces resource competition
        currentConversion = Task(priority: .userInitiated) { [weak self] in
            // Get source video info for resolution detection and pixel-based bitrate calculation
            let videoInfo = await HLSVideoProcessor.shared.getVideoInfo(filePath: inputURL.path)
            
            // Reference: 720p (1280×720) = 921,600 pixels = reference720pBitrate
            let REFERENCE_720P_PIXELS = 921600
            
            // Calculate target bitrates based on actual pixel count
            // High-quality variant: 
            //   - >720p (downscaled to 720p): reference720pBitrate
            //   - =720p: reference720pBitrate
            //   - <720p: pixel-based proportional bitrate (min minBitrate)
            // Lower variant: pixel-based proportional bitrate (min minBitrate)
            let targetHighQualityKbps: Int
            if sourceVideoResolution > 720 {
                // Resolution >720p: normalize to 720p at the shared reference bitrate
                targetHighQualityKbps = Int(Self.reference720pBitrate)
            } else if sourceVideoResolution == 720 {
                // Resolution =720p: use reference bitrate
                targetHighQualityKbps = Int(Self.reference720pBitrate)
            } else {
                // Resolution <720p: pixel-based proportional bitrate (min minBitrate to avoid inflating low-bitrate videos)
                if let info = videoInfo {
                    let pixelCount = info.displayWidth * info.displayHeight
                    let calculatedBitrate = Int((Double(pixelCount) / Double(REFERENCE_720P_PIXELS)) * Self.reference720pBitrate)
                    targetHighQualityKbps = max(Self.minBitrate, calculatedBitrate)
                    print("📊 High-quality variant: \(info.displayWidth)×\(info.displayHeight) (\(pixelCount) pixels) = \(calculatedBitrate)k → \(targetHighQualityKbps)k (with min)")
                } else {
                    // Fallback to linear if video info unavailable
                    targetHighQualityKbps = max(Self.minBitrate, Int(Self.reference720pBitrate * Double(highQualityResolution) / 720.0))
                }
            }
            
            // Lower variant bitrate: pixel-based proportional (min minBitrate to avoid inflating low-bitrate videos)
            // Calculate 480p equivalent pixels based on aspect ratio
            let targetLowerKbps: Int
            if let info = videoInfo {
                let aspectRatio = Float(info.displayWidth) / Float(info.displayHeight)
                let lowerWidth: Int
                let lowerHeight: Int
                
                if aspectRatio < 1.0 {
                    // Portrait: scale to 480 width
                    lowerWidth = min(info.displayWidth, lowerResolution)
                    lowerHeight = Int(Float(lowerWidth) / aspectRatio)
                } else {
                    // Landscape: scale to 480 height
                    lowerHeight = min(info.displayHeight, lowerResolution)
                    lowerWidth = Int(Float(lowerHeight) * aspectRatio)
                }
                
                let lowerPixelCount = lowerWidth * lowerHeight
                let calculatedBitrate = Int((Double(lowerPixelCount) / Double(REFERENCE_720P_PIXELS)) * Self.reference720pBitrate)
                targetLowerKbps = max(Self.minBitrate, calculatedBitrate)
                print("📊 Lower variant: \(lowerWidth)×\(lowerHeight) (\(lowerPixelCount) pixels) = \(calculatedBitrate)k → \(targetLowerKbps)k (with min)")
            } else {
                // Fallback to linear if video info unavailable
                targetLowerKbps = max(Self.minBitrate, Int(Self.reference720pBitrate * Double(lowerResolution) / 720.0))
            }
            
            let highQualityBitrate = "\(targetHighQualityKbps)k"
            let lowerResolutionBitrate = "\(targetLowerKbps)k"
            
            print("📊 [HLS CONVERSION] Calculated bitrates:")
            if !singleVariant480p {
                print("  - High-quality (\(highQualityResolution)p): \(highQualityBitrate)")
                print("  - Lower (480p): \(lowerResolutionBitrate)")
            } else {
                print("  - Single variant (480p): \(lowerResolutionBitrate)")
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
            print("📹 [HLS CONVERSION] Step 1/3: Converting high-quality variant (\(highQualityResolution)p)")
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
        let stepNumber = singleVariant480p ? "1/2" : "2/3"
        print("📹 [HLS CONVERSION] Step \(stepNumber): Converting lower variant (480p)")
        await updateProgress(stage: "Converting to \(lowerResolution)p HLS...", progress: progressStart)
        logMemoryUsage("before \(lowerResolution)p conversion")
        
        let resultLowerRes = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: lowerResURL,
            resolution: "\(lowerResolution)",
            bitrate: lowerResolutionBitrate,
            aspectRatio: aspectRatio,
            cachedVideoInfo: videoInfo,
            isNormalized: isNormalized  // Pass through normalization flag to enable COPY codec for ≤480p videos
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
        
        // Step 3: Create master playlist (both single and dual variant)
        let finalStepNumber = singleVariant480p ? "2/2" : "3/3"
        print("📹 [HLS CONVERSION] Step \(finalStepNumber): Creating master playlist")
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
            // Single variant: master.m3u8 points to playlist.m3u8 at root
            masterPlaylistContent = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidthLowerRes * 1000),RESOLUTION=\(actualLowerResResolution)
            playlist.m3u8
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
        print("DEBUG: [VIDEO CONVERSION] Could not get video info, using VideoToolbox H.264")
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
            
            // Determine if COPY can be used for normalized videos
            // Matches Node.js server logic:
            // - 720p variant: use COPY if normalized resolution is between 480p and 720p (avoids upscaling)
            // - 480p variant: use COPY if normalized resolution is ≤480p (avoids upscaling)
            let shouldUseCopy = isNormalized && {
                if let videoInfo = cachedVideoInfo {
                    // Calculate source resolution based on orientation
                    // For landscape: resolution is height, for portrait: resolution is width
                    let sourceResolution: Int
                    if let aspectRatio = aspectRatio {
                        if aspectRatio < 1.0 {
                            // Portrait: resolution is width
                            sourceResolution = videoInfo.displayWidth
                        } else {
                            // Landscape: resolution is height
                            sourceResolution = videoInfo.displayHeight
                        }
                    } else {
                        // Fallback: use height for landscape
                        sourceResolution = videoInfo.displayHeight
                    }
                    
                    // Use COPY for 720p variant if normalized resolution is between 480p and 720p
                    // This avoids upscaling (e.g., 576p content stays 576p but labeled as 720p)
                    if targetResolution == 720 && sourceResolution > 480 && sourceResolution <= 720 {
                        if sourceResolution < 720 {
                            print("✅ [VIDEO CONVERSION] Using COPY for 720p variant (actual content: \(sourceResolution)p, labeled as 720p, no upscaling)")
                        } else {
                            print("✅ [VIDEO CONVERSION] Using COPY for 720p variant (normalized resolution \(sourceResolution)p matches variant)")
                        }
                        return true
                    }
                    
                    // Use COPY for 480p variant if normalized resolution is ≤480p
                    // This avoids upscaling (e.g., 360p content stays 360p but labeled as 480p)
                    if targetResolution == 480 && sourceResolution <= 480 {
                        if sourceResolution < 480 {
                            print("✅ [VIDEO CONVERSION] Using COPY for 480p variant (actual content: \(sourceResolution)p, labeled as 480p, no upscaling)")
                        } else {
                            print("✅ [VIDEO CONVERSION] Using COPY for 480p variant (normalized resolution \(sourceResolution)p matches variant)")
                        }
                        return true
                    }
                    
                    return false
                }
                return false
            }()

            if shouldUseCopy {
                print("========== \(targetResolution)p VARIANT: COPY CODEC (No Re-encoding) ==========")
                print("  Video already normalized")
                print("  Target: \(targetResolution)p (no scaling needed)")
                print("  Method: COPY codec - preserves standardized quality")
                print("  No second normalization - just segmenting for HLS")
                print("==============================================================")
                
                // COPY codec - no re-encoding needed for already normalized video
                let copyCommand = buildCopyCommand(
                    inputURL: inputURL,
                    outputURL: outputURL
                )

                await MainActor.run {
                    self.executeFFmpegCommand(command: copyCommand, outputURL: outputURL, resolution: resolution, completion: completion)
                }
            } else {
                print("========== \(targetResolution)p VARIANT: RE-ENCODING (VideoToolbox H.264) ==========")
                print("  Method: h264_videotoolbox re-encoding")
                print("  Reason: Scaling or format conversion needed")
                print("==========================================================")
                
                // Use Apple's hardware H.264 encoder for all other cases.
                print("DEBUG: [VIDEO CONVERSION] Using h264_videotoolbox codec for resolution: \(resolution) (compatibility and normalization)")

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

                let h264Command = buildVideoToolboxH264Command(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    resolution: resolution,
                    bitrate: bitrate,
                    scaleFilter: scaleFilter
                )

                await MainActor.run {
                    self.executeFFmpegCommand(command: h264Command, outputURL: outputURL, resolution: resolution, completion: completion)
                }
            }
        }
    }
    
    /// Builds FFmpeg command for Apple's VideoToolbox H.264 encoder - standard HLS configuration
    private func buildVideoToolboxH264Command(
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
        
        // OPTIMIZATION: Keep encoder buffers small to reduce memory footprint.
        let bufferSize = Int(bitrate.replacingOccurrences(of: "k", with: "")) ?? 2000
        let optimizedBufferSize = "\(bufferSize / 2)k" // Half the bitrate for buffer
        
        // Build command as a single line to avoid multiline string issues
        var commandParts: [String] = [
            "-i \"\(inputURL.path)\"",
            "-c:v h264_videotoolbox",
            "-allow_sw 1",
            "-profile:v main",
            "-level 4.0",
            "-pix_fmt yuv420p",
            "-c:a aac",
            "-ar 44100",
            "-b:v \(bitrate)",
            "-maxrate \(bitrate)",
            "-bufsize \(optimizedBufferSize)", // OPTIMIZED: Smaller buffer
            "-b:a 128k",
            "-g 48"
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
        print("🎬 [FFMPEG] Starting conversion to \(resolution)")
        print("  Full command: \(command)")
        
        DynamicFFmpegKit.shared.executeAsync(command) { session in
            guard let session = session else {
                print("❌ [FFMPEG] Failed to create FFmpeg session for \(resolution)")
                completion(false)
                return
            }
            
            let logs = session.logMessages
            
            print("🎬 [FFMPEG] Conversion to \(resolution) completed with return code: \(session.returnCodeDescription)")
            
            // Log FFmpeg output for debugging (show last 10 log entries, excluding verbose HLS segment messages)
            if logs.count > 0 {
                print("🎬 [FFMPEG] Showing last \(min(10, logs.count)) log entries:")
                let lastLogs = logs.suffix(10)
                for message in lastLogs {
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip verbose HLS segment opening messages
                    if !trimmed.isEmpty && !trimmed.contains("Opening") && !trimmed.contains("for writing") {
                        print("  \(trimmed)")
                    }
                }
            }
            
            let success = session.isSuccess
            
            if success {
                // Verify output file exists
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                    let fileSizeMB = Double(fileSize) / 1024 / 1024
                    print("✅ [FFMPEG] Successfully converted to \(resolution)")
                    print("  - Output: \(outputURL.lastPathComponent)")
                    print("  - Size: \(String(format: "%.2f", fileSizeMB))MB (\(fileSize) bytes)")
                    
                    // Count segments if it's an HLS directory
                    let directory = outputURL.deletingLastPathComponent()
                    if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                        let segmentCount = files.filter { $0.hasSuffix(".ts") }.count
                        if segmentCount > 0 {
                            print("  - Segments: \(segmentCount) .ts files")
                        }
                    }
                    completion(true)
                } else {
                    print("❌ [FFMPEG] Output file does not exist: \(outputURL.path)")
                    completion(false)
                }
            } else {
                print("❌ [FFMPEG] Conversion failed for \(resolution)")
                completion(false)
            }
        }
    }
    
    func getVideoInfo(
        inputURL: URL,
        completion: @escaping (VideoInfo?) -> Void
    ) {
        let command = "-i \"\(inputURL.path)\" -f null -"
        
        DynamicFFmpegKit.shared.executeAsync(command) { session in
            guard let session = session else {
                completion(nil)
                return
            }
            
            let videoInfo = self.parseVideoInfo(from: session.logMessages)
            completion(videoInfo)
        }
    }
    
    private func parseVideoInfo(from logs: [String]) -> VideoInfo? {
        var width: Int = 0
        var height: Int = 0
        var duration: Double?
        
        for message in logs {
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

final class DynamicFFmpegKit {
    static let shared = DynamicFFmpegKit()

    private enum LoaderError: Error, CustomStringConvertible {
        case missingFramework
        case dlopenFailed(String)
        case missingClass(String)
        case missingSelector(String)

        var description: String {
            switch self {
            case .missingFramework:
                return "ffmpegkit.framework was not found in the app bundle"
            case .dlopenFailed(let message):
                return "dlopen failed: \(message)"
            case .missingClass(let name):
                return "FFmpegKit class not found: \(name)"
            case .missingSelector(let name):
                return "FFmpegKit selector not found: \(name)"
            }
        }
    }

    private let lock = NSLock()
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var didConfigureLogLevel = false
    private var activeCompletionBlocks: [UUID: AnyObject] = [:]

    private init() {}

    func executeAsync(_ command: String, completion: @escaping (DynamicFFmpegSession?) -> Void) {
        do {
            let ffmpegClass: AnyClass = try loadFFmpegKitClass()
            let selector = NSSelectorFromString("executeAsync:withCompleteCallback:")
            let implementation = try classImplementation(ffmpegClass, selector: selector)
            typealias ExecuteAsync = @convention(c) (AnyClass, Selector, NSString, AnyObject) -> AnyObject?
            let executeAsync = unsafeBitCast(implementation, to: ExecuteAsync.self)

            let blockId = UUID()
            let block: @convention(block) (AnyObject?) -> Void = { [weak self] rawSession in
                let session = rawSession.map(DynamicFFmpegSession.init(rawSession:))
                completion(session)
                self?.releaseCompletionBlock(blockId)
            }
            let blockObject = unsafeBitCast(block, to: AnyObject.self)
            retainCompletionBlock(blockObject, id: blockId)

            _ = executeAsync(ffmpegClass, selector, command as NSString, blockObject)
        } catch {
            print("ERROR: [DynamicFFmpegKit] \(error)")
            completion(nil)
        }
    }

    private func loadFFmpegKitClass() throws -> AnyClass {
        try loadFrameworkIfNeeded()
        try configureLogLevelIfNeeded()

        guard let ffmpegClass = NSClassFromString("FFmpegKit") else {
            throw LoaderError.missingClass("FFmpegKit")
        }
        return ffmpegClass
    }

    private func loadFrameworkIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }

        if frameworkHandle != nil { return }

        guard let frameworkURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("ffmpegkit.framework")
            .appendingPathComponent("ffmpegkit"),
              FileManager.default.fileExists(atPath: frameworkURL.path) else {
            throw LoaderError.missingFramework
        }

        print("Loading ffmpeg-kit on demand.")
        guard let handle = dlopen(frameworkURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw LoaderError.dlopenFailed(message)
        }
        frameworkHandle = handle
        print("Loaded ffmpeg-kit on demand.")
    }

    private func configureLogLevelIfNeeded() throws {
        lock.lock()
        let needsConfigure = !didConfigureLogLevel
        if needsConfigure {
            didConfigureLogLevel = true
        }
        lock.unlock()

        guard needsConfigure else { return }
        guard let configClass = NSClassFromString("FFmpegKitConfig") else {
            throw LoaderError.missingClass("FFmpegKitConfig")
        }

        let selector = NSSelectorFromString("setLogLevel:")
        let implementation = try classImplementation(configClass, selector: selector)
        typealias SetLogLevel = @convention(c) (AnyClass, Selector, Int32) -> Void
        let setLogLevel = unsafeBitCast(implementation, to: SetLogLevel.self)
        setLogLevel(configClass, selector, 16)
    }

    private func retainCompletionBlock(_ block: AnyObject, id: UUID) {
        lock.lock()
        activeCompletionBlocks[id] = block
        lock.unlock()
    }

    private func releaseCompletionBlock(_ id: UUID) {
        lock.lock()
        activeCompletionBlocks.removeValue(forKey: id)
        lock.unlock()
    }

    fileprivate static func classImplementation(_ cls: AnyClass, selector: Selector) throws -> IMP {
        guard let method = class_getClassMethod(cls, selector) else {
            throw LoaderError.missingSelector(NSStringFromSelector(selector))
        }
        return method_getImplementation(method)
    }

    fileprivate static func instanceImplementation(_ object: AnyObject, selector: Selector) throws -> IMP {
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, selector) else {
            throw LoaderError.missingSelector(NSStringFromSelector(selector))
        }
        return method_getImplementation(method)
    }

    private func classImplementation(_ cls: AnyClass, selector: Selector) throws -> IMP {
        try Self.classImplementation(cls, selector: selector)
    }
}

struct DynamicFFmpegSession {
    private let rawSession: AnyObject

    init(rawSession: AnyObject) {
        self.rawSession = rawSession
    }

    var returnCodeDescription: String {
        guard let returnCode = returnCodeObject else { return "nil" }
        return String(describing: returnCode)
    }

    var isSuccess: Bool {
        guard let returnCode = returnCodeObject else { return false }
        do {
            let selector = NSSelectorFromString("isValueSuccess")
            let implementation = try DynamicFFmpegKit.instanceImplementation(returnCode, selector: selector)
            typealias IsValueSuccess = @convention(c) (AnyObject, Selector) -> Bool
            let isValueSuccess = unsafeBitCast(implementation, to: IsValueSuccess.self)
            return isValueSuccess(returnCode, selector)
        } catch {
            print("ERROR: [DynamicFFmpegKit] \(error)")
            return false
        }
    }

    var logMessages: [String] {
        do {
            let selector = NSSelectorFromString("getLogs")
            let implementation = try DynamicFFmpegKit.instanceImplementation(rawSession, selector: selector)
            typealias GetLogs = @convention(c) (AnyObject, Selector) -> NSArray?
            let getLogs = unsafeBitCast(implementation, to: GetLogs.self)
            guard let logs = getLogs(rawSession, selector) else { return [] }

            return logs.compactMap { log in
                guard let logObject = log as AnyObject? else { return nil }
                let messageSelector = NSSelectorFromString("getMessage")
                guard let messageImplementation = try? DynamicFFmpegKit.instanceImplementation(logObject, selector: messageSelector) else {
                    return nil
                }
                typealias GetMessage = @convention(c) (AnyObject, Selector) -> NSString?
                let getMessage = unsafeBitCast(messageImplementation, to: GetMessage.self)
                return getMessage(logObject, messageSelector) as String?
            }
        } catch {
            print("ERROR: [DynamicFFmpegKit] \(error)")
            return []
        }
    }

    private var returnCodeObject: AnyObject? {
        do {
            let selector = NSSelectorFromString("getReturnCode")
            let implementation = try DynamicFFmpegKit.instanceImplementation(rawSession, selector: selector)
            typealias GetReturnCode = @convention(c) (AnyObject, Selector) -> AnyObject?
            let getReturnCode = unsafeBitCast(implementation, to: GetReturnCode.self)
            return getReturnCode(rawSession, selector)
        } catch {
            print("ERROR: [DynamicFFmpegKit] \(error)")
            return nil
        }
    }
}
