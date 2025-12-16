#!/bin/bash

echo "🔗 Testing Deeplink..."
echo ""
echo "Make sure the app is running in the simulator first!"
echo ""
read -p "Press Enter to test the custom URL scheme..."

# Test custom URL scheme
xcrun simctl openurl booted "tweet://tweet/y19y5iwAtdbS36IMq6uGnMSH1W6/mwmQCHCEHClCIJy-bItx5ALAhq9"

echo ""
echo "✅ Test command sent!"
echo ""
echo "Check the Xcode console for these logs:"
echo "  - [TweetApp] ✅ SwiftUI onOpenURL received"
echo "  - [AppDelegate] ✅ Received deeplink URL"
echo "  - [ContentView] ✅ Received deeplink notification"
echo "  - [DeeplinkManager] Parsing URL"
