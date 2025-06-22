#!/bin/sh

# FFmpeg iOS Build Script - iOS 16.0 Simple Universal
# Builds for both iOS device and simulator

# directories
FF_VERSION="6.1"
SOURCE="ffmpeg-$FF_VERSION"
FAT="FFmpeg-iOS"
SCRATCH="scratch"

# Minimal HLS configuration
CONFIGURE_FLAGS="--enable-cross-compile --disable-programs --disable-ffplay --disable-ffprobe --disable-ffmpeg --disable-doc --disable-debug --disable-avdevice --enable-pic \
  --enable-encoder=h264 --enable-encoder=aac \
  --enable-decoder=h264 --enable-decoder=aac \
  --enable-demuxer=mov --enable-demuxer=mp4 --enable-demuxer=avi --enable-demuxer=matroska --enable-demuxer=flv --enable-demuxer=mpegts --enable-demuxer=rm \
  --enable-muxer=mp4 --enable-muxer=mpegts --enable-muxer=hls \
  --enable-protocol=file \
  --enable-filter=scale"

DEPLOYMENT_TARGET="16.0"

echo "Building universal FFmpeg for iOS 16.0..."
echo "FFmpeg version: $FF_VERSION"
echo "Target iOS version: $DEPLOYMENT_TARGET"
echo "Features: Built-in H.264 encoding, Built-in AAC encoding, MP4/M3U8/TS formats only"

# Install dependencies
if [ ! `which yasm` ]; then
    echo "Installing yasm..."
    if [ ! `which brew` ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install yasm
fi

if [ ! `which gas-preprocessor.pl` ]; then
    echo "Installing gas-preprocessor..."
    curl -L https://github.com/libav/gas-preprocessor/raw/master/gas-preprocessor.pl \
        -o /usr/local/bin/gas-preprocessor.pl && chmod +x /usr/local/bin/gas-preprocessor.pl
fi

# Download FFmpeg source
if [ ! -r $SOURCE ]; then
    echo "Downloading FFmpeg source version $FF_VERSION..."
    curl -L http://www.ffmpeg.org/releases/$SOURCE.tar.bz2 | tar xj
fi

# Build for iOS device (arm64)
echo "Building for iOS device (arm64)..."
mkdir -p "$SCRATCH/arm64"
cd "$SCRATCH/arm64"

CFLAGS="-arch arm64 -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
CC="xcrun -sdk iphoneos clang"
AS="gas-preprocessor.pl -arch aarch64 -- $CC"
CXXFLAGS="$CFLAGS"
LDFLAGS="$CFLAGS"
EXPORT="GASPP_FIX_XCODE5=1"

echo "Configuring for iOS device (arm64)..."
TMPDIR=${TMPDIR/%\/} ../../$SOURCE/configure \
    --target-os=darwin \
    --arch=arm64 \
    --cc="$CC" \
    --as="$AS" \
    $CONFIGURE_FLAGS \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    --prefix="." || exit 1

echo "Compiling for iOS device (arm64)..."
make -j$(sysctl -n hw.ncpu) install $EXPORT || exit 1
cd ../..

# Build for iOS simulator (x86_64)
echo "Building for iOS simulator (x86_64)..."
mkdir -p "$SCRATCH/x86_64"
cd "$SCRATCH/x86_64"

CFLAGS="-arch x86_64 -mios-simulator-version-min=$DEPLOYMENT_TARGET"
CC="xcrun -sdk iphonesimulator clang"
AS="gas-preprocessor.pl -- $CC"
CXXFLAGS="$CFLAGS"
LDFLAGS="$CFLAGS"

echo "Configuring for iOS simulator (x86_64)..."
TMPDIR=${TMPDIR/%\/} ../../$SOURCE/configure \
    --target-os=darwin \
    --arch=x86_64 \
    --cc="$CC" \
    --as="$AS" \
    $CONFIGURE_FLAGS \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    --prefix="." || exit 1

echo "Compiling for iOS simulator (x86_64)..."
make -j$(sysctl -n hw.ncpu) install || exit 1
cd ../..

# Build for iOS simulator (arm64)
echo "Building for iOS simulator (arm64)..."
mkdir -p "$SCRATCH/arm64-sim"
cd "$SCRATCH/arm64-sim"

CFLAGS="-arch arm64 -mios-simulator-version-min=$DEPLOYMENT_TARGET"
CC="xcrun -sdk iphonesimulator clang"
AS="gas-preprocessor.pl -arch aarch64 -- $CC"
CXXFLAGS="$CFLAGS"
LDFLAGS="$CFLAGS"

echo "Configuring for iOS simulator (arm64)..."
TMPDIR=${TMPDIR/%\/} ../../$SOURCE/configure \
    --target-os=darwin \
    --arch=arm64 \
    --cc="$CC" \
    --as="$AS" \
    $CONFIGURE_FLAGS \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    --prefix="." || exit 1

echo "Compiling for iOS simulator (arm64)..."
make -j$(sysctl -n hw.ncpu) install || exit 1
cd ../..

# Create universal binaries
echo "Creating universal binaries..."
mkdir -p $FAT/lib $FAT/include

# Only the essential libraries for HLS
ESSENTIAL_LIBS="libavcodec.a libavformat.a libavutil.a libswscale.a libswresample.a"

for LIB in $ESSENTIAL_LIBS; do
    if [ -f "scratch/arm64/lib/$LIB" ]; then
        echo "Creating universal binary for $LIB..."
        # Create universal binary with all three architectures
        lipo -create scratch/arm64/lib/$LIB scratch/arm64-sim/lib/$LIB scratch/x86_64/lib/$LIB -output $FAT/lib/$LIB
    fi
done

# Copy headers from device build
cp -rf scratch/arm64/include/* $FAT/include/

echo ""
echo "=== Universal FFmpeg Build Complete ==="
echo "FFmpeg version: $FF_VERSION"
echo "Target iOS version: $DEPLOYMENT_TARGET"
echo "Libraries included: $ESSENTIAL_LIBS"
echo "Framework location: $FAT"
echo ""
echo "For Xcode integration:"
echo "1. Add $FAT/lib to Library Search Paths"
echo "2. Add $FAT/include to Header Search Paths"
echo "3. Add these linker flags: -lavformat -lavcodec -lavutil -lswscale -lswresample -lz -lm -lpthread"
echo "4. Set Enable Bitcode to No"
echo "5. Set iOS Deployment Target to $DEPLOYMENT_TARGET or higher"
echo ""
echo "This build includes support for both iOS device and simulator!" 