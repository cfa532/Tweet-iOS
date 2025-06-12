import SwiftUI
import WebKit

public struct WebVideoPlayer: UIViewRepresentable {
    let url: URL
    let isMuted: Bool
    let autoPlay: Bool
    
    public init(url: URL, isMuted: Bool, autoPlay: Bool) {
        self.url = url
        self.isMuted = isMuted
        self.autoPlay = autoPlay
    }
    
    public func makeUIView(context: Context) -> WKWebView {
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
    
    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Add timestamp to URL to prevent caching issues
        let videoURL = url.absoluteString + "#t=3"
        
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