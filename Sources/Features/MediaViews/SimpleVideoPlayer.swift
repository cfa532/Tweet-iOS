//
//  SimpleVideoPlayer.swift
//  Tweet
//
//  A simpler video player implementation
//

import SwiftUI
import WebKit
import CryptoKit

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

// MARK: - Video Cache Manager
class VideoCacheManager {
    static let shared = VideoCacheManager()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds
    
    private init() {
        // Get the cache directory
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("VideoCache")
        
        // Create cache directory if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func cleanupOldCache() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            let now = Date()
            
            for fileURL in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modificationDate = attributes[.modificationDate] as? Date {
                    if now.timeIntervalSince(modificationDate) > maxCacheAge {
                        try? fileManager.removeItem(at: fileURL)
                    }
                }
            }
        } catch {
            print("Error cleaning up video cache: \(error)")
        }
    }
    
    private func getCacheKey(for url: URL) -> String {
        return url.lastPathComponent
    }
    
    private func getCacheFileURL(for key: String) -> URL {
        return cacheDirectory.appendingPathComponent(key)
    }
    
    func getCachedVideoURL(for url: URL) -> URL? {
        let key = getCacheKey(for: url)
        let fileURL = getCacheFileURL(for: key)
        
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }
    
    func cacheVideo(from url: URL) async {
        let key = getCacheKey(for: url)
        let fileURL = getCacheFileURL(for: key)
        
        // Skip if already cached
        if fileManager.fileExists(atPath: fileURL.path) {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: fileURL)
        } catch {
            print("Error caching video: \(error)")
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
        let videoURL = url.absoluteString
        
        if context.coordinator.lastLoadedURL != videoURL {
            // Start caching the video
            Task {
                await VideoCacheManager.shared.cacheVideo(from: url)
            }
            
            // Try to use cached video if available
            let videoSource: String
            if let cachedURL = VideoCacheManager.shared.getCachedVideoURL(for: url),
               let data = try? Data(contentsOf: cachedURL) {
                // Convert cached video to base64 data URL
                let base64 = data.base64EncodedString()
                videoSource = "data:video/mp4;base64,\(base64)"
            } else {
                videoSource = videoURL
            }
            
            let html = """
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
                <style>
                    body { margin: 0; background-color: black; }
                    video { 
                        width: 100%; 
                        height: 100%; 
                        object-fit: contain;
                        background-color: black;
                    }
                </style>
            </head>
            <body>
                <video
                    id="videoPlayer"
                    \(autoPlay ? "autoplay" : "")
                    controls
                    playsinline
                    webkit-playsinline
                    \(isMuted ? "muted" : "")
                    ontimeupdate="window.webkit.messageHandlers.timeUpdate.postMessage(this.currentTime)"
                    preload="metadata"
                >
                    <source src="\(videoSource)" type="video/mp4">
                </video>
                <script>
                    document.querySelector('video').addEventListener('volumechange', function(e) {
                        window.webkit.messageHandlers.muteStateChanged.postMessage(e.target.muted);
                    });
                    window.setMute = function(muted) {
                        document.querySelector('video').muted = muted;
                    }
                </script>
            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            context.coordinator.lastLoadedURL = videoURL
        }
        
        // Update mute state
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
            } else if message.name == "timeUpdate", let time = message.body as? Double {
                onTimeUpdate?(time)
            }
        }
    }
} 
