#!/bin/bash

# Check if source image exists
if [ ! -f "2birds1024.png" ]; then
    echo "Error: Icon.png not found"
    exit 1
fi

# Generate iPhone icons
sips -z 40 40 2birds1024.png --out Icon-iPhone-20@2x.png
sips -z 60 60 2birds1024.png --out Icon-iPhone-20@3x.png
sips -z 58 58 2birds1024.png --out Icon-iPhone-29@2x.png
sips -z 87 87 2birds1024.png --out Icon-iPhone-29@3x.png
sips -z 80 80 2birds1024.png --out Icon-iPhone-40@2x.png
sips -z 120 120 2birds1024.png --out Icon-iPhone-40@3x.png
sips -z 120 120 2birds1024.png --out Icon-iPhone-60@2x.png
sips -z 180 180 2birds1024.png --out Icon-iPhone-60@3x.png

# Generate iPad icons
sips -z 20 20 2birds1024.png --out Icon-iPad-20@1x.png
sips -z 40 40 2birds1024.png --out Icon-iPad-20@2x.png
sips -z 29 29 2birds1024.png --out Icon-iPad-29@1x.png
sips -z 58 58 2birds1024.png --out Icon-iPad-29@2x.png
sips -z 40 40 2birds1024.png --out Icon-iPad-40@1x.png
sips -z 80 80 2birds1024.png --out Icon-iPad-40@2x.png
sips -z 76 76 2birds1024.png --out Icon-iPad-76@1x.png
sips -z 152 152 2birds1024.png --out Icon-iPad-76@2x.png
sips -z 167 167 2birds1024.png --out Icon-iPad-83.5@2x.png

echo "All icons generated successfully!" 
