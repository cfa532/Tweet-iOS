import SwiftUI
import PhotosUI

// Wrapper struct to give each PhotosPickerItem a unique identifier
struct IdentifiablePhotosPickerItem: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
} 