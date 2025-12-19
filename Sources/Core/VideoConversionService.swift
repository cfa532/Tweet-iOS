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
        progressCallback: @escaping (ConversionProgress) -> Void,
        completion: @escaping (HLSConversionResult) -> Void
    ) {
        print("DEBUG: [VIDEO CONVERSION] Starting background conversion for \(inputURL.lastPathComponent)")
        
        // Cancel any existing conversion
        cancelCurrentConversion()
        
        // Store progress callback
        self.progressCallback = progressCallback

        // Standard HLS conversion configuration
        // Always use 720p (1500kb) + 480p (1000kb) regardless of file size
        let resolution720pBitrate = "1500k"
        let lowerResolution = 480
        let lowerResolutionBitrate = "1000k"
        
        // Create HLS directory structure
        let hlsDirectory = outputDirectory.appendingPathComponent("hls")
        let hls720pDir = hlsDirectory.appendingPathComponent("720p")
        let lowerResDir = hlsDirectory.appendingPathComponent("\(lowerResolution)p")
        
        // Create directories
        try? FileManager.default.createDirectory(at: hls720pDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: lowerResDir, withIntermediateDirectories: true)
        
        // Create output URLs
        let hls720pURL = hls720pDir.appendingPathComponent("playlist.m3u8")
        let lowerResURL = lowerResDir.appendingPathComponent("playlist.m3u8")
        let masterPlaylistURL = hlsDirectory.appendingPathComponent("master.m3u8")
        
        // Log initial memory usage
        logMemoryUsage("before conversion")
        
        // Run conversion in background task
        currentConversion = Task.detached { [weak self] in
            await self?.performConversion(
                inputURL: inputURL,
                hls720pURL: hls720pURL,
                lowerResURL: lowerResURL,
                masterPlaylistURL: masterPlaylistURL,
                hlsDirectory: hlsDirectory,
                aspectRatio: aspectRatio,
                resolution720pBitrate: resolution720pBitrate,
                lowerResolution: lowerResolution,
                lowerResolutionBitrate: lowerResolutionBitrate,
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
        resolution720pBitrate: String,
        lowerResolution: Int,
        lowerResolutionBitrate: String,
        completion: @escaping (HLSConversionResult) -> Void
    ) async {
        // Calculate actual resolutions based on aspect ratio
        let actual720pResolution = calculateActualResolution(targetResolution: 720, aspectRatio: aspectRatio)
        let actualLowerResResolution = calculateActualResolution(targetResolution: lowerResolution, aspectRatio: aspectRatio)
        
        print("DEBUG: [MASTER PLAYLIST] Calculated 720p resolution: \(actual720pResolution)")
        print("DEBUG: [MASTER PLAYLIST] Calculated \(lowerResolution)p resolution: \(actualLowerResResolution)")
        
        // Get video info once to avoid redundant FFmpeg calls
        let videoInfo = await HLSVideoProcessor.shared.getVideoInfoWithFFmpeg(filePath: inputURL.path)
        
        // Step 1: Convert to 720p HLS (50% of progress)
        await updateProgress(stage: "Converting to 720p HLS...", progress: 10)
        logMemoryUsage("before 720p conversion")
        
        let result720p = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: hls720pURL,
            resolution: "720",
            bitrate: resolution720pBitrate,
            aspectRatio: aspectRatio,
            cachedVideoInfo: videoInfo
        )
        
        logMemoryUsage("after 720p conversion")
        
        // Force memory cleanup between conversions
        forceMemoryCleanup()
        
        guard result720p else {
            await MainActor.run {
                completion(HLSConversionResult(
                    success: false,
                    hlsDirectoryURL: nil,
                    errorMessage: "Failed to convert to 720p HLS"
                ))
            }
            return
        }
        
        // Step 2: Convert to lower resolution HLS (remaining 50% of progress)
        await updateProgress(stage: "Converting to \(lowerResolution)p HLS...", progress: 60)
        logMemoryUsage("before \(lowerResolution)p conversion")
        
        let resultLowerRes = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: lowerResURL,
            resolution: "\(lowerResolution)",
            bitrate: lowerResolutionBitrate,
            aspectRatio: aspectRatio,
            cachedVideoInfo: videoInfo
        )
        
        logMemoryUsage("after \(lowerResolution)p conversion")
        
        // Force memory cleanup after lower resolution conversion
        forceMemoryCleanup()
        
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
        
        // Step 3: Create master playlist
        await updateProgress(stage: "Creating master playlist...", progress: 90)
        logMemoryUsage("before master playlist creation")
        
        let masterPlaylistCreated = await createMasterPlaylist(
            masterPlaylistURL: masterPlaylistURL,
            hls720pURL: hls720pURL,
            lowerResURL: lowerResURL,
            actual720pResolution: actual720pResolution,
            actualLowerResResolution: actualLowerResResolution,
            resolution720pBitrate: resolution720pBitrate,
            lowerResolution: lowerResolution,
            lowerResolutionBitrate: lowerResolutionBitrate
        )
        
        logMemoryUsage("after master playlist creation")
        
        await updateProgress(stage: "Conversion completed!", progress: 100)
        
        // Force memory cleanup
        await Task.yield()
        logMemoryUsage("final")
        
        await MainActor.run {
            completion(HLSConversionResult(
                success: resultLowerRes && masterPlaylistCreated,
                hlsDirectoryURL: resultLowerRes && masterPlaylistCreated ? hlsDirectory : nil,
                errorMessage: resultLowerRes ? (masterPlaylistCreated ? nil : "Failed to create master playlist") : "Failed to convert to \(lowerResolution)p HLS"
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
        actual720pResolution: String,
        actualLowerResResolution: String,
        resolution720pBitrate: String,
        lowerResolution: Int,
        lowerResolutionBitrate: String
    ) async -> Bool {
        // Convert bitrate strings (e.g., "3000k") to bandwidth integers (e.g., 3000000)
        let bandwidth720p = Int(resolution720pBitrate.replacingOccurrences(of: "k", with: "")) ?? 2000
        let bandwidthLowerRes = Int(lowerResolutionBitrate.replacingOccurrences(of: "k", with: "")) ?? 1000
        
        let masterPlaylistContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth720p * 1000),RESOLUTION=\(actual720pResolution)
        720p/playlist.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidthLowerRes * 1000),RESOLUTION=\(actualLowerResResolution)
        \(lowerResolution)p/playlist.m3u8
        """
        
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
        cachedVideoInfo: (width: Int, height: Int, displayWidth: Int, displayHeight: Int, rotation: Int)?
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            convertToHLS(
                inputURL: inputURL,
                outputURL: outputURL,
                resolution: resolution,
                bitrate: bitrate,
                aspectRatio: aspectRatio,
                cachedVideoInfo: cachedVideoInfo
            ) { success in
                continuation.resume(returning: success)
            }
        }
    }
    
    // MARK: - Convert to HLS with specific resolution
    
    /// Determines if COPY codec should be used based on video resolution
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
            videoInfo = await HLSVideoProcessor.shared.getVideoInfoWithFFmpeg(filePath: inputURL.path)
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
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            let targetResolution = Int(resolution) ?? 720
            let shouldUseCopy = await shouldUseCopyPreset(
                inputURL: inputURL,
                aspectRatio: aspectRatio,
                targetResolution: targetResolution,
                cachedVideoInfo: cachedVideoInfo
            )
            
            // Use the same logic as the server: determine scaling based on orientation
            let scaleFilter: String
            if let aspectRatio = aspectRatio {
                // If aspect ratio < 1.0, it's portrait (height > width)
                if aspectRatio < 1.0 {
                    // Portrait: scale to target width, calculate height
                    // This will maintain portrait orientation: 720x1280 instead of 394x720
                    scaleFilter = "scale=\(resolution):-2"
                } else {
                    // Landscape: scale to target height, calculate width
                    // This will maintain landscape orientation: 1280x720 instead of 720x405
                    scaleFilter = "scale=-2:\(resolution)"
                }
            } else {
                // Fallback to height-based scaling
                scaleFilter = "scale=-2:\(resolution)"
            }

            // Use COPY codec for videos that are already at target resolution
            if shouldUseCopy {
                print("DEBUG: [VIDEO CONVERSION] Using COPY codec for resolution: \(resolution)")
                
                // COPY codec - no re-encoding, just remux to HLS
                let copyCommand = """
                    -i "\(inputURL.path)" \
                    -c:v copy \
                    -c:a aac \
                    -b:a 128k \
                    -f hls \
                    -hls_time 4 \
                    -hls_list_size 0 \
                    -hls_segment_filename "\(outputURL.deletingLastPathComponent().path)/segment%03d.ts" \
                    -hls_playlist_type vod \
                    -start_number 0 \
                    "\(outputURL.path)"
                    """
                
                await MainActor.run {
                    self.executeFFmpegCommand(command: copyCommand, outputURL: outputURL, resolution: resolution, completion: completion)
                }
            } else {
                // Use libx264 for videos that need scaling
                let libx264Command = buildLibx264Command(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    resolution: resolution,
                    bitrate: bitrate,
                    scaleFilter: scaleFilter
                )
                
                print("DEBUG: [VIDEO CONVERSION] Using libx264 codec for resolution: \(resolution)")
                
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
        return """
            -i "\(inputURL.path)" \
            -c:v libx264 \
            -profile:v main \
            -level 4.0 \
            -pix_fmt yuv420p \
            -c:a aac \
            -ar 44100 \
            -vf "\(scaleFilter)" \
            -b:v \(bitrate) \
            -b:a 128k \
            -preset veryfast \
            -g 48 \
            -keyint_min 48 \
            -sc_threshold 0 \
            -threads 0 \
            -f hls \
            -hls_time 4 \
            -hls_list_size 0 \
            -hls_segment_filename "\(outputURL.deletingLastPathComponent().path)/segment%03d.ts" \
            -hls_playlist_type vod \
            -start_number 0 \
            "\(outputURL.path)"
            """
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
