#!/bin/bash

# Filter out specific FFmpeg-related linker warnings while preserving other warnings
# This script can be used as a post-build script in Xcode

# Filter out the alignment warning
grep -v "Reducing alignment of section __DATA,__common from 0x8000 to 0x4000 because it exceeds segment maximum alignment" || true

# Exit with success
exit 0 