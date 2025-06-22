#!/bin/sh

# FFmpeg iOS Build Script - iOS 15.0 Compatible
# Optimized for iOS 15.0 deployment target

# directories
FF_VERSION="4.3.1"
if [[ $FFMPEG_VERSION != "" ]]; then
  FF_VERSION=$FFMPEG_VERSION
fi
SOURCE="ffmpeg-$FF_VERSION"
FAT="FFmpeg-iOS"

SCRATCH="scratch"
THIN=`pwd`/"thin"

# HLS-optimized configuration flags for iOS 15.0
CONFIGURE_FLAGS="--enable-cross-compile --disable-debug --disable-programs \
                 --disable-doc --enable-pic \
                 --enable-gpl --enable-libx264 --enable-libfdk-aac --enable-nonfree \
                 --enable-encoder=libx264 --enable-encoder=aac \
                 --enable-decoder=h264 --enable-decoder=aac \
                 --enable-demuxer=mov --enable-demuxer=m4v --enable-demuxer=mp4 \
                 --enable-muxer=mp4 --enable-muxer=mpegts --enable-muxer=hls \
                 --enable-protocol=file --enable-protocol=http --enable-protocol=https \
                 --enable-filter=scale --enable-filter=resample \
                 --disable-avdevice --disable-postproc --disable-swresample \
                 --disable-avfilter --disable-network --disable-encoders \
                 --disable-decoders --disable-muxers --disable-demuxers \
                 --disable-parsers --disable-bsfs --disable-hwaccels \
                 --disable-indevs --disable-outdevs --disable-filters \
                 --disable-devices --disable-ffplay --disable-ffprobe \
                 --disable-ffmpeg --disable-avresample --disable-postproc \
                 --disable-swresample --disable-swscale --disable-avfilter \
                 --disable-network --disable-encoders --disable-decoders \
                 --disable-muxers --disable-demuxers --disable-parsers \
                 --disable-bsfs --disable-hwaccels --disable-indevs \
                 --disable-outdevs --disable-filters --disable-devices \
                 --disable-ffplay --disable-ffprobe --disable-ffmpeg \
                 --enable-encoder=libx264 --enable-encoder=aac \
                 --enable-decoder=h264 --enable-decoder=aac \
                 --enable-demuxer=mov --enable-demuxer=m4v --enable-demuxer=mp4 \
                 --enable-muxer=mp4 --enable-muxer=mpegts --enable-muxer=hls \
                 --enable-protocol=file --enable-protocol=http --enable-protocol=https \
                 --enable-filter=scale --enable-filter=resample"

# Only build for modern architectures
ARCHS="arm64 x86_64"

COMPILE="y"
LIPO="y"
DEPLOYMENT_TARGET="15.0"

if [ "$*" ]
then
	if [ "$*" = "lipo" ]
	then
		# skip compile
		COMPILE=
	else
		ARCHS="$*"
		if [ $# -eq 1 ]
		then
			# skip lipo
			LIPO=
		fi
	fi
fi

if [ "$COMPILE" ]
then
	echo "Building FFmpeg for iOS 15.0 compatibility..."
	echo "Deployment Target: $DEPLOYMENT_TARGET"
	echo "Enabled features: H.264 encoding, AAC encoding, MP4/M3U8/TS formats"
	echo "Architectures: $ARCHS"
	
	if [ ! `which yasm` ]
	then
		echo 'Yasm not found. Installing...'
		if [ ! `which brew` ]
		then
			echo 'Homebrew not found. Installing...'
			/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
		fi
		brew install yasm || exit 1
	fi
	
	if [ ! `which gas-preprocessor.pl` ]
	then
		echo 'gas-preprocessor.pl not found. Installing...'
		(curl -L https://github.com/libav/gas-preprocessor/raw/master/gas-preprocessor.pl \
			-o /usr/local/bin/gas-preprocessor.pl \
			&& chmod +x /usr/local/bin/gas-preprocessor.pl) \
			|| exit 1
	fi

	if [ ! -r $SOURCE ]
	then
		echo 'FFmpeg source not found. Downloading...'
		curl -L http://www.ffmpeg.org/releases/$SOURCE.tar.bz2 | tar xj \
			|| exit 1
	fi

	CWD=`pwd`
	for ARCH in $ARCHS
	do
		echo "Building $ARCH for iOS $DEPLOYMENT_TARGET..."
		mkdir -p "$SCRATCH/$ARCH"
		cd "$SCRATCH/$ARCH"

		CFLAGS="-arch $ARCH"
		if [ "$ARCH" = "x86_64" ]
		then
		    PLATFORM="iPhoneSimulator"
		    CFLAGS="$CFLAGS -mios-simulator-version-min=$DEPLOYMENT_TARGET"
		else
		    PLATFORM="iPhoneOS"
		    CFLAGS="$CFLAGS -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
		    if [ "$ARCH" = "arm64" ]
		    then
		        EXPORT="GASPP_FIX_XCODE5=1"
		    fi
		fi

		XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
		CC="xcrun -sdk $XCRUN_SDK clang"

		# force "configure" to use "gas-preprocessor.pl"
		if [ "$ARCH" = "arm64" ]
		then
		    AS="gas-preprocessor.pl -arch aarch64 -- $CC"
		else
		    AS="gas-preprocessor.pl -- $CC"
		fi

		CXXFLAGS="$CFLAGS"
		LDFLAGS="$CFLAGS"

		echo "Configuring FFmpeg for $ARCH with iOS $DEPLOYMENT_TARGET..."
		TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
		    --target-os=darwin \
		    --arch=$ARCH \
		    --cc="$CC" \
		    --as="$AS" \
		    $CONFIGURE_FLAGS \
		    --extra-cflags="$CFLAGS" \
		    --extra-ldflags="$LDFLAGS" \
		    --prefix="$THIN/$ARCH" \
		|| exit 1

		echo "Compiling FFmpeg for $ARCH..."
		make -j$(sysctl -n hw.ncpu) install $EXPORT || exit 1
		cd $CWD
	done
fi

if [ "$LIPO" ]
then
	echo "Creating universal binary for iOS $DEPLOYMENT_TARGET libraries..."
	mkdir -p $FAT/lib
	set - $ARCHS
	CWD=`pwd`
	cd $THIN/$1/lib
	
	# Only include the libraries needed for HLS
	HLS_LIBS="libavcodec.a libavformat.a libavutil.a libswscale.a libswresample.a"
	
	for LIB in $HLS_LIBS
	do
		if [ -f "$LIB" ]
		then
			cd $CWD
			echo "Creating universal binary for $LIB..."
			lipo -create `find $THIN -name $LIB` -output $FAT/lib/$LIB || exit 1
		fi
	done

	cd $CWD
	cp -rf $THIN/$1/include $FAT
	
	echo "iOS $DEPLOYMENT_TARGET compatible FFmpeg build completed!"
	echo "Libraries included: $HLS_LIBS"
	echo "Framework location: $FAT"
	echo ""
	echo "For Xcode integration, add these linker flags:"
	echo "-lavformat -lavcodec -lavutil -lswresample -lswscale -lz -lm -lpthread"
fi

echo "iOS $DEPLOYMENT_TARGET compatible FFmpeg build completed successfully!" 