//
//  ScreenDimensions.swift
//  Tweet
//
//  Created for performance optimization
//

import SwiftUI

/// Cached screen dimensions to avoid repeated UIScreen.main.bounds calls
/// which can cause performance issues when rendering many views
@MainActor
class ScreenDimensions: ObservableObject {
    static let shared = ScreenDimensions()
    
    @Published private(set) var width: CGFloat
    @Published private(set) var height: CGFloat
    
    // Standard horizontal padding used in tweet layouts
    let horizontalPadding: CGFloat = 32
    
    // Pre-calculated grid width (screen width - padding)
    var gridWidth: CGFloat {
        max(10, width - horizontalPadding)
    }
    
    private init() {
        let bounds = UIScreen.main.bounds
        self.width = bounds.width
        self.height = bounds.height
        
        // Listen for orientation changes
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDimensions()
        }
    }
    
    private func updateDimensions() {
        let bounds = UIScreen.main.bounds
        self.width = bounds.width
        self.height = bounds.height
    }
}

/// Environment key for screen dimensions
struct ScreenDimensionsKey: EnvironmentKey {
    static let defaultValue = ScreenDimensions.shared
}

extension EnvironmentValues {
    var screenDimensions: ScreenDimensions {
        get { self[ScreenDimensionsKey.self] }
        set { self[ScreenDimensionsKey.self] = newValue }
    }
}

