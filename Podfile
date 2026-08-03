platform :ios, '15.0'

target 'Tweet' do
  use_frameworks!  # Use dynamic frameworks
  pod 'hprose', '2.0.3'
  pod 'SDWebImageSwiftUI', '~> 3.1.3'
  pod 'ffmpeg-kit-ios', :path => 'Vendor/ffmpeg-kit-ios-min'
  
  # CachingPlayerItem is now integrated directly into the app
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      
      # Force dSYM generation for all frameworks
      config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
      
      # Ensure symbols are not stripped
      config.build_settings['STRIP_INSTALLED_PRODUCT'] = 'NO'
      config.build_settings['SEPARATE_STRIP'] = 'NO'
      
      # Additional dSYM settings
      config.build_settings['DWARF_DSYM_FOLDER_PATH'] = '$(CONFIGURATION_BUILD_DIR)'
      config.build_settings['DWARF_DSYM_FILE_NAME'] = '$(EXECUTABLE_NAME).dSYM'
      config.build_settings['DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT'] = 'YES'
      
      # Disable bitcode (can cause dSYM issues)
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      
      # Ensure proper architecture settings - support both arm64 and x86_64 for simulator
      config.build_settings['ARCHS'] = '$(ARCHS_STANDARD)'
      config.build_settings['VALID_ARCHS'] = 'arm64 x86_64'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
      
      # Suppress deprecation warnings in SDWebImage (third-party code using old UTType APIs)
      if target.name == 'SDWebImage'
        config.build_settings['GCC_WARN_DEPRECATED_FUNCTIONS'] = 'NO'
        config.build_settings['CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS'] = 'NO'
        config.build_settings['GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS'] = 'NO'
      end
      
      # Suppress deprecation warnings in hprose (third-party code using old SSL APIs)
      if target.name == 'hprose'
        config.build_settings['GCC_WARN_DEPRECATED_FUNCTIONS'] = 'NO'
        config.build_settings['CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS'] = 'NO'
        config.build_settings['GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS'] = 'NO'
      end
    end
  end

  ffmpeg_copy_script = File.join(
    installer.sandbox.root,
    'Target Support Files',
    'ffmpeg-kit-ios',
    'ffmpeg-kit-ios-xcframeworks.sh'
  )

  if File.exist?(ffmpeg_copy_script)
    ffmpeg_copy_script_body = <<~'SH'
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
    SH

    File.write(ffmpeg_copy_script, "#!/bin/sh\n#{ffmpeg_copy_script_body}")
    File.chmod(0o755, ffmpeg_copy_script)

    ffmpeg_target = installer.pods_project.targets.find { |target| target.name == 'ffmpeg-kit-ios' }
    if ffmpeg_target
      ffmpeg_target.build_phases.each do |phase|
        next unless phase.respond_to?(:name) && phase.name == '[CP] Copy XCFrameworks'

        phase.shell_script = ffmpeg_copy_script_body
      end
    end
  end

  # FFmpegKit is loaded explicitly through dlopen when conversion/probing is
  # requested. Keep the frameworks copied into the app bundle, but remove them
  # from the app target linker flags so app launch does not load FFmpeg.
  ffmpeg_link_flags = [
    '-framework "ffmpegkit"',
    '-framework "libavcodec"',
    '-framework "libavdevice"',
    '-framework "libavfilter"',
    '-framework "libavformat"',
    '-framework "libavutil"',
    '-framework "libswresample"',
    '-framework "libswscale"'
  ]

  Dir.glob(File.join(installer.sandbox.root, 'Target Support Files', 'Pods-Tweet', 'Pods-Tweet.*.xcconfig')).each do |xcconfig|
    contents = File.read(xcconfig)
    ffmpeg_link_flags.each do |flag|
      contents = contents.gsub(" #{flag}", '')
    end
    File.write(xcconfig, contents)
  end
end
