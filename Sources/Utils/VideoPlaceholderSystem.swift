//
//  VideoPlaceholderSystem.swift
//  Tweet
//
//  Created by AI Assistant on 2025/01/27.
//  Video placeholder system for improved scrolling performance
//

import SwiftUI
import AVFoundation

// MARK: - Video Placeholder System
/// Manages video placeholders to improve scrolling performance
class VideoPlaceholderManager: ObservableObject {
    static let shared = VideoPlaceholderManager()
    private init() {
        setupMemoryManagement()
    }
    
    @Published var loadedVideos: Set<String> = []
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    
    /// Start background loading for a video
    func startBackgroundLoading(for url: URL, mid: String) {
        // Don't start if already loading or loaded
        guard !loadedVideos.contains(mid) && loadingTasks[mid] == nil else { return }
        
        print("DEBUG: [VIDEO PLACEHOLDER] Starting background load for: \(mid)")
        
        let task = Task {
            do {
                // Use BackgroundVideoLoader to load video in background
                _ = try await BackgroundVideoLoader.shared.loadVideo(for: url, mid: mid)
                
                await MainActor.run {
                    self.loadedVideos.insert(mid)
                    self.loadingTasks.removeValue(forKey: mid)
                    print("DEBUG: [VIDEO PLACEHOLDER] Background load completed for: \(mid)")
                }
            } catch {
                await MainActor.run {
                    self.loadingTasks.removeValue(forKey: mid)
                    print("DEBUG: [VIDEO PLACEHOLDER] Background load failed for: \(mid): \(error)")
                }
            }
        }
        
        loadingTasks[mid] = task
    }
    
    /// Check if video is ready to display
    func isVideoReady(for mid: String) -> Bool {
        return loadedVideos.contains(mid)
    }
    
    /// Clear loaded videos (for memory management)
    func clearLoadedVideos() {
        loadedVideos.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }
    
    /// Setup memory management
    func setupMemoryManagement() {
        // Clear cache when app goes to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.clearLoadedVideos()
        }
        
        // Clear cache on memory warning
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.clearLoadedVideos()
        }
    }
}

// MARK: - Video Placeholder View
struct VideoPlaceholderView: View {
    let aspectRatio: CGFloat
    let isLoading: Bool
    
    var body: some View {
        ZStack {
            Color.black
                .aspectRatio(aspectRatio, contentMode: .fit)
            
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
        }
    }
}
