//
//  LocalHTTPServerWrapper.swift
//  Tweet
//
//  Wrapper for LocalHTTPServer from CachingPlayerItem pod
//

import Foundation
import CachingPlayerItem

class LocalHTTPServerWrapper {
    static let shared = LocalHTTPServerWrapper()
    
    private init() {}
    
    func start() {
        LocalHTTPServer.shared.start()
    }
    
    func registerMedia(mediaID: String, cachePath: String) {
        LocalHTTPServer.shared.registerMedia(mediaID: mediaID, cachePath: cachePath)
    }
    
    func getLocalURL(for mediaID: String) -> URL? {
        return LocalHTTPServer.shared.getLocalURL(for: mediaID)
    }
}
