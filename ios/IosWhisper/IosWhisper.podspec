Pod::Spec.new do |s|
  s.name = 'IosWhisper'
  s.version = '0.1.0'
  s.summary = 'On-device whisper.cpp for TranslateAnywhere.'
  s.homepage = 'https://local.translateanywhere'
  s.license = { :type => 'MIT' }
  s.author = { 'TranslateAnywhere' => 'dev@local' }
  s.source = { :path => '.' }
  s.platform = :ios, '15.5'
  s.source_files = 'Sources/*.{h,mm}'
  s.public_header_files = 'Sources/IosWhisper.h'
  header = File.expand_path('../../third_party/whisper.cpp', __dir__)
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => "\"#{header}/include\" \"#{header}/ggml/include\"",
    'OTHER_LDFLAGS' => "-force_load \"#{File.expand_path('../../native/prebuilt/ios/libwhisper_ios.a', __dir__)}\"",
  }
  s.frameworks = 'Foundation', 'Metal', 'MetalKit', 'Accelerate'
  s.libraries = 'c++'
end
