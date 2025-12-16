#!/usr/bin/env swift

import Foundation

// Test URL parsing logic
let testURLs = [
    "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9",
    "http://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9",
    "https://fireshare.us/tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"
]

for urlString in testURLs {
    if let url = URL(string: urlString) {
        print("\nTesting: \(urlString)")
        print("  Scheme: \(url.scheme ?? "nil")")
        print("  Host: \(url.host ?? "nil")")
        print("  Path: \(url.path)")
        print("  Path components: \(url.pathComponents.filter { $0 != "/" })")
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if pathComponents.count >= 2 && pathComponents[0] == "tweet" {
            let tweetId = pathComponents[1]
            let authorId = pathComponents.count >= 3 ? pathComponents[2] : ""
            print("  ✅ Parsed: tweetId=\(tweetId), authorId=\(authorId)")
        } else {
            print("  ❌ Could not parse")
        }
    }
}
