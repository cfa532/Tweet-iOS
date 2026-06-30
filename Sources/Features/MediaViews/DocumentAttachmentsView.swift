//
//  DocumentAttachmentsView.swift
//  Tweet
//
//  View for displaying document attachments (PDF, Word, etc.) with improved UI
//

import SwiftUI
import QuickLook

/// Identifiable wrapper for document URL to use with .sheet(item:)
struct DocumentURLItem: Identifiable {
    let id: String // Use document's mid as identifier
    let url: URL
}

/// View that displays document attachments vertically below media grid
struct DocumentAttachmentsView: View {
    let parentTweet: Tweet?
    let documents: [MimeiFileType]
    let maxDocuments: Int? // If set, limits number of documents shown and adds ellipsis
    let baseUrl: URL? // Optional baseUrl override (for chat messages)
    
    @State private var documentURLItem: DocumentURLItem? // Use item-based sheet
    @State private var downloadingDocuments: Set<String> = [] // Track which documents are downloading
    @State private var downloadingForShare: Set<String> = [] // Track which documents are downloading for share
    
    private var resolvedBaseUrl: URL {
        return baseUrl 
            ?? parentTweet?.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
    }
    
    // Convenience initializer for Tweet context
    init(parentTweet: Tweet, documents: [MimeiFileType], maxDocuments: Int? = nil) {
        self.parentTweet = parentTweet
        self.documents = documents
        self.maxDocuments = maxDocuments
        self.baseUrl = nil
    }
    
    // Convenience initializer for Chat context
    init(documents: [MimeiFileType], baseUrl: URL, maxDocuments: Int? = nil) {
        self.parentTweet = nil
        self.documents = documents
        self.maxDocuments = maxDocuments
        self.baseUrl = baseUrl
    }
    
    private var displayedDocuments: [MimeiFileType] {
        if let maxDocuments = maxDocuments, documents.count > maxDocuments {
            return Array(documents.prefix(maxDocuments))
        }
        return documents
    }
    
    private var hasMoreDocuments: Bool {
        if let maxDocuments = maxDocuments {
            return documents.count > maxDocuments
        }
        return false
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Vertical list of documents
            ForEach(displayedDocuments, id: \.mid) { document in
                DocumentRowView(
                    document: document,
                    isDownloading: downloadingDocuments.contains(document.mid),
                    isDownloadingForShare: downloadingForShare.contains(document.mid),
                    onTap: {
                        downloadAndShowDocument(document)
                    },
                    onDownloadTap: {
                        downloadAndShare(document)
                    }
                )
            }
            .onAppear {
                print("DEBUG: [DocumentAttachmentsView] Showing \(displayedDocuments.count) of \(documents.count) documents, maxDocuments: \(maxDocuments?.description ?? "nil")")
            }
            
            // Show ellipsis if there are more documents
            if hasMoreDocuments {
                HStack(spacing: 4) {
                    Text("···")
                        .font(.system(size: 20, weight: .bold))
                    Text("+\(documents.count - displayedDocuments.count) more")
                        .font(.system(size: 13))
                }
                .padding(.leading, 12)
                .padding(.top, 0)
            }
        }
        .padding(4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        .sheet(item: $documentURLItem, onDismiss: {
            print("DEBUG: [DocumentAttachmentsView] Sheet dismissed")
        }) { item in
            PDFQuickLookView(url: item.url)
                .onAppear {
                    print("DEBUG: [DocumentAttachmentsView] Sheet presenting with URL: \(item.url.lastPathComponent)")
                }
                .onDisappear {
                    print("DEBUG: [DocumentAttachmentsView] PDFQuickLookView disappeared")
                }
        }
    }
    
    private func downloadAndShowDocument(_ document: MimeiFileType) {
        // Prevent duplicate taps while downloading
        guard !downloadingDocuments.contains(document.mid) else {
            print("DEBUG: [DocumentAttachmentsView] Already downloading, ignoring tap")
            return
        }
        
        guard let url = document.getUrl(resolvedBaseUrl) else {
            print("ERROR: [DocumentAttachmentsView] Invalid document URL")
            return
        }
        
        // Create consistent filename based on document CID
        let tempDirectory = FileManager.default.temporaryDirectory
        let originalFileName = document.fileName ?? "Document.pdf"
        let fileExtension = (originalFileName as NSString).pathExtension
        let baseName = (originalFileName as NSString).deletingPathExtension
        let ext = fileExtension.isEmpty ? "pdf" : fileExtension
        
        // Use document ID for unique but consistent filename
        let uniqueFileName = "\(baseName)_\(document.mid.prefix(8)).\(ext)"
        let cachedURL = tempDirectory.appendingPathComponent(uniqueFileName)
        
        // Check if file already exists in cache
        if FileManager.default.fileExists(atPath: cachedURL.path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > 0,
           FileManager.default.isReadableFile(atPath: cachedURL.path),
           (try? FileHandle(forReadingFrom: cachedURL)) != nil {
            
            // File exists and is valid - use cached version
            print("DEBUG: [DocumentAttachmentsView] Using cached file: \(uniqueFileName) (\(fileSize) bytes)")
            
            // Show spinner briefly while presenting
            downloadingDocuments.insert(document.mid)
            
            // Present sheet with URL item after a small delay to ensure file system is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Double-check file is still accessible before presenting
                guard FileManager.default.fileExists(atPath: cachedURL.path),
                      FileManager.default.isReadableFile(atPath: cachedURL.path),
                      (try? FileHandle(forReadingFrom: cachedURL)) != nil else {
                    print("ERROR: [DocumentAttachmentsView] Cached file became inaccessible before presentation")
                    downloadingDocuments.remove(document.mid)
                    return
                }
                
                self.documentURLItem = DocumentURLItem(id: document.mid, url: cachedURL)
                print("DEBUG: [DocumentAttachmentsView] Presenting PDF viewer (cached) with URL: \(cachedURL.lastPathComponent)")
                
                // Hide spinner after sheet is presented
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    downloadingDocuments.remove(document.mid)
                }
            }
            return
        }
        
        // If cached file exists but is invalid, remove it and download fresh
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            print("DEBUG: [DocumentAttachmentsView] Cached file exists but is invalid, removing and re-downloading")
            try? FileManager.default.removeItem(at: cachedURL)
        }
        
        // File doesn't exist or is invalid - need to download
        documentURLItem = nil
        
        print("DEBUG: [DocumentAttachmentsView] Downloading file from server...")
        downloadingDocuments.insert(document.mid)
        
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            // CRITICAL: Copy file IMMEDIATELY before URLSession deletes the temp file
            // Do NOT dispatch to main queue until after file is copied!
            
            if let error = error {
                DispatchQueue.main.async {
                    downloadingDocuments.remove(document.mid)
                    print("ERROR: [DocumentAttachmentsView] Failed to download: \(error)")
                }
                return
            }
            
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    downloadingDocuments.remove(document.mid)
                    print("ERROR: [DocumentAttachmentsView] No local URL")
                }
                return
            }
            
            // Copy file synchronously BEFORE URLSession cleans it up
            do {
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: cachedURL.path) {
                    try FileManager.default.removeItem(at: cachedURL)
                    print("DEBUG: [DocumentAttachmentsView] Removed existing cached file")
                }
                
                // Copy downloaded file to cache (MUST happen before returning from this handler)
                try FileManager.default.copyItem(at: localURL, to: cachedURL)
                print("DEBUG: [DocumentAttachmentsView] File copied to cache: \(uniqueFileName)")
                
                // Ensure file is flushed to disk by opening and closing a file handle
                let fileHandle = try FileHandle(forWritingTo: cachedURL)
                try fileHandle.synchronize()
                try fileHandle.close()
                
                // Verify file is valid and readable with multiple checks
                guard FileManager.default.fileExists(atPath: cachedURL.path),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
                      let fileSize = attributes[.size] as? Int64,
                      fileSize > 0,
                      FileManager.default.isReadableFile(atPath: cachedURL.path) else {
                    DispatchQueue.main.async {
                        downloadingDocuments.remove(document.mid)
                    }
                    print("ERROR: [DocumentAttachmentsView] Downloaded file is empty, invalid, or not readable")
                    try? FileManager.default.removeItem(at: cachedURL)
                    return
                }
                
                // Verify file can actually be opened (QuickLook requirement)
                guard (try? FileHandle(forReadingFrom: cachedURL)) != nil else {
                    DispatchQueue.main.async {
                        downloadingDocuments.remove(document.mid)
                    }
                    print("ERROR: [DocumentAttachmentsView] Cannot open file for reading")
                    try? FileManager.default.removeItem(at: cachedURL)
                    return
                }
                
                print("DEBUG: [DocumentAttachmentsView] File verified and readable: \(fileSize) bytes")
                
                // Now switch to main queue for UI updates
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Double-check file is still accessible before presenting
                    guard FileManager.default.fileExists(atPath: cachedURL.path),
                          FileManager.default.isReadableFile(atPath: cachedURL.path),
                          (try? FileHandle(forReadingFrom: cachedURL)) != nil else {
                        print("ERROR: [DocumentAttachmentsView] File became inaccessible before presentation")
                        downloadingDocuments.remove(document.mid)
                        return
                    }
                    
                    self.documentURLItem = DocumentURLItem(id: document.mid, url: cachedURL)
                    print("DEBUG: [DocumentAttachmentsView] Presenting PDF viewer (downloaded) with URL: \(cachedURL.lastPathComponent)")
                    
                    // Hide spinner after sheet is presented
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        downloadingDocuments.remove(document.mid)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    downloadingDocuments.remove(document.mid)
                }
                print("ERROR: [DocumentAttachmentsView] Failed to cache file: \(error.localizedDescription)")
                // Clean up partial file
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }
        
        task.resume()
    }
    
    private func downloadAndShare(_ document: MimeiFileType) {
        guard let url = document.getUrl(resolvedBaseUrl) else {
            print("ERROR: [DocumentAttachmentsView] Invalid document URL")
            return
        }
        
        downloadingForShare.insert(document.mid)
        
        // Download and present share sheet with original filename
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    downloadingForShare.remove(document.mid)
                    print("ERROR: [DocumentAttachmentsView] No local URL for download")
                }
                return
            }
            
            do {
                // Copy to temp directory with original filename
                // IMPORTANT: Do this immediately in the completion handler, not in DispatchQueue.main.async
                // The temporary file from URLSession may be cleaned up if we wait
                let tempDirectory = FileManager.default.temporaryDirectory
                let originalFileName = document.fileName ?? getDefaultFileName(for: document.type)
                let destinationURL = tempDirectory.appendingPathComponent(originalFileName)
                
                // Remove existing file if present
                try? FileManager.default.removeItem(at: destinationURL)
                
                // Copy file with original name
                try FileManager.default.copyItem(at: localURL, to: destinationURL)
                
                DispatchQueue.main.async {
                    // Present share sheet with properly named file
                    let activityVC = UIActivityViewController(
                        activityItems: [destinationURL],
                        applicationActivities: nil
                    )
                    
                    // Exclude some activities that don't make sense for documents
                    activityVC.excludedActivityTypes = [
                        .assignToContact,
                        .addToReadingList,
                        .postToFacebook,
                        .postToTwitter,
                        .postToWeibo,
                        .postToVimeo,
                        .postToFlickr
                    ]
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootViewController = windowScene.windows.first?.rootViewController {
                        var topController = rootViewController
                        while let presented = topController.presentedViewController {
                            topController = presented
                        }
                        
                        // For iPad, need to set source view
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = topController.view
                            popover.sourceRect = CGRect(x: topController.view.bounds.midX,
                                                       y: topController.view.bounds.midY,
                                                       width: 0, height: 0)
                            popover.permittedArrowDirections = []
                        }
                        
                        topController.present(activityVC, animated: true) {
                            // Only hide spinner after share sheet is presented
                            downloadingForShare.remove(document.mid)
                            print("DEBUG: [DocumentAttachmentsView] Share sheet presented with file: \(originalFileName)")
                        }
                    } else {
                        // Fallback: hide spinner if we can't present
                        downloadingForShare.remove(document.mid)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    downloadingForShare.remove(document.mid)
                    print("ERROR: [DocumentAttachmentsView] Failed to prepare file for sharing: \(error)")
                }
            }
        }
        
        task.resume()
    }
    
    nonisolated private func getDefaultFileName(for type: MediaType) -> String {
        switch type {
        case .pdf:
            return "Document.pdf"
        case .word:
            return "Document.docx"
        case .excel:
            return "Spreadsheet.xlsx"
        case .ppt:
            return "Presentation.pptx"
        case .zip:
            return "Archive.zip"
        case .txt:
            return "Text.txt"
        case .html:
            return "Page.html"
        default:
            return "Attachment"
        }
    }
}

/// Individual document row view with improved UI
struct DocumentRowView: View {
    let document: MimeiFileType
    let isDownloading: Bool
    let isDownloadingForShare: Bool
    let onTap: () -> Void
    let onDownloadTap: () -> Void
    
    private var iconName: String {
        switch document.type {
        case .pdf:
            return "doc.fill"
        case .word:
            return "doc.text.fill"
        case .excel:
            return "tablecells.fill"
        case .ppt:
            return "play.rectangle.fill"
        case .zip:
            return "archivebox.fill"
        case .txt:
            return "doc.plaintext.fill"
        case .html:
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc.fill"
        }
    }
    
    private var iconColor: Color {
        switch document.type {
        case .pdf:
            return .red
        case .word:
            return .blue
        case .excel:
            return .green
        case .ppt:
            return .orange
        case .zip:
            return .purple
        default:
            return .gray
        }
    }
    
    private var displayFileName: String {
        truncateFileName(document.fileName ?? "Document")
    }
    
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.system(size: 16))
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayFileName)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let size = document.size {
                        Text(formatFileSize(size))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Download/share button
                Button(action: {
                    onDownloadTap()
                }) {
                    if isDownloadingForShare {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(iconColor)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isDownloadingForShare)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .opacity(isDownloading ? 0.5 : 1.0)
            .disabled(isDownloading || isDownloadingForShare)
            
            // Spinner overlay when downloading for preview
            if isDownloading {
                ProgressView()
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6).opacity(0.8))
                    .cornerRadius(8)
            }
        }
        .onTapGesture {
            if !isDownloading && !isDownloadingForShare {
                onTap()
            }
        }
    }
    
    private func truncateFileName(_ fileName: String, maxLength: Int = 30) -> String {
        guard fileName.count > maxLength else {
            return fileName
        }
        
        let ellipsis = "..."
        let halfLength = (maxLength - ellipsis.count) / 2
        
        let start = String(fileName.prefix(halfLength))
        let end = String(fileName.suffix(halfLength))
        
        return "\(start)\(ellipsis)\(end)"
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
