platform :ios, '15.0'

target 'Tweet' do
  use_frameworks!  # Use dynamic frameworks
  pod 'hprose', '2.0.3'
  pod 'SDWebImageSwiftUI', '~> 3.1.3'
  pod 'ffmpeg-kit-ios', '~> 6.0'
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
      
      # Ensure proper architecture settings
      config.build_settings['ARCHS'] = 'arm64'
      config.build_settings['VALID_ARCHS'] = 'arm64'
    end
  end
end 