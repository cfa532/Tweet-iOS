//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation
//

import SwiftUI
import WebKit

struct SimpleVideoPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    
    @State private var isMuted: Bool = PreferenceHelper().getSpeakerMute()
    private let preferenceHelper = PreferenceHelper()
    
    var body: some View {
        ZStack {
            // Web-based player
            WebVideoPlayer(url: url, isMuted: isMuted, autoPlay: autoPlay)
                .onAppear {
                    print("SimpleVideoPlayer: Using web player for \(url.lastPathComponent)")
                }
            
            // Controls overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    // Mute/Unmute button
                    Button(action: toggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20)
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .clipped()
    }
    
    private func toggleMute() {
        isMuted.toggle()
        preferenceHelper.setSpeakerMute(isMuted)
    }
}

// MARK: - Web Video Player
struct WebVideoPlayer: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let autoPlay: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.scrollView.isScrollEnabled = false
        webView.configuration.allowsInlineMediaPlayback = true
        webView.configuration.mediaTypesRequiringUserActionForPlayback = []
        
        // Disable right-click
        let script = WKUserScript(
            source: "document.addEventListener('contextmenu', function(e) { e.preventDefault(); });",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(script)
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Add timestamp to URL to prevent caching issues
        let videoURL = url.absoluteString + "#t=2"
        
        let html = """
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body { margin: 0; background-color: black; }
                .video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                }
                .video-portrait {
                    object-fit: cover;
                }
            </style>
        </head>
        <body>
            <video
                class="video"
                \(autoPlay ? "autoplay" : "")
                controls
                preload="auto"
                \(isMuted ? "muted" : "")
                playsinline
                onloadedmetadata="checkOrientation(this)"
            >
                <source src="\(videoURL)" type="video/mp4">
            </video>
            
            <script>
                function checkOrientation(video) {
                    if (video.videoWidth < video.videoHeight) {
                        video.classList.add('video-portrait');
                    }
                }
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
} 
