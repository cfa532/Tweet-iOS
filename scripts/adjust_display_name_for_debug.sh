#!/bin/bash

# Script to conditionally remove CFBundleDisplayName from InfoPlist.strings for Debug builds
# This allows Debug to use the build setting "M2O" while Release uses localized names
# The script modifies copies in the app bundle, not source files

if [ "${CONFIGURATION}" == "Debug" ]; then
    echo "Debug build - removing CFBundleDisplayName from InfoPlist.strings to use build setting 'M2O'"
    
    # Find and modify InfoPlist.strings in the app bundle
    APP_BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
    RESOURCE_PATH="${APP_BUNDLE}"
    
    if [ -d "${RESOURCE_PATH}" ]; then
        # Find all InfoPlist.strings files in the bundle (including .lproj subdirectories)
        find "${RESOURCE_PATH}" -name "InfoPlist.strings" -type f | while read file; do
            echo "Processing: $file"
            
            # Convert binary plist to XML, remove CFBundleDisplayName, convert back to binary
            if plutil -convert xml1 "$file" -o "${file}.xml" 2>/dev/null; then
                # Remove the CFBundleDisplayName key and its value from XML
                sed -i '' '/<key>CFBundleDisplayName<\/key>/,/<\/string>/d' "${file}.xml"
                # Convert back to binary plist
                plutil -convert binary1 "${file}.xml" -o "$file"
                rm "${file}.xml"
                echo "  ✓ Removed CFBundleDisplayName from: $file"
            else
                echo "  ✗ Failed to process: $file"
            fi
        done
    fi
else
    echo "Release build - keeping CFBundleDisplayName in InfoPlist.strings for localization"
fi

