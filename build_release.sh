#!/bin/bash

# Build Release Version Script
# This script builds a release version of Tweet for installation on device

echo "🔨 Building Tweet Release Version..."
echo ""

# Clean build folder
echo "🧹 Cleaning build folder..."
xcodebuild clean -workspace Tweet.xcworkspace -scheme Tweet -configuration Release

# Build for device (Release configuration)
echo "📦 Building for device (Release configuration)..."
xcodebuild archive \
    -workspace Tweet.xcworkspace \
    -scheme Tweet \
    -configuration Release \
    -archivePath "build/Tweet-Release.xcarchive" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="96LBXG78A7"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Release build completed successfully!"
    echo "📁 Archive location: build/Tweet-Release.xcarchive"
    echo ""
    echo "📱 Installing on connected iPhone..."
    echo ""
    
    # Create export options plist for development distribution
    cat > build/ExportOptions.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>96LBXG78A7</string>
    <key>compileBitcode</key>
    <false/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>thinning</key>
    <string>&lt;none&gt;</string>
</dict>
</plist>
EOF

    # Export the archive
    echo "📤 Exporting IPA..."
    xcodebuild -exportArchive \
        -archivePath "build/Tweet-Release.xcarchive" \
        -exportPath "build/Release-iphoneos" \
        -exportOptionsPlist "build/ExportOptions.plist"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Export completed successfully!"
        echo "📦 IPA location: build/Release-iphoneos/Tweet.ipa"
        echo ""
        echo "🚀 Installing to connected device..."
        
        # Try to install using xcrun
        if [ -f "build/Release-iphoneos/Tweet.ipa" ]; then
            xcrun devicectl device install app --device $(xcrun devicectl list devices | grep -m 1 "iPhone" | awk '{print $3}') "build/Release-iphoneos/Tweet.ipa" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "✅ App installed successfully on iPhone!"
            else
                echo "⚠️  Automatic installation failed. Please install manually:"
                echo "   1. Connect your iPhone"
                echo "   2. Open Xcode > Window > Devices and Simulators"
                echo "   3. Select your device"
                echo "   4. Drag build/Release-iphoneos/Tweet.ipa to the 'Installed Apps' section"
            fi
        fi
    else
        echo ""
        echo "❌ Export failed. Trying alternative installation method..."
        echo ""
        echo "Please install manually:"
        echo "1. Open Xcode > Window > Organizer"
        echo "2. Select the Tweet-Release.xcarchive"
        echo "3. Click 'Distribute App' > 'Development'"
        echo "4. Follow the wizard to install on your connected device"
    fi
else
    echo ""
    echo "❌ Build failed. Please check the error messages above."
    exit 1
fi

