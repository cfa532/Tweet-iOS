//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation
//

import SwiftUI
import WebKit

// Global mute state
class MuteState: ObservableObject {
    static let shared = MuteState()
    @Published var isMuted: Bool {
        didSet {
            PreferenceHelper().setSpeakerMute(isMuted)
        }
    }
    init() {
        self.isMuted = PreferenceHelper().getSpeakerMute()
    }
}

struct SimpleVideoPlayer: View {
    let url: URL
    var autoPlay: Bool = true
    @EnvironmentObject var muteState: MuteState
    var onTimeUpdate: ((Double) -> Void)? = nil
    var isMuted: Bool? = nil
    var onMuteChanged: ((Bool) -> Void)? = nil
    
    var body: some View {
        WebVideoPlayer(
            url: url,
            autoPlay: autoPlay,
            isMuted: isMuted ?? muteState.isMuted,
            onMuteChanged: { muted in
                if let onMuteChanged = onMuteChanged {
                    onMuteChanged(muted)
                } else {
                    muteState.isMuted = muted
                }
            },
            onTimeUpdate: onTimeUpdate
        )
        .onAppear {
            print("SimpleVideoPlayer: Using web player for \(url.lastPathComponent)")
        }
    }
}

// MARK: - Web Video Player
struct WebVideoPlayer: UIViewRepresentable {
    let url: URL
    let autoPlay: Bool
    let isMuted: Bool
    let onMuteChanged: (Bool) -> Void
    let onTimeUpdate: ((Double) -> Void)?
    // Static reference for fullscreen mute control
    static weak var lastFullScreenWebView: WKWebView?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onMuteChanged: onMuteChanged, onTimeUpdate: onTimeUpdate)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        // Configure for inline playback
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        
        // Add message handler for mute state changes and time updates
        configuration.userContentController.add(context.coordinator, name: "muteStateChanged")
        configuration.userContentController.add(context.coordinator, name: "timeUpdate")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.scrollView.isScrollEnabled = false
        
        // Disable right-click
        let script = WKUserScript(
            source: "document.addEventListener('contextmenu', function(e) { e.preventDefault(); });",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(script)
        
        // Store static reference for fullscreen
        WebVideoPlayer.lastFullScreenWebView = webView
        context.coordinator.webView = webView
        context.coordinator.lastLoadedURL = nil // force initial load
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload HTML if the URL has changed
        let videoURL = url.absoluteString + "#t=2"
        if context.coordinator.lastLoadedURL != videoURL {
            let html = """
            <html>
            <head>
                <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no\">
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
                    class=\"video\"
                    \(autoPlay ? "autoplay" : "")
                    controls
                    preload=\"auto\"
                    playsinline
                    webkit-playsinline
                    x-webkit-airplay=\"allow\"
                    onloadedmetadata=\"checkOrientation(this)\"
                    \(isMuted ? "muted" : "")
                    ontimeupdate=\"window.reportTime(this.currentTime)\"
                >
                    <source src=\"\(videoURL)\" type=\"video/mp4\">
                </video>
                <script>
                    function checkOrientation(video) {
                        if (video.videoWidth < video.videoHeight) {
                            video.classList.add('video-portrait');
                        }
                    }
                    // Listen for mute/unmute events
                    document.querySelector('video').addEventListener('volumechange', function(e) {
                        const isMuted = e.target.muted;
                        window.webkit.messageHandlers.muteStateChanged.postMessage(isMuted);
                    });
                    // React to mute state from Swift
                    window.setMute = function(muted) {
                        document.querySelector('video').muted = muted;
                    }
                    // Report time to Swift
                    window.reportTime = function(currentTime) {
                        window.webkit.messageHandlers.timeUpdate.postMessage(currentTime);
                    }
                </script>
            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            context.coordinator.lastLoadedURL = videoURL
        }
        // Always update mute state via JS (no reload)
        let js = "window.setMute(\(isMuted ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    static func updateMuteExternally(isMuted: Bool) {
        let js = "window.setMute(\(isMuted ? "true" : "false"));"
        lastFullScreenWebView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        let onMuteChanged: (Bool) -> Void
        let onTimeUpdate: ((Double) -> Void)?
        weak var webView: WKWebView?
        var lastLoadedURL: String?
        init(onMuteChanged: @escaping (Bool) -> Void, onTimeUpdate: ((Double) -> Void)?) {
            self.onMuteChanged = onMuteChanged
            self.onTimeUpdate = onTimeUpdate
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "muteStateChanged", let isMuted = message.body as? Bool {
                onMuteChanged(isMuted)
            } else if message.name == "timeUpdate" {
                if let time = message.body as? Double {
                    onTimeUpdate?(time)
                } else if let timeStr = message.body as? String, let time = Double(timeStr) {
                    onTimeUpdate?(time)
                }
            }
        }
    }
} 
