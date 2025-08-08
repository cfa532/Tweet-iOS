platform :ios, '15.0'

target 'Tweet' do
  use_frameworks!  # Use dynamic frameworks
  pod 'hprose', '2.0.3'
  pod 'SDWebImageSwiftUI', '~> 3.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      # Ensure inherited settings are used
      config.build_settings['LIBRARY_SEARCH_PATHS'] = ['$(inherited)']
    end
  end
end 