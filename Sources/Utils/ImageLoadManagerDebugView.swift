//
//  ImageLoadManagerDebugView.swift
//  Tweet
//
//  Debug view for monitoring GlobalImageLoadManager
//

import SwiftUI

struct ImageLoadManagerDebugView: View {
    @StateObject private var imageManager = GlobalImageLoadManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image Load Manager Status")
                .font(.headline)
                .padding(.bottom, 4)
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Loads: \(imageManager.activeLoadCount)")
                        .foregroundColor(.blue)
                    Text("Pending Loads: \(imageManager.pendingLoadCount)")
                        .foregroundColor(.orange)
                    Text("Completed: \(imageManager.completedLoadCount)")
                        .foregroundColor(.green)
                    Text("Retries: \(imageManager.retryCount)")
                        .foregroundColor(.orange)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    Button("Clear History") {
                        imageManager.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Cancel Low Priority") {
                        imageManager.cancelLoads(priority: .low)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Divider()
            
            Text("Memory Management")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Text("• Max concurrent loads: 8")
            Text("• Max queue size: 100")
            Text("• Memory warning threshold: 80%")
            
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

#Preview {
    ImageLoadManagerDebugView()
        .padding()
}
