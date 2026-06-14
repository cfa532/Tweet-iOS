#!/bin/sh
set -e

if [ -z "${PODS_ROOT:-}" ] || [ -z "${PODS_XCFRAMEWORKS_BUILD_DIR:-}" ]; then
  echo "error: PODS_ROOT or PODS_XCFRAMEWORKS_BUILD_DIR is not set"
  exit 1
fi

case "${EFFECTIVE_PLATFORM_NAME:-${PLATFORM_NAME:-}}" in
  *simulator*) SLICE="ios-arm64_x86_64-simulator" ;;
  *) SLICE="ios-arm64" ;;
esac

SOURCE_ROOT="${PODS_ROOT}/../Vendor/ffmpeg-kit-ios-min/Frameworks"
DESTINATION="${PODS_XCFRAMEWORKS_BUILD_DIR}/ffmpeg-kit-ios"
mkdir -p "${DESTINATION}"

copy_framework() {
  NAME="$1"
  SOURCE="${SOURCE_ROOT}/${NAME}.xcframework/${SLICE}/${NAME}.framework"
  TARGET="${DESTINATION}/${NAME}.framework"

  if [ ! -d "${SOURCE}" ]; then
    echo "error: Missing ${SOURCE}"
    exit 1
  fi

  rm -rf "${TARGET}"
  /bin/cp -R "${SOURCE}" "${DESTINATION}/"
  echo "Copied ${SOURCE} to ${TARGET}"
}

copy_framework ffmpegkit
copy_framework libavcodec
copy_framework libavdevice
copy_framework libavfilter
copy_framework libavformat
copy_framework libavutil
copy_framework libswresample
copy_framework libswscale
