Pod::Spec.new do |s|
  s.name = 'ffmpeg-kit-ios'
  s.version = '6.0.1-local-min'
  s.summary = 'Minimal local FFmpegKit iOS build for Tweet video conversion.'
  s.description = 'A local FFmpegKit build with Apple VideoToolbox, AudioToolbox, and zlib enabled.'
  s.homepage = 'https://github.com/arthenica/ffmpeg-kit'
  s.license = { :type => 'LGPL-3.0', :file => 'LICENSE' }
  s.author = { 'Tweet' => 'local' }
  s.platform = :ios, '15.0'
  s.source = { :path => '.' }
  s.vendored_frameworks = 'Frameworks/*.xcframework'
  s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'Foundation', 'VideoToolbox'
  s.libraries = 'c++', 'z'
end
