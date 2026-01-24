//
//  VideoPlayerProtocols.swift
//  Tweet
//
//  Created by Assistant on 2026-01-23.
//  Shared protocols for video player components
//

import AVFoundation

// MARK: - Video Player Container Protocol

/// Protocol for video player container views
public protocol VideoPlayerContainerProtocol: AnyObject {
    var videoId: String? { get set }
    func assignPlayer(_ player: AVPlayer, for videoId: String)
    func removePlayer()
    func viewDidAppear()
    func viewDidDisappear()
}