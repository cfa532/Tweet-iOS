# Minimal FFmpegKit iOS Build Memo

**Last updated:** June 2026

This app needs local FFmpeg because uploaded video is converted on the phone before it is sent to IPFS/cloud-drive storage. We cannot require every remote IPFS node to install FFmpeg.

The current dependency is a local CocoaPod:

- Pod: `ffmpeg-kit-ios`
- Path: `Vendor/ffmpeg-kit-ios-min`
- Version label: `6.0.1-local-min`
- Current vendored size: about `43 MB`
- Slices: `ios-arm64` and `ios-arm64_x86_64-simulator`
- Main system libraries used: `VideoToolbox`, `AudioToolbox`, `AVFoundation`, `zlib`

FFmpegKit itself is archived/retired upstream, so we keep the built artifacts in this repo instead of depending on remote CocoaPods binaries.

## What The App Actually Uses

The current conversion path is intentionally narrow:

- Run FFmpeg through `FFmpegKit.executeAsync`.
- Re-encode video with Apple hardware H.264: `-c:v h264_videotoolbox`.
- Allow software fallback: `-allow_sw 1`.
- Encode audio with FFmpeg AAC: `-c:a aac`.
- Scale when needed: `-vf scale=...`.
- Produce HLS VOD output: `-f hls`, `-hls_time 10`, `segment%03d.ts`, `playlist.m3u8`.
- Fast path for already-normalized video: `-c:v copy`, `-c:a aac`, HLS remux.
- MP4 fallback/normalization still uses `h264_videotoolbox`, `aac`, `scale`, and `+faststart`.

So the minimum useful FFmpeg feature set is:

- FFmpegKit Objective-C wrapper: `ffmpegkit.framework`
- FFmpeg core libraries: `libavcodec`, `libavformat`, `libavutil`, `libavfilter`, `libswscale`, `libswresample`
- Usually present even if barely used: `libavdevice`
- Encoders: `h264_videotoolbox`, `aac`
- Common decoders/demuxers for iOS camera/library input: MP4/MOV, H.264, HEVC, AAC
- Muxers: `hls`, `mpegts`, `mp4`
- Protocol: `file`
- Filters: `scale` and its dependencies

Do not include GPL encoders such as `x264` or `x265`; the app does not call `libx264`.

## Practical Rebuild Recipe

This is the safer rebuild path. It keeps FFmpegKit's normal FFmpeg feature selection but removes the big external/GPL dependency families.

1. Clone the archived upstream source outside this repo:

```bash
git clone https://github.com/arthenica/ffmpeg-kit.git
cd ffmpeg-kit
git checkout v6.0
```

2. Build iOS XCFrameworks, main release, iOS 15+, no GPL, no full package:

```bash
./ios.sh \
  --xcframework \
  --target=15.0 \
  --no-bitcode \
  --disable-armv7 \
  --disable-armv7s \
  --disable-i386 \
  --disable-arm64e \
  --disable-arm64-mac-catalyst \
  --disable-x86-64-mac-catalyst
```

Notes:

- Do not pass `--full`.
- Do not pass `--enable-gpl`.
- Do not enable `x264`, `x265`, `libvpx`, `libwebp`, `libass`, font libraries, TLS libraries, or other optional packages unless a new app feature truly needs them.
- Use main release, not LTS, because the app depends on `VideoToolbox`.

3. Copy the generated iOS XCFrameworks into:

```text
Vendor/ffmpeg-kit-ios-min/Frameworks/
```

Keep these framework names because the Podfile copy script and linker settings expect them:

```text
ffmpegkit.xcframework
libavcodec.xcframework
libavdevice.xcframework
libavfilter.xcframework
libavformat.xcframework
libavutil.xcframework
libswresample.xcframework
libswscale.xcframework
```

4. Keep/update the local podspec:

```text
Vendor/ffmpeg-kit-ios-min/ffmpeg-kit-ios.podspec
```

It should continue to declare:

```ruby
s.vendored_frameworks = 'Frameworks/*.xcframework'
s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'Foundation', 'VideoToolbox'
s.libraries = 'c++', 'z'
```

5. Reinstall pods:

```bash
pod install
```

The repo's `Podfile` patches the CocoaPods `[CP] Copy XCFrameworks` phase for this pod. That patch copies only the active slice into `PODS_XCFRAMEWORKS_BUILD_DIR`, avoiding the previous Xcode script failure from copying the whole package.

## Verification Checklist

After replacing the frameworks:

1. Clean DerivedData for the app.
2. Run `pod install`.
3. Build `Tweet.xcworkspace` for a real iPhone.
4. Build for an iPhone simulator.
5. Confirm Swift can import `ffmpegkit`.
6. Upload a short portrait video.
7. Upload a short landscape video.
8. Upload a video above 720p and confirm it scales down.
9. Upload a video at or below 720p and confirm the HLS output plays.
10. Check that `master.m3u8`, `playlist.m3u8`, and `.ts` segments are uploaded.
11. Watch memory during conversion; it should stay comfortably below iOS pressure thresholds.

Expected failure if the package is trimmed too far:

- Missing `FFmpegKit`, `FFmpegKitConfig`, `ReturnCode`, or `Log` symbols means `ffmpegkit.framework` is not linked/copied correctly.
- `Unknown encoder 'h264_videotoolbox'` means VideoToolbox support was not built.
- `Unknown encoder 'aac'` means FFmpeg AAC encoder support was removed.
- `Requested output format 'hls' is not a suitable output format` means the HLS muxer was removed.
- `No such filter: 'scale'` means `libavfilter`/`libswscale` or the scale filter was removed.

## Optional: More Aggressive Trimming

The practical build above is the recommended baseline. A smaller build is possible, but it requires patching FFmpegKit's FFmpeg configure flags to disable most FFmpeg components and then explicitly re-enable the pieces listed in this memo.

That path is more fragile because iOS Photos input can vary: H.264, HEVC, MOV/MP4 containers, rotation metadata, AAC audio, and sometimes odd pixel formats. If we do this later, keep it as a separate branch and validate with a real device video matrix before replacing the vendored package.

Candidate FFmpeg configure direction:

```text
--disable-everything
--enable-encoder=h264_videotoolbox,aac
--enable-decoder=h264,hevc,aac
--enable-demuxer=mov
--enable-muxer=hls,mpegts,mp4
--enable-parser=h264,hevc,aac
--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
--enable-protocol=file
--enable-filter=scale
--enable-videotoolbox
--enable-audiotoolbox
--enable-zlib
```

Treat that list as a starting point, not a drop-in guarantee. The app's current production-safe choice is the local `ffmpeg-kit-ios-min` pod with external/GPL libraries excluded.

## References

- Current pod: `Vendor/ffmpeg-kit-ios-min`
- Pod integration: `Podfile`
- Conversion code: `Sources/Core/VideoConversionService.swift`
- Legacy/fallback conversion code: `Sources/Core/HproseInstance.swift`
- Upstream source: `https://github.com/arthenica/ffmpeg-kit`
