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
            echo "Modifying: $file"
            # Remove CFBundleDisplayName lines (including lines with just whitespace before)
            sed -i '' '/^[[:space:]]*CFBundleDisplayName[[:space:]]*=/d' "$file" 2>/dev/null || \
            sed -i '/^[[:space:]]*CFBundleDisplayName[[:space:]]*=/d' "$file"
        done
    fi
else
    echo "Release build - keeping CFBundleDisplayName in InfoPlist.strings for localization"
fi

