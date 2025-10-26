//
//  CircularImageCropper.swift
//  Tweet
//
//  Created for circular avatar cropping
//

import SwiftUI
import UIKit
import PhotosUI

struct CircularImageCropperView: View {
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void
    
    @State private var selectedImage: UIImage? = nil
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    private let circleSize: CGFloat = 280
    
    private var image: UIImage? {
        selectedImage
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            if let image = selectedImage {
                // Show cropping UI when image is selected
                croppingView(for: image)
            } else {
                // Show "Select Photo" screen
                selectPhotoView
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, newItem in
            if let item = newItem {
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let loadedImage = UIImage(data: data) {
                        await MainActor.run {
                            selectedImage = loadedImage
                        }
                    }
                }
            }
        }
        .onAppear {
            // Open photo picker immediately when cropper appears
            showPhotoPicker = true
        }
    }
    
    private var selectPhotoView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.5))
            
            Text(NSLocalizedString("Select a photo", comment: "Select photo prompt"))
                .font(.title2)
                .foregroundColor(.white)
            
            Button(action: {
                showPhotoPicker = true
            }) {
                Text(NSLocalizedString("Choose Photo", comment: "Choose photo button"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: 200)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            
            Spacer()
            
            Button(action: onCancel) {
                Text(NSLocalizedString("Cancel", comment: "Cancel button"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: 200)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(12)
            }
            .padding(.bottom, 40)
        }
    }
    
    private func croppingView(for image: UIImage) -> some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Image cropping area
            GeometryReader { geometry in
                    let screenWidth = geometry.size.width
                    let screenHeight = geometry.size.height
                    
                    ZStack {
                        // The draggable/scalable image
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: screenWidth, height: screenHeight)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let delta = value / lastScale
                                        lastScale = value
                                        let newScale = scale * delta
                                        // Limit scale between 0.5x and 5x
                                        scale = min(max(newScale, 0.5), 5.0)
                                    }
                                    .onEnded { _ in
                                        lastScale = 1.0
                                    }
                            )
                        
                        // Dark overlay with circular cutout
                        DarkOverlayWithHole(holeSize: circleSize)
                            .allowsHitTesting(false)
                        
                        // Circular border
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: circleSize, height: circleSize)
                            .allowsHitTesting(false)
                    }
                    .frame(width: screenWidth, height: screenHeight)
                    .clipped()
            }
            
            Spacer()
            
            // Bottom buttons
            HStack(spacing: 16) {
                Button(action: onCancel) {
                    Text(NSLocalizedString("Cancel", comment: "Cancel button"))
                        .font(.body)
                        .foregroundColor(.white)
                        .frame(width: 140)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)
                }
                
                Button(action: cropImage) {
                    Text(NSLocalizedString("Done", comment: "Done button"))
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(width: 140)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
            .padding(.bottom, 30)
        }
    }
    
    private func cropImage() {
        guard let image = selectedImage else { return }
        
        let screenSize = UIScreen.main.bounds.size
        
        // Calculate how the image is displayed (scaledToFit)
        let imageAspect = image.size.width / image.size.height
        let screenAspect = screenSize.width / screenSize.height
        
        var displaySize: CGSize
        if imageAspect > screenAspect {
            // Image is wider - fit to width
            displaySize = CGSize(
                width: screenSize.width,
                height: screenSize.width / imageAspect
            )
        } else {
            // Image is taller - fit to height
            displaySize = CGSize(
                width: screenSize.height * imageAspect,
                height: screenSize.height
            )
        }
        
        // Apply user's zoom scale
        displaySize.width *= scale
        displaySize.height *= scale
        
        // Circle is at screen center
        let circleCenterX = screenSize.width / 2
        let circleCenterY = screenSize.height / 2
        
        // Image center on screen (with user's drag offset)
        let imageCenterX = screenSize.width / 2 + offset.width
        let imageCenterY = screenSize.height / 2 + offset.height
        
        // Calculate where the circle overlaps the image (in screen coordinates)
        let cropScreenX = circleCenterX - circleSize / 2 - (imageCenterX - displaySize.width / 2)
        let cropScreenY = circleCenterY - circleSize / 2 - (imageCenterY - displaySize.height / 2)
        
        // Convert screen coordinates to image coordinates
        let scaleToImage = image.size.width / displaySize.width
        
        let cropRect = CGRect(
            x: cropScreenX * scaleToImage,
            y: cropScreenY * scaleToImage,
            width: circleSize * scaleToImage,
            height: circleSize * scaleToImage
        )
        
        NSLog("🔍 [Crop] Image size: \(image.size), Display size: \(displaySize), Scale: \(scale)")
        NSLog("🔍 [Crop] Offset: \(offset), Circle center: (\(circleCenterX), \(circleCenterY))")
        NSLog("🔍 [Crop] Crop rect: \(cropRect)")
        
        // Perform the actual crop
        if let croppedImage = cropToSquare(image: image, rect: cropRect) {
            onCrop(croppedImage)
        } else {
            NSLog("⚠️ [Crop] Failed to crop, returning original")
            onCrop(image)
        }
    }
    
    private func cropToSquare(image: UIImage, rect: CGRect) -> UIImage? {
        // Ensure rect is within image bounds
        guard let cgImage = image.cgImage else { return nil }
        
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        var cropRect = rect
        
        // Clamp the crop rect to image bounds
        cropRect.origin.x = max(0, min(cropRect.origin.x, imageSize.width - cropRect.size.width))
        cropRect.origin.y = max(0, min(cropRect.origin.y, imageSize.height - cropRect.size.height))
        cropRect.size.width = min(cropRect.size.width, imageSize.width)
        cropRect.size.height = min(cropRect.size.height, imageSize.height)
        
        NSLog("🔍 [Crop] Final rect after clamping: \(cropRect)")
        
        // Crop to square
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { 
            NSLog("⚠️ [Crop] CGImage cropping failed")
            return nil 
        }
        
        let croppedImage = UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
        NSLog("✅ [Crop] Cropped to size: \(croppedImage.size)")
        
        return croppedImage
    }
}

// Dark overlay with circular hole
struct DarkOverlayWithHole: View {
    let holeSize: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Fill the entire area with semi-transparent black
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black.opacity(0.6))
                )
                
                // Cut out a circle in the center
                let centerX = size.width / 2
                let centerY = size.height / 2
                let circleRect = CGRect(
                    x: centerX - holeSize / 2,
                    y: centerY - holeSize / 2,
                    width: holeSize,
                    height: holeSize
                )
                
                context.blendMode = .destinationOut
                context.fill(
                    Path(ellipseIn: circleRect),
                    with: .color(.black)
                )
            }
        }
    }
}

