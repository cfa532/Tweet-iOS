//
//  VideoPlayerTestView.swift
//  Tweet
//
//  Test view for debugging video playback issues
//

import SwiftUI
import AVKit

struct VideoPlayerTestView: View {
    let videoURL: URL
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Video Player Test")
                .font(.title)
                .padding()
            
            // Test with a known working video
            VStack {
                Text("Test Video (Apple Sample)")
                    .font(.headline)
                
                if let testURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8") {
                    SimpleVideoPlayer(url: testURL, autoPlay: false)
                        .frame(height: 200)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal)
            
            // The problematic video
            VStack {
                Text("Your Video")
                    .font(.headline)
                
                SimpleVideoPlayer(url: videoURL, autoPlay: false)
                    .frame(height: 200)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            
            // Debug buttons
            HStack(spacing: 20) {
                Button("Clear All Cache") {
                    VideoDataLoader.shared.clearCache()
                    print("Cleared all video cache")
                }
                .padding()
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
                
                Button("Clear This Video") {
                    VideoDataLoader.shared.clearCacheForURL(videoURL)
                    print("Cleared cache for this video")
                }
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .navigationTitle("Video Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
} 