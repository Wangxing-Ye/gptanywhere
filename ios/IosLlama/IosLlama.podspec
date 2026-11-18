Pod::Spec.new do |s|
  s.name = 'IosLlama'
  s.version = '0.1.0'
  s.summary = 'On-device llama.cpp for TranslateAnywhere.'
  s.homepage = 'https://local.translateanywhere'
  s.license = { :type => 'MIT' }
  s.author = { 'TranslateAnywhere' => 'dev@local' }
  s.source = { :path => '.' }
  s.platform = :ios, '15.5'
  s.source_files = 'Sources/*.{h,mm}'
  s.public_header_files = 'Sources/IosLlama.h'
  s.frameworks = 'Foundation', 'Metal', 'MetalKit', 'Accelerate'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_ENABLE_CPP_EXCEPTIONS' => 'YES',
    'GCC_ENABLE_CPP_RTTI' => 'YES',
    'OTHER_LDFLAGS' => "-force_load \"#{File.expand_path('../../native/prebuilt/ios/libllama_ios.a', __dir__)}\"",
  }
end
