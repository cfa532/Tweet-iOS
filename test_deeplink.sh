#!/bin/bash

# Deeplink Testing Script
# Usage: ./test_deeplink.sh [simulator|device]

MODE=${1:-simulator}
TWEET_ID="y19y5iwAtdbS36IMq6uGnMSH1W6"
AUTHOR_ID="mwmQCHCEHClCIJy-bItx5ALAhq9"

echo "Testing Deeplinks..."
echo "Tweet ID: $TWEET_ID"
echo "Author ID: $AUTHOR_ID"
echo ""

if [ "$MODE" == "simulator" ]; then
    echo "Testing on Simulator..."
    echo ""
    
    echo "1. Testing custom URL scheme..."
    xcrun simctl openurl booted "tweet://tweet/$TWEET_ID/$AUTHOR_ID"
    sleep 2
    
    echo "2. Testing HTTP URL..."
    xcrun simctl openurl booted "http://fireshare.us/tweet/$TWEET_ID/$AUTHOR_ID"
    sleep 2
    
    echo "3. Testing HTTPS URL..."
    xcrun simctl openurl booted "https://fireshare.us/tweet/$TWEET_ID/$AUTHOR_ID"
    
    echo ""
    echo "Done! Check the simulator and app logs for results."
else
    echo "For device testing:"
    echo "1. Open Safari on your device"
    echo "2. Navigate to: http://fireshare.us/tweet/$TWEET_ID/$AUTHOR_ID"
    echo "3. Or use custom scheme: tweet://tweet/$TWEET_ID/$AUTHOR_ID"
fi
