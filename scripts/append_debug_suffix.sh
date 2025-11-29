#!/bin/bash

# Script to append "d" to CFBundleDisplayName in InfoPlist.strings for debug builds
# This allows localized app names to have "d" suffix in debug builds

PROJECT_DIR="${SRCROOT}/Tweet"

if [ "${CONFIGURATION}" == "Debug" ]; then
    # Debug build: Append "d" to app names
    for LOC_DIR in "${PROJECT_DIR}"/*.lproj; do
        if [ -d "${LOC_DIR}" ]; then
            INFOPLIST_FILE="${LOC_DIR}/InfoPlist.strings"
            
            if [ -f "${INFOPLIST_FILE}" ]; then
                # Check if CFBundleDisplayName exists and doesn't already end with "d"
                if grep -q "CFBundleDisplayName" "${INFOPLIST_FILE}" && ! grep -q 'CFBundleDisplayName = ".*d";' "${INFOPLIST_FILE}"; then
                    # Append "d" to the value before the closing quote
                    sed -i '' 's/\(CFBundleDisplayName = "\)\([^"]*\)\(";\)/\1\2d\3/g' "${INFOPLIST_FILE}"
                    echo "Updated ${INFOPLIST_FILE} for debug build"
                fi
            fi
        fi
    done
else
    # Release build: Remove "d" suffix if present (restore original names)
    for LOC_DIR in "${PROJECT_DIR}"/*.lproj; do
        if [ -d "${LOC_DIR}" ]; then
            INFOPLIST_FILE="${LOC_DIR}/InfoPlist.strings"
            
            if [ -f "${INFOPLIST_FILE}" ]; then
                # Check if CFBundleDisplayName ends with "d" and remove it
                if grep -q 'CFBundleDisplayName = ".*d";' "${INFOPLIST_FILE}"; then
                    # Remove "d" before the closing quote
                    sed -i '' 's/\(CFBundleDisplayName = "\)\([^"]*\)d\(";\)/\1\2\3/g' "${INFOPLIST_FILE}"
                    echo "Restored ${INFOPLIST_FILE} for release build"
                fi
            fi
        fi
    done
fi

exit 0

