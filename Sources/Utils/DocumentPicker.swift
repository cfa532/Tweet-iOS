//
//  DocumentPicker.swift
//  Tweet
//
//  Document picker for selecting PDF and other document files
//

import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI wrapper for UIDocumentPickerViewController
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedDocuments: [DocumentFile]
    let allowedTypes: [UTType]
    let allowsMultipleSelection: Bool
    
    init(
        selectedDocuments: Binding<[DocumentFile]>,
        allowedTypes: [UTType] = [.pdf],
        allowsMultipleSelection: Bool = true
    ) {
        self._selectedDocuments = selectedDocuments
        self.allowedTypes = allowedTypes
        self.allowsMultipleSelection = allowsMultipleSelection
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // No updates needed
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var documents: [DocumentFile] = []
            
            for url in urls {
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    print("ERROR: [DocumentPicker] Could not access security-scoped resource: \(url)")
                    continue
                }
                
                defer {
                    url.stopAccessingSecurityScopedResource()
                }
                
                do {
                    // Read file data
                    let data = try Data(contentsOf: url)
                    let fileName = url.lastPathComponent
                    let fileSize = Int64(data.count)
                    
                    // Determine media type
                    let mediaType = determineMediaType(from: url)
                    
                    print("DEBUG: [DocumentPicker] Picked document: \(fileName), size: \(fileSize) bytes, type: \(mediaType)")
                    
                    documents.append(DocumentFile(
                        url: url,
                        data: data,
                        fileName: fileName,
                        fileSize: fileSize,
                        mediaType: mediaType
                    ))
                } catch {
                    print("ERROR: [DocumentPicker] Failed to read document: \(error)")
                }
            }
            
            DispatchQueue.main.async {
                self.parent.selectedDocuments = documents
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            print("DEBUG: [DocumentPicker] Document picker was cancelled")
        }
        
        private func determineMediaType(from url: URL) -> MediaType {
            let pathExtension = url.pathExtension.lowercased()
            
            switch pathExtension {
            case "pdf":
                return .pdf
            case "doc", "docx":
                return .word
            case "xls", "xlsx":
                return .excel
            case "ppt", "pptx":
                return .ppt
            case "txt":
                return .txt
            case "html", "htm":
                return .html
            case "zip", "rar", "7z":
                return .zip
            default:
                return .unknown
            }
        }
    }
}

/// Represents a selected document file
struct DocumentFile: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data
    let fileName: String
    let fileSize: Int64
    let mediaType: MediaType
}

/// Button view that triggers document picker
struct DocumentPickerButton: View {
    @State private var showDocumentPicker = false
    @Binding var selectedDocuments: [DocumentFile]
    let allowedTypes: [UTType]
    let icon: String
    let color: Color
    
    init(
        selectedDocuments: Binding<[DocumentFile]>,
        allowedTypes: [UTType] = [.pdf],
        icon: String = "doc.fill",
        color: Color = .blue
    ) {
        self._selectedDocuments = selectedDocuments
        self.allowedTypes = allowedTypes
        self.icon = icon
        self.color = color
    }
    
    var body: some View {
        Button(action: {
            showDocumentPicker = true
        }) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 20))
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                selectedDocuments: $selectedDocuments,
                allowedTypes: allowedTypes
            )
        }
    }
}

/// Preview grid for selected documents
struct DocumentPreviewGrid: View {
    let documents: [DocumentFile]
    let onRemove: (Int) -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                    DocumentThumbnailView(
                        document: document,
                        onRemove: {
                            onRemove(index)
                        }
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Thumbnail view for a single document
struct DocumentThumbnailView: View {
    let document: DocumentFile
    let onRemove: () -> Void
    
    private var iconName: String {
        switch document.mediaType {
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
        switch document.mediaType {
        case .pdf:
            return .red
        case .word:
            return .blue
        case .excel:
            return .green
        case .ppt:
            return .orange
        default:
            return .gray
        }
    }
    
    private var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: document.fileSize)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Document preview
                VStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 32))
                        .foregroundColor(iconColor)
                    
                    Text(document.fileName)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 80)
                    
                    Text(formattedFileSize)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(width: 90, height: 100)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                
                // Remove button
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .background(Color.white.clipShape(Circle()))
                }
                .offset(x: 8, y: -8)
            }
        }
    }
}

