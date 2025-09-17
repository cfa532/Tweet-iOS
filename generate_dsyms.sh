#!/bin/bash

# Script to generate dSYM files for FFmpeg frameworks
# Add this as a "Run Script" phase in Xcode Build Phases

echo "Generating dSYM files for FFmpeg frameworks..."

# Get the build directory and dSYM directory
BUILD_DIR="${BUILD_DIR}"
DSYM_DIR="${DWARF_DSYM_FOLDER_PATH}"
CONFIGURATION="${CONFIGURATION}"

echo "Build directory: ${BUILD_DIR}"
echo "dSYM directory: ${DSYM_DIR}"
echo "Configuration: ${CONFIGURATION}"

# Create dSYM directory if it doesn't exist
mkdir -p "${DSYM_DIR}"

# Find FFmpeg frameworks in the build directory
echo "Searching for FFmpeg frameworks..."

# Look for FFmpeg frameworks in various possible locations
FFMPEG_FRAMEWORKS=()

# Check in the main build directory
for framework in "${BUILD_DIR}"/*.framework; do
    if [ -d "${framework}" ]; then
        framework_name=$(basename "${framework}")
        if [[ "${framework_name}" == *"ffmpeg"* ]] || [[ "${framework_name}" == *"av"* ]] || [[ "${framework_name}" == *"sw"* ]]; then
            FFMPEG_FRAMEWORKS+=("${framework}")
            echo "Found FFmpeg framework: ${framework_name}"
        fi
    fi
done

# Also check in Pods directory for xcframework structures
PODS_DIR="${SRCROOT}/Pods"
if [ -d "${PODS_DIR}" ]; then
    # Look for xcframework structures
    for xcframework in "${PODS_DIR}"/*/Frameworks/*.xcframework; do
        if [ -d "${xcframework}" ]; then
            xcframework_name=$(basename "${xcframework}")
            if [[ "${xcframework_name}" == *"ffmpeg"* ]] || [[ "${xcframework_name}" == *"av"* ]] || [[ "${xcframework_name}" == *"sw"* ]]; then
                # Look for device frameworks within the xcframework
                for platform_dir in "${xcframework}"/*; do
                    if [ -d "${platform_dir}" ]; then
                        for framework in "${platform_dir}"/*.framework; do
                            if [ -d "${framework}" ]; then
                                FFMPEG_FRAMEWORKS+=("${framework}")
                                echo "Found FFmpeg framework in xcframework: $(basename "${framework}")"
                            fi
                        done
                    fi
                done
            fi
        fi
    done
fi

# Generate dSYM for each found framework
for framework_path in "${FFMPEG_FRAMEWORKS[@]}"; do
    if [ -d "${framework_path}" ]; then
        framework_name=$(basename "${framework_path}")
        binary_name=$(basename "${framework_path}" .framework)
        binary_path="${framework_path}/${binary_name}"
        
        echo "Processing ${framework_name}..."
        
        if [ -f "${binary_path}" ]; then
            # Create dSYM bundle
            dsym_bundle="${DSYM_DIR}/${binary_name}.dSYM"
            mkdir -p "${dsym_bundle}/Contents/Resources/DWARF"
            
            # Create Info.plist for the dSYM bundle
            cat > "${dsym_bundle}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.apple.xcode.dsym.${binary_name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${binary_name}</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
            
            # Copy the binary to the dSYM bundle
            cp "${binary_path}" "${dsym_bundle}/Contents/Resources/DWARF/"
            echo "Generated dSYM for ${framework_name}"
        else
            echo "Warning: Binary not found for ${framework_name} at ${binary_path}"
        fi
    fi
done

echo "dSYM generation completed. Found ${#FFMPEG_FRAMEWORKS[@]} FFmpeg frameworks."
