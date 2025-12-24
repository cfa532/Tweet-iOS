//
//  DocumentAttachmentsView.swift
//  Tweet
//
//  View for displaying document attachments (PDF, Word, etc.) in wrappable rows
//

import SwiftUI
import QuickLook

/// View that displays document attachments vertically below media grid
struct DocumentAttachmentsView: View {
    let parentTweet: Tweet
    let documents: [MimeiFileType]
    let maxDocuments: Int? // If set, limits number of documents shown and adds ellipsis
    
    @State private var selectedDocument: MimeiFileType?
    @State private var showPDFViewer = false
    @State private var pdfURL: URL?
    @State private var isDownloading = false
    @State private var showDownloadSheet = false
    @State private var documentToDownload: MimeiFileType?
    
    private var baseUrl: URL {
        return parentTweet.author?.baseUrl 
            ?? HproseInstance.shared.appUser.baseUrl 
            ?? HproseInstance.baseUrl
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
        VStack(alignment: .leading, spacing: 4) {
            // Vertical list of documents
            ForEach(displayedDocuments, id: \.mid) { document in
                DocumentRowView(
                    document: document,
                    onTap: {
                        downloadAndShowDocument(document)
                    },
                    onLongPress: {
                        documentToDownload = document
                        showDownloadSheet = true
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
//                        .foregroundColor(.secondary)
                    Text("+\(documents.count - displayedDocuments.count) more")
                        .font(.system(size: 13))
//                        .foregroundColor(.secondary)
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
        .sheet(isPresented: $showPDFViewer, onDismiss: {
            // Clean up state when sheet is dismissed
            print("DEBUG: [DocumentAttachmentsView] Sheet dismissed")
        }) {
            Group {
                if let pdfURL = pdfURL {
                    PDFQuickLookView(url: pdfURL)
                        .onAppear {
                            print("DEBUG: [DocumentAttachmentsView] Sheet presenting with URL: \(pdfURL.lastPathComponent)")
                        }
                        .onDisappear {
                            print("DEBUG: [DocumentAttachmentsView] PDFQuickLookView disappeared")
                        }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Failed to load document")
                            .font(.headline)
                        Text("Please try again")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Close") {
                            showPDFViewer = false
                        }
                        .padding()
                    }
                    .onAppear {
                        print("ERROR: [DocumentAttachmentsView] Sheet presented but pdfURL is nil!")
                    }
                }
            }
        }
        .confirmationDialog(
            "Document Options",
            isPresented: $showDownloadSheet,
            titleVisibility: .visible
        ) {
            Button("Preview") {
                if let document = documentToDownload {
                    downloadAndShowDocument(document)
                }
            }
            Button("Download to Files") {
                if let document = documentToDownload {
                    downloadToFiles(document)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    private func downloadAndShowDocument(_ document: MimeiFileType) {
        // Prevent duplicate taps while downloading
        guard !isDownloading else {
            print("DEBUG: [DocumentAttachmentsView] Already downloading, ignoring tap")
            return
        }
        
        guard let url = document.getUrl(baseUrl) else {
            print("ERROR: [DocumentAttachmentsView] Invalid document URL")
            return
        }
        
        // Reset state before loading
        showPDFViewer = false
        pdfURL = nil
        
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
           FileManager.default.isReadableFile(atPath: cachedURL.path) {
            
            // File exists and is valid - use cached version
            print("DEBUG: [DocumentAttachmentsView] Using cached file: \(uniqueFileName) (\(fileSize) bytes)")
            
            // Set URL and present immediately on main thread
            DispatchQueue.main.async {
                self.pdfURL = cachedURL
                // Wait one runloop cycle to ensure URL is set
                DispatchQueue.main.async {
                    self.showPDFViewer = true
                }
            }
            return
        }
        
        // File doesn't exist or is invalid - download it
        print("DEBUG: [DocumentAttachmentsView] Downloading file from server...")
        isDownloading = true
        
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            DispatchQueue.main.async {
                self.isDownloading = false
                
                if let error = error {
                    print("ERROR: [DocumentAttachmentsView] Failed to download: \(error)")
                    return
                }
                
                guard let localURL = localURL else {
                    print("ERROR: [DocumentAttachmentsView] No local URL")
                    return
                }
                
                do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: cachedURL.path) {
                        try FileManager.default.removeItem(at: cachedURL)
                        print("DEBUG: [DocumentAttachmentsView] Removed existing cached file")
                    }
                    
                    // Copy downloaded file to cache
                    try FileManager.default.copyItem(at: localURL, to: cachedURL)
                    print("DEBUG: [DocumentAttachmentsView] Cached file: \(uniqueFileName)")
                    
                    // Verify file is valid
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
                          let fileSize = attributes[.size] as? Int64,
                          fileSize > 0 else {
                        print("ERROR: [DocumentAttachmentsView] Downloaded file is empty or invalid")
                        try? FileManager.default.removeItem(at: cachedURL)
                        return
                    }
                    
                    print("DEBUG: [DocumentAttachmentsView] File verified: \(fileSize) bytes")
                    
                    // Set URL first, then present
                    self.pdfURL = cachedURL
                    // Wait one runloop cycle to ensure URL is set
                    DispatchQueue.main.async {
                        self.showPDFViewer = true
                    }
                } catch {
                    print("ERROR: [DocumentAttachmentsView] Failed to cache file: \(error.localizedDescription)")
                    // Clean up partial file
                    try? FileManager.default.removeItem(at: cachedURL)
                }
            }
        }
        
        task.resume()
    }
    
    private func downloadToFiles(_ document: MimeiFileType) {
        guard let url = document.getUrl(baseUrl) else {
            print("ERROR: [DocumentAttachmentsView] Invalid document URL")
            return
        }
        
        // Download and present share sheet with original filename
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL else {
                print("ERROR: [DocumentAttachmentsView] No local URL for download")
                return
            }
            
            do {
                // Copy to temp directory with original filename
                let tempDirectory = FileManager.default.temporaryDirectory
                let originalFileName = document.fileName ?? "Document.pdf"
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
                        
                        topController.present(activityVC, animated: true)
                        print("DEBUG: [DocumentAttachmentsView] Share sheet presented with file: \(originalFileName)")
                    }
                }
            } catch {
                print("ERROR: [DocumentAttachmentsView] Failed to prepare file for sharing: \(error)")
            }
        }
        
        task.resume()
    }
}

/// Individual document row view
struct DocumentRowView: View {
    let document: MimeiFileType
    let onTap: () -> Void
    let onLongPress: () -> Void
    
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
        document.fileName ?? "Document"
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 16))
                .frame(width: 24)
            
            Text(displayFileName)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
    }
}

/// Flow layout for wrappable rows
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            let position = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    // New line
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                sizes.append(size)
                
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(
                width: maxWidth,
                height: y + lineHeight
            )
        }
    }
}

