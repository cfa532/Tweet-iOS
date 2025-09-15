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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    private init() {
        // FFmpegKit configuration
    }
    
    func convertVideoToHLS(
        inputURL: URL,
        outputDirectory: URL,
        aspectRatio: Float? = nil,
        progressCallback: @escaping (ConversionProgress) -> Void,
        completion: @escaping (HLSConversionResult) -> Void
    ) {
        print("DEBUG: [VIDEO CONVERSION] Starting background conversion for \(inputURL.lastPathComponent)")
        
        // Cancel any existing conversion
        cancelCurrentConversion()
        
        // Store progress callback
        self.progressCallback = progressCallback
        
        // Start background task
        startBackgroundTask()
        
        // Create HLS directory structure
        let hlsDirectory = outputDirectory.appendingPathComponent("hls")
        let hls720pDir = hlsDirectory.appendingPathComponent("720p")
        let hls480pDir = hlsDirectory.appendingPathComponent("480p")
        
        // Create directories
        try? FileManager.default.createDirectory(at: hls720pDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hls480pDir, withIntermediateDirectories: true)
        
        // Create output URLs
        let hls720pURL = hls720pDir.appendingPathComponent("playlist.m3u8")
        let hls480pURL = hls480pDir.appendingPathComponent("playlist.m3u8")
        let masterPlaylistURL = hlsDirectory.appendingPathComponent("master.m3u8")
        
        // Log initial memory usage
        logMemoryUsage("before conversion")
        
        // Run conversion in background task
        currentConversion = Task.detached { [weak self] in
            await self?.performConversion(
                inputURL: inputURL,
                hls720pURL: hls720pURL,
                hls480pURL: hls480pURL,
                masterPlaylistURL: masterPlaylistURL,
                hlsDirectory: hlsDirectory,
                aspectRatio: aspectRatio,
                completion: completion
            )
        }
    }
    
    // MARK: - Background Task Management
    
    private func startBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoConversion") { [weak self] in
            // Background time expired, end the task
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
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
            return Double(info.resident_size) / 1024.0 / 1024.0 // Convert to MB
        } else {
            return 0.0
        }
    }
    
    private func logMemoryUsage(_ context: String) {
        let memory = getMemoryUsage()
        print("DEBUG: [VIDEO CONVERSION] Memory usage \(context): \(String(format: "%.1f", memory)) MB")
    }
    
    private func forceMemoryCleanup() {
        // Force garbage collection
        autoreleasepool {
            // This will help release any autoreleased objects
        }
        
        // Log memory after cleanup
        logMemoryUsage("after cleanup")
    }
    
    func cancelCurrentConversion() {
        currentConversion?.cancel()
        currentConversion = nil
        endBackgroundTask()
    }
    
    // MARK: - Async Conversion
    
    private func performConversion(
        inputURL: URL,
        hls720pURL: URL,
        hls480pURL: URL,
        masterPlaylistURL: URL,
        hlsDirectory: URL,
        aspectRatio: Float?,
        completion: @escaping (HLSConversionResult) -> Void
    ) async {
        // Step 1: Convert to 720p HLS (50% of progress)
        await updateProgress(stage: "Converting to 720p HLS...", progress: 10)
        logMemoryUsage("before 720p conversion")
        
        let success720p = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: hls720pURL,
            resolution: "720",
            bitrate: "2000k",
            aspectRatio: aspectRatio
        )
        
        logMemoryUsage("after 720p conversion")
        
        // Force memory cleanup between conversions
        forceMemoryCleanup()
        
        guard success720p else {
            await MainActor.run {
                completion(HLSConversionResult(
                    success: false,
                    hlsDirectoryURL: nil,
                    errorMessage: "Failed to convert to 720p HLS"
                ))
            }
            endBackgroundTask()
            return
        }
        
        // Step 2: Convert to 480p HLS (remaining 50% of progress)
        await updateProgress(stage: "Converting to 480p HLS...", progress: 60)
        logMemoryUsage("before 480p conversion")
        
        let success480p = await convertToHLSAsync(
            inputURL: inputURL,
            outputURL: hls480pURL,
            resolution: "480",
            bitrate: "1000k",
            aspectRatio: aspectRatio
        )
        
        logMemoryUsage("after 480p conversion")
        
        // Force memory cleanup after 480p conversion
        forceMemoryCleanup()
        
        // Step 3: Create master playlist
        await updateProgress(stage: "Creating master playlist...", progress: 90)
        logMemoryUsage("before master playlist creation")
        
        let masterPlaylistCreated = await createMasterPlaylist(
            masterPlaylistURL: masterPlaylistURL,
            hls720pURL: hls720pURL,
            hls480pURL: hls480pURL
        )
        
        logMemoryUsage("after master playlist creation")
        
        await updateProgress(stage: "Conversion completed!", progress: 100)
        
        // Force memory cleanup
        await Task.yield()
        logMemoryUsage("final")
        
        await MainActor.run {
            completion(HLSConversionResult(
                success: success480p && masterPlaylistCreated,
                hlsDirectoryURL: success480p && masterPlaylistCreated ? hlsDirectory : nil,
                errorMessage: success480p ? (masterPlaylistCreated ? nil : "Failed to create master playlist") : "Failed to convert to 480p HLS"
            ))
        }
        
        endBackgroundTask()
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
        hls480pURL: URL
    ) async -> Bool {
        let masterPlaylistContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        720p/playlist.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=854x480
        480p/playlist.m3u8
        """
        
        do {
            try masterPlaylistContent.write(to: masterPlaylistURL, atomically: true, encoding: .utf8)
            print("DEBUG: [VIDEO CONVERSION] Master playlist created at: \(masterPlaylistURL.path)")
            return true
        } catch {
            print("DEBUG: [VIDEO CONVERSION] Failed to create master playlist: \(error)")
            return false
        }
    }
    
    // MARK: - Async HLS Conversion
    
    private func convertToHLSAsync(
        inputURL: URL,
        outputURL: URL,
        resolution: String,
        bitrate: String,
        aspectRatio: Float?
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            convertToHLS(
                inputURL: inputURL,
                outputURL: outputURL,
                resolution: resolution,
                bitrate: bitrate
            ) { success in
                continuation.resume(returning: success)
            }
        }
    }
    
    // MARK: - Convert to HLS with specific resolution
    private func convertToHLS(
        inputURL: URL,
        outputURL: URL,
        resolution: String,
        bitrate: String,
        completion: @escaping (Bool) -> Void
    ) {
        // First, get video information to determine orientation
        let infoCommand = """
        -i "\(inputURL.path)" \
        -f null \
        -
        """
        
        print("DEBUG: [VIDEO CONVERSION] Getting video info for orientation detection")
        
        FFmpegKit.executeAsync(infoCommand) { infoSession in
            guard let infoSession = infoSession else {
                print("DEBUG: [VIDEO CONVERSION] Failed to get video info")
                completion(false)
                return
            }
            
            // Parse video information to determine if it's portrait
            let logs = infoSession.getLogs()
            var isPortrait = false
            var videoWidth = 0
            var videoHeight = 0
            
            for log in logs {
                if let message = log.getMessage() {
                    // Look for video stream information
                    if message.contains("Video:") && message.contains("x") {
                        // Extract dimensions from log like "Video: hevc (hvc1 / 0x31637668), yuv420p(tv, bt709), 720x800"
                        let components = message.components(separatedBy: " ")
                        for component in components {
                            if component.contains("x") && component.count > 5 {
                                let dimensions = component.components(separatedBy: "x")
                                if dimensions.count == 2,
                                   let width = Int(dimensions[0]),
                                   let height = Int(dimensions[1]) {
                                    videoWidth = width
                                    videoHeight = height
                                    isPortrait = height > width
                                    print("DEBUG: [VIDEO CONVERSION] Detected video dimensions: \(width)x\(height), isPortrait: \(isPortrait)")
                                    break
                                }
                            }
                        }
                    }
                }
            }
            
            // Build conversion command based on orientation
            let scaleFilter: String
            if isPortrait {
                // For portrait videos, scale to height instead of width
                scaleFilter = "scale=-2:\(resolution)"
                print("DEBUG: [VIDEO CONVERSION] Using portrait scaling: scale=-2:\(resolution)")
            } else {
                // For landscape videos, use width scaling
                scaleFilter = "scale=\(resolution):-2"
                print("DEBUG: [VIDEO CONVERSION] Using landscape scaling: scale=\(resolution):-2")
            }
            
            let command = """
            -i "\(inputURL.path)" \
            -c:v libx264 \
            -c:a aac \
            -vf "\(scaleFilter)" \
            -b:v \(bitrate) \
            -b:a 128k \
            -preset ultrafast \
            -tune zerolatency \
            -threads 2 \
            -max_muxing_queue_size 512 \
            -fflags +genpts+igndts \
            -avoid_negative_ts make_zero \
            -max_interleave_delta 0 \
            -bufsize \(bitrate) \
            -maxrate \(bitrate) \
            -f hls \
            -hls_time 10 \
            -hls_list_size 0 \
            -hls_segment_filename "\(outputURL.deletingPathExtension().path)_%03d.ts" \
            -hls_flags delete_segments+independent_segments \
            "\(outputURL.path)"
            """
            
            print("DEBUG: [VIDEO CONVERSION] Converting to \(resolution) with command: \(command)")
            
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
