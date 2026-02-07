//
//  UploadProgressOverlay.swift
//  Tweet
//
//  Visual overlay showing upload progress with warning
//

import SwiftUI

struct UploadProgressOverlay: View {
    @ObservedObject var progressManager: UploadProgressManager
    @State private var showCancelConfirmation = false
    
    var body: some View {
        if progressManager.isUploading {
            ZStack {
                // Semi-transparent background - blocks interaction with content behind
                // The background will naturally block touches to content behind it
                Color.black.opacity(0.3)
                    .edgesIgnoringSafeArea(.all)
                
                // Confirmation dialog overlay
                if showCancelConfirmation {
                    Color.black.opacity(0.5)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            withAnimation {
                                showCancelConfirmation = false
                            }
                        }
                    
                    VStack(spacing: 20) {
                        Text(NSLocalizedString("Cancel Upload", comment: "Cancel upload alert title"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(NSLocalizedString("Are you sure you want to cancel this upload? This action cannot be undone.", comment: "Cancel upload confirmation message"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        HStack(spacing: 16) {
                            Button(action: {
                                print("DEBUG: [UploadProgressOverlay] User cancelled the cancellation")
                                withAnimation {
                                    showCancelConfirmation = false
                                }
                            }) {
                                Text(NSLocalizedString("Continue", comment: "Continue upload button"))
                                    .font(.body)
                                    .foregroundColor(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(10)
                            }
                            
                            Button(action: {
                                print("DEBUG: [UploadProgressOverlay] User confirmed cancellation")
                                withAnimation {
                                    showCancelConfirmation = false
                                }
                                progressManager.cancelUpload()
                            }) {
                                Text(NSLocalizedString("Cancel Upload", comment: "Cancel upload button"))
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.red)
                                    .cornerRadius(10)
                            }
                        }
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemBackground))
                            .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                    )
                    .padding(.horizontal, 40)
                    .zIndex(2000)
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Progress card - positioned on top, fully interactive
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
                        
                        // Close button - use tap gesture for more reliable touch handling
                        ZStack {
                            // Invisible background to ensure full tap area
                            Color.clear
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.primary)
                                .opacity(0.8)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            print("DEBUG: [UploadProgressOverlay] Close button tapped, showing confirmation")
                            withAnimation {
                                showCancelConfirmation = true
                            }
                        }
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
                .allowsHitTesting(true) // Explicitly enable hit testing for the dialog
            }
            .transition(.opacity)
            .zIndex(1000)
            .allowsHitTesting(true) // Ensure the entire overlay can receive touches
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

