import SwiftUI
import PhotosUI

// Wrapper struct to give each PhotosPickerItem a unique identifier
struct IdentifiablePhotosPickerItem: Identifiable {
    // Use itemIdentifier as the stable ID to prevent re-rendering on text changes
    var id: String {
        return item.itemIdentifier ?? UUID().uuidString
    }
    let item: PhotosPickerItem
} 