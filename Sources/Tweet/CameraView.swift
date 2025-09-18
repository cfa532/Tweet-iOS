//
//  CameraView.swift
//  Tweet
//
//  Created by Assistant on 2025/1/27.
//

import SwiftUI
import UIKit
import AVFoundation
import Photos

@available(iOS 16.0, *)
struct CameraView: UIViewControllerRepresentable {
    let onMediaCaptured: (UIImage?, URL?) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        // Check camera availability first
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            print("DEBUG: Camera not available")
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary // Fallback to photo library
            picker.delegate = context.coordinator
            picker.modalPresentationStyle = .fullScreen
            return picker
        }
        
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        
        // Configure for full screen presentation
        picker.modalPresentationStyle = .fullScreen
        
        // Enhanced camera configuration for better focus and capture
        picker.cameraDevice = .rear
        picker.cameraFlashMode = .auto
        picker.cameraCaptureMode = .photo // Default to photo mode
        
        // Ensure proper camera setup
        if UIImagePickerController.isCameraDeviceAvailable(.rear) {
            picker.cameraDevice = .rear
        } else if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        
        // Enable video recording capabilities
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 60 // 60 seconds max
        
        print("DEBUG: Camera configured with device: \(picker.cameraDevice.rawValue)")
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        
        init(_ parent: CameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            print("DEBUG: Camera didFinishPickingMediaWithInfo called")
            
            // Handle image capture
            if let image = info[.originalImage] as? UIImage {
                print("DEBUG: Image captured successfully: \(image.size)")
                
                // Save image to system album
                saveImageToAlbum(image)
                
                parent.onMediaCaptured(image, nil)
            }
            // Handle video capture
            else if let videoURL = info[.mediaURL] as? URL {
                print("DEBUG: Video captured successfully: \(videoURL)")
                
                // Save video to system album
                saveVideoToAlbum(videoURL)
                
                parent.onMediaCaptured(nil, videoURL)
            }
            // No media captured
            else {
                print("DEBUG: No media captured")
                parent.onMediaCaptured(nil, nil)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            print("DEBUG: Camera picker cancelled")
            parent.onMediaCaptured(nil, nil)
            picker.dismiss(animated: true)
        }
        
        // MARK: - Save to System Album
        
        private func saveImageToAlbum(_ image: UIImage) {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    print("DEBUG: Photo library access not authorized")
                    return
                }
                
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            print("DEBUG: Image saved to system album successfully")
                        } else {
                            print("DEBUG: Failed to save image to system album: \(error?.localizedDescription ?? "Unknown error")")
                        }
                    }
                }
            }
        }
        
        private func saveVideoToAlbum(_ videoURL: URL) {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    print("DEBUG: Photo library access not authorized")
                    return
                }
                
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            print("DEBUG: Video saved to system album successfully")
                        } else {
                            print("DEBUG: Failed to save video to system album: \(error?.localizedDescription ?? "Unknown error")")
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    CameraView { image, videoURL in
        if let image = image {
            print("Image captured: \(image)")
        }
        if let videoURL = videoURL {
            print("Video captured: \(videoURL)")
        }
    }
}
