//
//  PDFPreviewView.swift
//  Tweet
//
//  PDF preview component for displaying PDF attachments
//

import SwiftUI
import QuickLook

// MARK: - PDF Preview View for Grid/Cell
struct PDFPreviewView: View {
    let attachment: MimeiFileType
    let baseUrl: URL
    @State private var showPDFViewer = false
    @State private var pdfURL: URL?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadError: String?
    
    private var displayFileName: String {
        attachment.fileName ?? "Document.pdf"
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.gray.opacity(0.15)
            
            VStack(spacing: 12) {
                // PDF Icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.red)
                
                // File name
                Text(displayFileName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                
                // Download/Open indicator
                if isDownloading {
                    ProgressView(value: downloadProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 60)
                        .tint(.red)
                } else if downloadError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Tap to view")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isDownloading {
                downloadAndShowPDF()
            }
        }
        .sheet(isPresented: $showPDFViewer) {
            if let pdfURL = pdfURL {
                PDFQuickLookView(url: pdfURL)
            }
        }
    }
    
    private func downloadAndShowPDF() {
        guard let url = attachment.getUrl(baseUrl) else {
            downloadError = "Invalid URL"
            return
        }
        
        isDownloading = true
        downloadProgress = 0.0
        downloadError = nil
        
        // Download PDF to temporary location
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            DispatchQueue.main.async {
                isDownloading = false
                
                if let error = error {
                    downloadError = error.localizedDescription
                    print("ERROR: [PDFPreviewView] Failed to download PDF: \(error)")
                    return
                }
                
                guard let localURL = localURL else {
                    downloadError = "Download failed"
                    return
                }
                
                // Move to a more permanent temporary location
                let tempDirectory = FileManager.default.temporaryDirectory
                // Make filename unique by incrementing suffix if needed
                let originalFileName = displayFileName
                let fileExtension = (originalFileName as NSString).pathExtension
                let baseName = (originalFileName as NSString).deletingPathExtension
                let ext = fileExtension.isEmpty ? "pdf" : fileExtension
                
                // Find unique filename
                var destinationURL = tempDirectory.appendingPathComponent("\(baseName).\(ext)")
                var counter = 1
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    let uniqueName = "\(baseName)_\(counter).\(ext)"
                    destinationURL = tempDirectory.appendingPathComponent(uniqueName)
                    counter += 1
                }
                
                do {
                    // Remove existing file if present
                    try? FileManager.default.removeItem(at: destinationURL)
                    
                    // Move downloaded file
                    try FileManager.default.moveItem(at: localURL, to: destinationURL)
                    
                    self.pdfURL = destinationURL
                    self.showPDFViewer = true
                    
                    print("DEBUG: [PDFPreviewView] Successfully downloaded PDF to: \(destinationURL)")
                } catch {
                    downloadError = "Failed to save PDF"
                    print("ERROR: [PDFPreviewView] Failed to move PDF: \(error)")
                }
            }
        }
        
        // Track download progress
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async {
                downloadProgress = progress.fractionCompleted
            }
        }
        
        task.resume()
        
        // Keep observation alive until task completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            observation.invalidate()
        }
    }
}

// MARK: - PDF Preview View for Full Screen Browser
struct PDFPreviewViewFullScreen: View {
    let attachment: MimeiFileType
    let baseUrl: URL
    @State private var showPDFViewer = false
    @State private var pdfURL: URL?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadError: String?
    @State private var showActionSheet = false
    
    private var displayFileName: String {
        attachment.fileName ?? "Document.pdf"
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // PDF Icon
                Image(systemName: "doc.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.red)
                
                // File name
                Text(displayFileName)
                    .font(.title3)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                // File size if available
                if let size = attachment.size {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                    .frame(height: 40)
                
                // Action button
                if isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(value: downloadProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .red))
                            .frame(width: 200)
                        
                        Text("Downloading...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                } else if let error = downloadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                        
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        
                        Button("Try Again") {
                            downloadAndShowPDF()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } else {
                    Button(action: {
                        showActionSheet = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Open PDF")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .cornerRadius(25)
                    }
                }
            }
        }
        .confirmationDialog("Open PDF", isPresented: $showActionSheet, titleVisibility: .visible) {
            Button("View in App") {
                downloadAndShowPDF()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPDFViewer) {
            if let pdfURL = pdfURL {
                PDFQuickLookView(url: pdfURL)
            }
        }
        .onAppear {
            // Auto-download and show PDF when full screen view appears
            downloadAndShowPDF()
        }
    }
    
    private func downloadAndShowPDF() {
        guard let url = attachment.getUrl(baseUrl) else {
            downloadError = "Invalid URL"
            return
        }
        
        isDownloading = true
        downloadProgress = 0.0
        downloadError = nil
        
        // Download PDF to temporary location
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            DispatchQueue.main.async {
                isDownloading = false
                
                if let error = error {
                    downloadError = error.localizedDescription
                    print("ERROR: [PDFPreviewView] Failed to download PDF: \(error)")
                    return
                }
                
                guard let localURL = localURL else {
                    downloadError = "Download failed"
                    return
                }
                
                // Move to a more permanent temporary location
                let tempDirectory = FileManager.default.temporaryDirectory
                // Make filename unique by incrementing suffix if needed
                let originalFileName = displayFileName
                let fileExtension = (originalFileName as NSString).pathExtension
                let baseName = (originalFileName as NSString).deletingPathExtension
                let ext = fileExtension.isEmpty ? "pdf" : fileExtension
                
                // Find unique filename
                var destinationURL = tempDirectory.appendingPathComponent("\(baseName).\(ext)")
                var counter = 1
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    let uniqueName = "\(baseName)_\(counter).\(ext)"
                    destinationURL = tempDirectory.appendingPathComponent(uniqueName)
                    counter += 1
                }
                
                do {
                    // Remove existing file if present
                    try? FileManager.default.removeItem(at: destinationURL)
                    
                    // Move downloaded file
                    try FileManager.default.moveItem(at: localURL, to: destinationURL)
                    
                    self.pdfURL = destinationURL
                    self.showPDFViewer = true
                    
                    print("DEBUG: [PDFPreviewView] Successfully downloaded PDF to: \(destinationURL)")
                } catch {
                    downloadError = "Failed to save PDF"
                    print("ERROR: [PDFPreviewView] Failed to move PDF: \(error)")
                }
            }
        }
        
        // Track download progress
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async {
                downloadProgress = progress.fractionCompleted
            }
        }
        
        task.resume()
        
        // Keep observation alive until task completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            observation.invalidate()
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - QuickLook PDF Viewer
struct PDFQuickLookView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        print("DEBUG: [PDFQuickLookView] Creating QLPreviewController for: \(url.lastPathComponent)")
        print("DEBUG: [PDFQuickLookView] File path: \(url.path)")
        print("DEBUG: [PDFQuickLookView] File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        
        // Force reload to ensure data source is queried
        DispatchQueue.main.async {
            controller.reloadData()
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        // Reload data when URL changes
        context.coordinator.url = url
        uiViewController.reloadData()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        
        init(url: URL) {
            self.url = url
            super.init()
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            print("DEBUG: [PDFQuickLookView] numberOfPreviewItems called, returning 1")
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            print("DEBUG: [PDFQuickLookView] previewItemAt \(index) called")
            print("DEBUG: [PDFQuickLookView] Returning URL: \(url.path)")
            
            // Create a proper preview item wrapper
            let item = PreviewItem(url: url, title: url.lastPathComponent)
            return item
        }
    }
    
    // Wrapper class that properly conforms to QLPreviewItem
    private class PreviewItem: NSObject, QLPreviewItem {
        let url: URL
        let title: String
        
        var previewItemURL: URL? {
            print("DEBUG: [PreviewItem] previewItemURL accessed: \(url.path)")
            return url
        }
        
        var previewItemTitle: String? {
            return title
        }
        
        init(url: URL, title: String) {
            self.url = url
            self.title = title
            super.init()
        }
    }
}

