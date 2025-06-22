#!/bin/sh

# FFmpeg iOS Build Script - iOS 16.0 Universal
# Builds for both iOS device and simulator with proper architecture support

# directories
FF_VERSION="6.1"
SOURCE="ffmpeg-$FF_VERSION"
FAT="FFmpeg-iOS"
SCRATCH="scratch"
THIN=`pwd`/"thin"

# Minimal HLS configuration - only what's absolutely necessary
CONFIGURE_FLAGS="--enable-cross-compile --disable-programs --disable-ffplay --disable-ffprobe --disable-ffmpeg --disable-doc --disable-debug --disable-avdevice --enable-pic \
  --enable-encoder=h264 --enable-encoder=aac \
  --enable-decoder=h264 --enable-decoder=aac \
  --enable-demuxer=mov --enable-demuxer=mp4 --enable-demuxer=avi --enable-demuxer=matroska --enable-demuxer=flv --enable-demuxer=mpegts --enable-demuxer=rm \
  --enable-muxer=mp4 --enable-muxer=mpegts --enable-muxer=hls \
  --enable-protocol=file \
  --enable-filter=scale"

# Build for all three architectures: device arm64, simulator arm64, simulator x86_64
ARCHS="arm64 arm64-simulator x86_64"
DEPLOYMENT_TARGET="16.0"

echo "Building universal FFmpeg for iOS 16.0..."
echo "FFmpeg version: $FF_VERSION"
echo "Target iOS version: $DEPLOYMENT_TARGET"
echo "Architectures: $ARCHS"
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

# Build for each architecture
CWD=`pwd`
for ARCH in $ARCHS; do
    echo "Building $ARCH..."
    mkdir -p "$SCRATCH/$ARCH"
    cd "$SCRATCH/$ARCH"

    CFLAGS="-arch $ARCH"
    if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "arm64-simulator" ]; then
        PLATFORM="iPhoneSimulator"
        CFLAGS="$CFLAGS -mios-simulator-version-min=$DEPLOYMENT_TARGET"
    else
        PLATFORM="iPhoneOS"
        CFLAGS="$CFLAGS -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
        if [ "$ARCH" = "arm64" ]; then
            EXPORT="GASPP_FIX_XCODE5=1"
        fi
    fi

    XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
    CC="xcrun -sdk $XCRUN_SDK clang"
    
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "arm64-simulator" ]; then
        AS="gas-preprocessor.pl -arch aarch64 -- $CC"
    else
        AS="gas-preprocessor.pl -- $CC"
    fi

    CXXFLAGS="$CFLAGS"
    LDFLAGS="$CFLAGS"

    echo "Configuring for $ARCH..."
    TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
        --target-os=darwin \
        --arch=$ARCH \
        --cc="$CC" \
        --as="$AS" \
        $CONFIGURE_FLAGS \
        --extra-cflags="$CFLAGS" \
        --extra-ldflags="$LDFLAGS" \
        --prefix="$THIN/$ARCH" || exit 1

    echo "Compiling for $ARCH..."
    make -j$(sysctl -n hw.ncpu) install $EXPORT || exit 1
    cd $CWD
done

# Create universal binaries
echo "Creating universal binaries..."
mkdir -p $FAT/lib

# Only the essential libraries for HLS
ESSENTIAL_LIBS="libavcodec.a libavformat.a libavutil.a libswscale.a libswresample.a"

for LIB in $ESSENTIAL_LIBS; do
    if [ -f "thin/arm64/lib/$LIB" ]; then
        echo "Creating universal binary for $LIB..."
        # Create universal binary with all three architectures
        lipo -create thin/arm64/lib/$LIB thin/arm64-simulator/lib/$LIB thin/x86_64/lib/$LIB -output $FAT/lib/$LIB
    fi
done

cd $CWD
cp -rf thin/arm64/include $FAT

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