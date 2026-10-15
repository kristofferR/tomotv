#
# TomoEngine.podspec
#
# The on-device playback engine (LocalRemuxer). Its bridge is a legacy
# RCT_EXTERN_MODULE class, so the pod depends on React-Core; FFmpeg comes from
# the TomoFFmpeg pod beside this file, SpatialAudioBridge from Swift Package Manager. The package's app.plugin.js adds this pod,
# TomoLiveSources and TomoFFmpeg to the app's Podfile.
#
require "json"

package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))

Pod::Spec.new do |s|
  s.name         = "TomoEngine"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = { :type => "MIT" }
  s.author       = package["author"]
  s.source       = { :path => "." }

  s.ios.deployment_target  = "16.4"
  s.tvos.deployment_target = "16.4"
  s.swift_versions = ["5.0"]

  s.source_files = "LocalRemuxer/**/*.{swift,m}"

  s.dependency "React-Core"
  s.dependency "TomoFFmpeg"
  # TrueHD Atmos and DTS:X to APAC; Package.swift declares the same package for the host tests.
  spm_dependency(s,
    url: "https://github.com/kristofferR/SpatialAudioBridge",
    requirement: { kind: "upToNextMajorVersion", minimumVersion: "1.6.2" },
    products: ["SpatialAudioBridge", "SpatialAudioPlayback"]
  )

  # Share SwiftPM's XCFramework staging directory so Xcode collects SpatialAudioCore's
  # archive signature once. CONFIGURATION_BUILD_DIR keeps the pod's own library separate.
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "BUILT_PRODUCTS_DIR" => "$(PODS_CONFIGURATION_BUILD_DIR)"
  }
end
