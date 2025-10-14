//
//  UploadProgressManager.swift
//  Tweet
//
//  Manages upload progress tracking and app backgrounding detection
//

import Foundation
import SwiftUI
import Combine

enum UploadStage {
    case preparing
    case convertingVideo
    case uploadingAttachments
    case submittingTweet
    case completed
    case failed
}

@MainActor
class UploadProgressManager: ObservableObject {
    static let shared = UploadProgressManager()
    
    @Published var isUploading: Bool = false
    @Published var currentStage: UploadStage = .preparing
    @Published var stageMessage: String = ""
    @Published var progress: Double = 0.0 // 0.0 to 1.0
    @Published var detailedProgress: String = ""
    @Published var uploadType: String = "" // "tweet", "comment", "chat"
    
    private var uploadStartTime: Date?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var wasBackgrounded: Bool = false
    
    private init() {
        setupBackgroundObserver()
    }
    
    private func setupBackgroundObserver() {
        // Observe app going to background
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isUploading {
                self.wasBackgrounded = true
                print("⚠️ [UploadProgress] App backgrounded during upload")
            }
        }
        
        // Observe app returning to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.wasBackgrounded {
                print("⚠️ [UploadProgress] App foregrounded after upload interruption")
                // Check if upload is still active
                if self.isUploading {
                    // Upload may have failed, notify user
                    self.handleBackgroundInterruption()
                }
                self.wasBackgrounded = false
            }
        }
    }
    
    func startUpload(type: String) {
        isUploading = true
        uploadType = type
        currentStage = .preparing
        stageMessage = NSLocalizedString("Preparing upload...", comment: "Upload stage")
        progress = 0.0
        detailedProgress = ""
        uploadStartTime = Date()
        wasBackgrounded = false
        
        print("📤 [UploadProgress] Started \(type) upload")
    }
    
    func updateProgress(stage: UploadStage, message: String, progress: Double = 0.0, detail: String = "") {
        self.currentStage = stage
        self.stageMessage = message
        self.progress = min(max(progress, 0.0), 1.0)
        self.detailedProgress = detail
        
        print("📊 [UploadProgress] \(message) - \(Int(progress * 100))%")
    }
    
    func completeUpload() {
        currentStage = .completed
        stageMessage = NSLocalizedString("Upload completed", comment: "Upload stage")
        progress = 1.0
        
        if let startTime = uploadStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print("✅ [UploadProgress] Upload completed in \(String(format: "%.1f", duration))s")
        }
        
        // Reset after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            self.isUploading = false
            self.uploadType = ""
            self.progress = 0.0
            self.detailedProgress = ""
        }
    }
    
    func failUpload(message: String) {
        currentStage = .failed
        stageMessage = message
        progress = 0.0
        
        print("❌ [UploadProgress] Upload failed: \(message)")
        
        // Keep failed state visible longer
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.isUploading = false
            self.uploadType = ""
            self.progress = 0.0
            self.detailedProgress = ""
        }
    }
    
    private func handleBackgroundInterruption() {
        // If still uploading after backgrounding, it likely failed
        // The upload manager will detect the actual failure
        print("⚠️ [UploadProgress] Detected potential upload interruption")
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

