require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "EverythingPlayer"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/react-native-everything-player"
  s.license      = package["license"]
  s.authors      = "react-native-everything-player"

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/react-native-everything-player.git", :tag => "#{s.version}" }
  s.swift_version = "5.9"

  s.source_files = [
    "ios/**/*.{swift}",
    "ios/**/*.{m,mm}",
    "ios/Vendor/Copus/**/*.{c,h}",
    "cpp/**/*.{hpp,cpp}",
  ]
  s.public_header_files = ["ios/Vendor/Copus/include/*.h"]

  s.frameworks = ["AVFoundation", "MediaPlayer", "VideoToolbox", "CoreMedia", "CoreVideo", "QuartzCore"]

  s.pod_target_xcconfig = {
    "HEADER_SEARCH_PATHS" => [
      "$(PODS_TARGET_SRCROOT)/ios/Vendor/Copus",
      "$(PODS_TARGET_SRCROOT)/ios/Vendor/Copus/include",
      "$(PODS_TARGET_SRCROOT)/ios/Vendor/Copus/celt",
      "$(PODS_TARGET_SRCROOT)/ios/Vendor/Copus/silk",
      "$(PODS_TARGET_SRCROOT)/ios/Vendor/Copus/silk/float",
    ].join(" "),
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) OPUS_BUILD VAR_ARRAYS=1 FLOATING_POINT HAVE_LRINT=1 HAVE_LRINTF=1",
  }

  load "nitrogen/generated/ios/EverythingPlayer+autolinking.rb"
  add_nitrogen_files(s)

  s.dependency "SwiftProtobuf", "~> 1.35"
  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  install_modules_dependencies(s)
end
