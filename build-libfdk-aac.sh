#!/bin/sh

# Build script for libfdk_aac for iOS
# This creates a universal binary that can be used with FFmpeg

FDK_AAC_VERSION="2.0.2"
SOURCE="fdk-aac-$FDK_AAC_VERSION"
FAT="fdk-aac-ios"
SCRATCH="scratch"
THIN=`pwd`/"thin"

ARCHS="arm64 x86_64"
DEPLOYMENT_TARGET="12.0"

echo "Building libfdk_aac for iOS..."
echo "Version: $FDK_AAC_VERSION"
echo "Architectures: $ARCHS"

# Download source if not present
if [ ! -r $SOURCE ]; then
    echo "Downloading libfdk_aac source..."
    curl -L https://github.com/mstorsjo/fdk-aac/archive/v$FDK_AAC_VERSION.tar.gz | tar xz
    mv fdk-aac-$FDK_AAC_VERSION $SOURCE
fi

# Install autotools if needed
if [ ! `which autoreconf` ]; then
    echo "Installing autotools..."
    if [ ! `which brew` ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install autoconf automake libtool
fi

# Build for each architecture
CWD=`pwd`
for ARCH in $ARCHS; do
    echo "Building libfdk_aac for $ARCH..."
    mkdir -p "$SCRATCH/$ARCH"
    cd "$SCRATCH/$ARCH"

    CFLAGS="-arch $ARCH"
    if [ "$ARCH" = "x86_64" ]; then
        PLATFORM="iPhoneSimulator"
        CFLAGS="$CFLAGS -mios-simulator-version-min=$DEPLOYMENT_TARGET"
    else
        PLATFORM="iPhoneOS"
        CFLAGS="$CFLAGS -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
    fi

    XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
    CC="xcrun -sdk $XCRUN_SDK clang"
    CXX="xcrun -sdk $XCRUN_SDK clang++"

    # Configure libfdk_aac
    $CWD/$SOURCE/configure \
        --host=arm-apple-darwin \
        --prefix="$THIN/$ARCH" \
        --enable-shared=no \
        --enable-static=yes \
        CC="$CC" \
        CXX="$CXX" \
        CFLAGS="$CFLAGS" \
        CXXFLAGS="$CFLAGS" \
        LDFLAGS="$CFLAGS" || exit 1

    echo "Compiling libfdk_aac for $ARCH..."
    make -j$(sysctl -n hw.ncpu) install || exit 1
    cd $CWD
done

# Create universal binary
echo "Creating universal binary..."
mkdir -p $FAT/lib
mkdir -p $FAT/include

cd $THIN/arm64/lib
for LIB in *.a; do
    if [ -f "$LIB" ]; then
        echo "Creating universal binary for $LIB..."
        lipo -create `find $THIN -name $LIB` -output $FAT/lib/$LIB
    fi
done

cd $CWD
cp -rf $THIN/arm64/include/* $FAT/include/

echo ""
echo "=== libfdk_aac Build Complete ==="
echo "Library location: $FAT"
echo "Include files: $FAT/include"
echo "Library files: $FAT/lib"
echo ""
echo "To use with FFmpeg, set FDK_AAC environment variable:"
echo "export FDK_AAC=$(pwd)/$FAT"
echo ""
echo "Then run FFmpeg build with:"
echo "./build-ffmpeg-hls-minimal.sh with-fdk-aac" 