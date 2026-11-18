Pod::Spec.new do |s|
  s.name = 'IosSherpa'
  s.version = '0.1.0'
  s.summary = 'On-device sherpa-onnx for TranslateAnywhere.'
  s.homepage = 'https://local.translateanywhere'
  s.license = { :type => 'Apache-2.0' }
  s.author = { 'TranslateAnywhere' => 'dev@local' }
  s.source = { :path => '.' }
  s.platform = :ios, '15.5'
  s.source_files = 'Sources/*.{h,mm}'
  s.public_header_files = 'Sources/IosSherpa.h'
  header = File.expand_path('../../third_party/sherpa-onnx/sherpa-onnx/c-api', __dir__)
  prebuilt = File.expand_path('../../native/prebuilt/ios', __dir__)
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => "\"#{header}\"",
    'OTHER_LDFLAGS' => "-force_load \"#{prebuilt}/libsherpa_ios.a\" -force_load \"#{prebuilt}/libonnxruntime_ios.a\" -lbz2",
  }
  s.frameworks = 'Foundation', 'Accelerate', 'CoreML'
  s.libraries = 'c++', 'bz2'
end
