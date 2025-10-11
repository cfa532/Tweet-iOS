platform :ios, '15.0'

target 'Tweet' do
  use_frameworks!  # Use dynamic frameworks
  pod 'hprose', '2.0.3'
  pod 'SDWebImageSwiftUI', '~> 3.1.3'
  pod 'ffmpeg-kit-ios', '~> 6.0'
  
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
end 