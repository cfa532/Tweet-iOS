#!/bin/bash

# Build Debug Version Script
# This script builds a debug version of Tweet that won't overwrite your production app

echo "🔨 Building M2O Debug Version..."
echo "📱 This will create a separate app called 'M2O' with bundle ID: com.example.Tweet.debug"
echo ""

# Clean build folder
echo "🧹 Cleaning build folder..."
xcodebuild clean -workspace Tweet.xcworkspace -scheme Tweet -configuration Debug

# Build for device (Debug configuration)
echo "📦 Building for device (Debug configuration)..."
xcodebuild archive \
    -workspace Tweet.xcworkspace \
    -scheme Tweet \
    -configuration Debug \
    -archivePath "build/Tweet-Debug.xcarchive" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER=""

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Debug build completed successfully!"
    echo "📱 App name: M2O"
    echo "🆔 Bundle ID: com.example.Tweet.debug"
    echo "📁 Archive location: build/Tweet-Debug.xcarchive"
    echo ""
    echo "To install on your device:"
    echo "1. Open Xcode"
    echo "2. Go to Window > Organizer"
    echo "3. Select the Tweet-Debug.xcarchive"
    echo "4. Click 'Distribute App' > 'Development'"
    echo "5. Select your device and install"
    echo ""
    echo "This debug version will install alongside your production Tweet app!"
else
    echo ""
    echo "❌ Build failed. Please check the error messages above."
    exit 1
fi
