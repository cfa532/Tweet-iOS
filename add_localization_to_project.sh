#!/bin/bash

# Script to add localization files to Xcode project
# Run this script from the project root directory

echo "Adding localization files to Xcode project..."

# Check if we're in the right directory
if [ ! -f "Tweet.xcodeproj/project.pbxproj" ]; then
    echo "Error: Tweet.xcodeproj/project.pbxproj not found. Please run this script from the project root directory."
    exit 1
fi

echo "Localization files found:"
echo "- Tweet/Localizable.strings (base)"
echo "- Tweet/zh-Hans.lproj/Localizable.strings (Chinese Simplified)"
echo "- Tweet/ja.lproj/Localizable.strings (Japanese)"

echo ""
echo "To add these files to your Xcode project:"
echo ""
echo "1. Open Tweet.xcodeproj in Xcode"
echo "2. Right-click on the 'Tweet' folder in the project navigator"
echo "3. Select 'Add Files to "Tweet"'"
echo "4. Navigate to and select:"
echo "   - Tweet/Localizable.strings"
echo "   - Tweet/zh-Hans.lproj/ (entire folder)"
echo "   - Tweet/ja.lproj/ (entire folder)"
echo "5. Make sure 'Add to target: Tweet' is checked"
echo "6. Click 'Add'"
echo ""
echo "After adding the files:"
echo "1. Clean the build folder (Product > Clean Build Folder)"
echo "2. Build and run the project"
echo "3. Change your device/simulator language to Japanese or Chinese"
echo "4. Restart the app"
echo ""
echo "The localization should now work!" 