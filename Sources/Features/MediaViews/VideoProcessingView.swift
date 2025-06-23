import SwiftUI
import PhotosUI
import AVFoundation

/// A view that demonstrates FFmpeg video processing capabilities
struct VideoProcessingView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0
    @State private var processingMessage = ""
    @State private var processedVideoURL: URL?
    @State private var videoInfo: VideoInfo?
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Video selection
                VStack {
                    Text("Select a video to process")
                        .font(.headline)
                    
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        HStack {
                            Image(systemName: "video.badge.plus")
                            Text("Choose Video")
                        }
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                
                // Video info display
                if let videoInfo = videoInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Video Information")
                            .font(.headline)
                        
                        Text("Duration: \(formatDuration(videoInfo.duration))")
                        Text("Resolution: \(videoInfo.width) x \(videoInfo.height)")
                        Text("Frame Rate: \(String(format: "%.1f", videoInfo.frameRate)) fps")
                        Text("File Size: \(formatFileSize(videoInfo.fileSize))")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                }
                
                // Processing controls
                if selectedVideoURL != nil {
                    VStack(spacing: 15) {
                        Button("Convert to HLS") {
                            Task {
                                await convertToHLS()
                            }
                        }
                        .disabled(isProcessing)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        
                        Button("Extract Thumbnail") {
                            Task {
                                await extractThumbnail()
                            }
                        }
                        .disabled(isProcessing)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        
                        Button("Get Video Info") {
                            Task {
                                await getVideoInfo()
                            }
                        }
                        .disabled(isProcessing)
                        .padding()
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                
                // Processing progress
                if isProcessing {
                    VStack {
                        ProgressView(value: processingProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text(processingMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                // Processed video player
                if let processedVideoURL = processedVideoURL {
                    VStack {
                        Text("Processed Video")
                            .font(.headline)
                        
                        SimpleVideoPlayer(
                            url: processedVideoURL,
                            autoPlay: false,
                            isVisible: true,
                            contentType: "hls_video"
                        )
                        .frame(height: 200)
                        .cornerRadius(10)
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("FFmpeg Video Processing")
            .onChange(of: selectedItem) { _ in
                Task {
                    await loadSelectedVideo()
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    // MARK: - Video Processing Methods
    
    private func loadSelectedVideo() async {
        guard let selectedItem = selectedItem else { return }
        
        do {
            let videoURL = try await selectedItem.loadTransferable(type: URL.self)
            await MainActor.run {
                self.selectedVideoURL = videoURL
                self.processedVideoURL = nil
                self.videoInfo = nil
            }
            
            // Get video info automatically
            await getVideoInfo()
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load video: \(error.localizedDescription)"
                self.showError = true
            }
        }
    }
    
    private func convertToHLS() async {
        guard let inputURL = selectedVideoURL else { return }
        
        await MainActor.run {
            isProcessing = true
            processingProgress = 0
            processingMessage = "Converting to HLS..."
        }
        
        do {
            // Create output directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let outputDirectory = documentsPath.appendingPathComponent("HLS_Output_\(Date().timeIntervalSince1970)")
            
            // Use FFmpeg to convert
            let result = FFmpegManager.shared.convertToHLS(
                inputPath: inputURL.path,
                outputDirectory: outputDirectory.path
            )
            
            await MainActor.run {
                isProcessing = false
                processingProgress = 1.0
            }
            
            switch result {
            case .success(let playlistPath):
                await MainActor.run {
                    processedVideoURL = URL(fileURLWithPath: playlistPath)
                    processingMessage = "HLS conversion completed successfully!"
                }
                
            case .failure(let error):
                await MainActor.run {
                    errorMessage = "HLS conversion failed: \(error.localizedDescription)"
                    showError = true
                }
            }
            
        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = "Conversion failed: \(error.localizedDescription)"
                showError = true
            }
        }
    }
    
    private func extractThumbnail() async {
        guard let inputURL = selectedVideoURL else { return }
        
        await MainActor.run {
            isProcessing = true
            processingProgress = 0
            processingMessage = "Extracting thumbnail..."
        }
        
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let thumbnailPath = documentsPath.appendingPathComponent("thumbnail_\(Date().timeIntervalSince1970).jpg").path
            
            let result = FFmpegManager.shared.extractThumbnail(
                videoPath: inputURL.path,
                outputPath: thumbnailPath,
                time: 1.0
            )
            
            await MainActor.run {
                isProcessing = false
                processingProgress = 1.0
            }
            
            switch result {
            case .success:
                await MainActor.run {
                    processingMessage = "Thumbnail extracted successfully!"
                    // You could display the thumbnail here
                }
                
            case .failure(let error):
                await MainActor.run {
                    errorMessage = "Thumbnail extraction failed: \(error.localizedDescription)"
                    showError = true
                }
            }
            
        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = "Thumbnail extraction failed: \(error.localizedDescription)"
                showError = true
            }
        }
    }
    
    private func getVideoInfo() async {
        guard let inputURL = selectedVideoURL else { return }
        
        let result = await FFmpegManager.shared.getVideoInfo(filePath: inputURL.path)
        
        await MainActor.run {
            switch result {
            case .success(let info):
                self.videoInfo = info
                
            case .failure(let error):
                self.errorMessage = "Failed to get video info: \(error.localizedDescription)"
                self.showError = true
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatDuration(_ duration: Double) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    VideoProcessingView()
} 