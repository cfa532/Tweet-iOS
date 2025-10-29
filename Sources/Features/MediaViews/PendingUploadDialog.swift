//
//  PendingUploadDialog.swift
//  Tweet
//
//  Dialog for handling pending uploads with retry/cancel options
//

import SwiftUI

struct PendingUploadDialog: View {
    let pendingUpload: TweetUploadManager.PendingTweetUpload
    let onRetry: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
            }
            
            // Title and message
            VStack(spacing: 12) {
                Text(NSLocalizedString("Upload Interrupted", comment: "Dialog title"))
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(uploadInterruptedMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Upload details
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(NSLocalizedString("Type:", comment: "Upload info"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(uploadTypeText)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text(NSLocalizedString("Date:", comment: "Upload info"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTimestamp(pendingUpload.timestamp))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                if pendingUpload.itemData.count > 0 {
                    HStack {
                        Text(NSLocalizedString("Attachments:", comment: "Upload info"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(pendingUpload.itemData.count)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
                
                if let content = pendingUpload.tweet.content, !content.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Content:", comment: "Upload info"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(content)
                            .font(.caption)
                            .lineLimit(3)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
            
            // Action buttons
            VStack(spacing: 12) {
                Button(action: {
                    dismiss()
                    onRetry()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(NSLocalizedString("Retry Upload", comment: "Button"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button(action: {
                    dismiss()
                    onCancel()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(NSLocalizedString("Discard", comment: "Button"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundColor(.red)
                    .cornerRadius(12)
                }
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(.systemBackground))
        )
        .padding(.horizontal, 24)
    }
    
    private var uploadInterruptedMessage: String {
        if pendingUpload.retryCount > 0 {
            return String(
                format: NSLocalizedString("Your upload was interrupted and %d retry attempts have failed. Would you like to try again or discard it?", comment: "Dialog message"),
                pendingUpload.retryCount
            )
        } else {
            return NSLocalizedString("Your upload was interrupted, possibly because the app was closed. Would you like to retry the upload or discard it?", comment: "Dialog message")
        }
    }
    
    private var uploadTypeText: String {
        if pendingUpload.tweet.originalTweetId != nil {
            return NSLocalizedString("Comment", comment: "Upload type")
        } else {
            return NSLocalizedString("Tweet", comment: "Upload type")
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PendingUploadDialog_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.opacity(0.3)
                .edgesIgnoringSafeArea(.all)
            
            PendingUploadDialog(
                pendingUpload: TweetUploadManager.PendingTweetUpload(
                    tweet: Tweet(
                        mid: "test",
                        authorId: "author",
                        content: "This is a test tweet with some content",
                        timestamp: Date().addingTimeInterval(-3600)
                    ),
                    itemData: [],
                    retryCount: 1
                ),
                onRetry: {},
                onCancel: {}
            )
        }
    }
}

