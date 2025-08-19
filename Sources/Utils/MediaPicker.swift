import SwiftUI
import PhotosUI
import AVFoundation

@available(iOS 16.0, *)
struct MediaPicker: View {
    @Binding var selectedItems: [PhotosPickerItem]
    @Binding var selectedImages: [UIImage]
    @Binding var showCamera: Bool
    @Binding var error: Error?
    
    let maxSelectionCount: Int
    let supportedTypes: [UTType]
    let onItemAdded: (() -> Void)?
    let onItemRemoved: (() -> Void)?
    
    init(
        selectedItems: Binding<[PhotosPickerItem]>,
        selectedImages: Binding<[UIImage]> = .constant([]),
        showCamera: Binding<Bool>,
        error: Binding<Error?> = .constant(nil),
        maxSelectionCount: Int = 4,
        supportedTypes: [UTType] = [.image, .movie],
        onItemAdded: (() -> Void)? = nil,
        onItemRemoved: (() -> Void)? = nil
    ) {
        self._selectedItems = selectedItems
        self._selectedImages = selectedImages
        self._showCamera = showCamera
        self._error = error
        self.maxSelectionCount = maxSelectionCount
        self.supportedTypes = supportedTypes
        self.onItemAdded = onItemAdded
        self.onItemRemoved = onItemRemoved
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // PhotosPicker
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: maxSelectionCount,
                matching: .any(of: [.images, .videos])
            ) {
                Image(systemName: "photo")
                    .foregroundColor(.blue)
                    .font(.system(size: 20))
            }
            .onChange(of: selectedItems) { _, _ in
                onItemAdded?()
            }
            
            // Camera button (only show if images are supported)
            if supportedTypes.contains(.image) {
                Button(action: {
                    showCamera = true
                }) {
                    Image(systemName: "camera")
                        .foregroundColor(.blue)
                        .font(.system(size: 20))
                }
            }
        }
    }
}

@available(iOS 16.0, *)
struct MediaPreviewGrid: View {
    let selectedItems: [PhotosPickerItem]
    let selectedImages: [UIImage]
    let onRemoveItem: (Int) -> Void
    let onRemoveImage: (Int) -> Void
    
    init(
        selectedItems: [PhotosPickerItem],
        selectedImages: [UIImage] = [],
        onRemoveItem: @escaping (Int) -> Void,
        onRemoveImage: @escaping (Int) -> Void
    ) {
        self.selectedItems = selectedItems
        self.selectedImages = selectedImages
        self.onRemoveItem = onRemoveItem
        self.onRemoveImage = onRemoveImage
    }
    
    var body: some View {
        if !selectedImages.isEmpty || !selectedItems.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                // Camera images
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                    MediaPreviewItem(
                        image: image,
                        onRemove: { onRemoveImage(index) }
                    )
                }
                
                // PhotosPicker items
                ForEach(Array(selectedItems.enumerated()), id: \.offset) { index, item in
                    MediaPreviewItem(
                        item: item,
                        onRemove: { onRemoveItem(index) }
                    )
                }
            }
        }
    }
}

@available(iOS 16.0, *)
struct MediaPreviewItem: View {
    let image: UIImage?
    let item: PhotosPickerItem?
    let onRemove: () -> Void
    
    init(image: UIImage, onRemove: @escaping () -> Void) {
        self.image = image
        self.item = nil
        self.onRemove = onRemove
    }
    
    init(item: PhotosPickerItem, onRemove: @escaping () -> Void) {
        self.image = nil
        self.item = item
        self.onRemove = onRemove
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipped()
                    .cornerRadius(8)
            } else if let item = item {
                ThumbnailView(item: item)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .offset(x: 4, y: -4)
        }
    }
}

@available(iOS 16.0, *)
struct MediaUploadHelper {
    static func prepareItemData(
        selectedItems: [PhotosPickerItem],
        selectedImages: [UIImage]
    ) async throws -> [HproseInstance.PendingTweetUpload.ItemData] {
        var itemData: [HproseInstance.PendingTweetUpload.ItemData] = []
        
        // Process PhotosPicker items (videos and images)
        for item in selectedItems {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    print("DEBUG: Successfully loaded media data: \(data.count) bytes")
                    
                    // Get the type identifier and determine file extension
                    let typeIdentifier = item.supportedContentTypes.first?.identifier ?? "public.image"
                    let fileExtension = getFileExtension(for: typeIdentifier)
                    
                    // Create a unique filename with timestamp
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let filename = "\(timestamp)_\(UUID().uuidString).\(fileExtension)"
                    
                    itemData.append(HproseInstance.PendingTweetUpload.ItemData(
                        identifier: item.itemIdentifier ?? UUID().uuidString,
                        typeIdentifier: typeIdentifier,
                        data: data,
                        fileName: filename,
                        noResample: false
                    ))
                }
            } catch {
                print("DEBUG: Error loading media data: \(error)")
                throw error
            }
        }
        
        // Process camera images
        for image in selectedImages {
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                let timestamp = Int(Date().timeIntervalSince1970)
                let filename = "\(timestamp)_\(UUID().uuidString).jpg"
                
                itemData.append(HproseInstance.PendingTweetUpload.ItemData(
                    identifier: UUID().uuidString,
                    typeIdentifier: "image/jpeg",
                    data: imageData,
                    fileName: filename,
                    noResample: false
                ))
            }
        }
        
        return itemData
    }
    
    private static func getFileExtension(for typeIdentifier: String) -> String {
        if typeIdentifier.contains("jpeg") || typeIdentifier.contains("jpg") {
            return "jpg"
        } else if typeIdentifier.contains("png") {
            return "png"
        } else if typeIdentifier.contains("gif") {
            return "gif"
        } else if typeIdentifier.contains("heic") || typeIdentifier.contains("heif") {
            return "heic"
        } else if typeIdentifier.contains("mp4") {
            return "mp4"
        } else if typeIdentifier.contains("mov") {
            return "mov"
        } else if typeIdentifier.contains("m4v") {
            return "m4v"
        } else if typeIdentifier.contains("mkv") {
            return "mkv"
        } else {
            return "file"
        }
    }
    
    static func validateContent(
        content: String,
        selectedItems: [PhotosPickerItem],
        selectedImages: [UIImage]
    ) -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedContent.isEmpty || !selectedItems.isEmpty || !selectedImages.isEmpty
    }
}
