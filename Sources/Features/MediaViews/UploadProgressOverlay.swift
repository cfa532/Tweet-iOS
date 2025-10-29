//
//  UploadProgressOverlay.swift
//  Tweet
//
//  Visual overlay showing upload progress with warning
//

import SwiftUI

struct UploadProgressOverlay: View {
    @ObservedObject var progressManager: UploadProgressManager
    
    var body: some View {
        if progressManager.isUploading {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.3)
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(true)
                
                // Progress card
                VStack(spacing: 20) {
                    // Icon and title
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: stageIcon)
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(uploadTitle)
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            Text(progressManager.stageMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Progress bar
                    if progressManager.currentStage != .failed {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progressManager.progress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            
                            if !progressManager.detailedProgress.isEmpty {
                                Text(progressManager.detailedProgress)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Error message
                    if progressManager.currentStage == .failed {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            
                            Text(progressManager.stageMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemBackground))
                        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                )
                .padding(.horizontal, 40)
            }
            .transition(.opacity)
            .zIndex(1000)
        }
    }
    
    private var uploadTitle: String {
        switch progressManager.uploadType {
        case "tweet":
            return NSLocalizedString("Posting Tweet", comment: "Upload title")
        case "comment":
            return NSLocalizedString("Posting Comment", comment: "Upload title")
        case "chat":
            return NSLocalizedString("Sending Message", comment: "Upload title")
        default:
            return NSLocalizedString("Uploading", comment: "Upload title")
        }
    }
    
    private var stageIcon: String {
        switch progressManager.currentStage {
        case .preparing:
            return "gearshape"
        case .convertingVideo:
            return "waveform.circle"
        case .uploadingAttachments:
            return "arrow.up.circle"
        case .submittingTweet:
            return "paperplane"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        }
    }
}

struct UploadProgressOverlay_Previews: PreviewProvider {
    static var previews: some View {
        UploadProgressOverlay(progressManager: UploadProgressManager.shared)
    }
}

