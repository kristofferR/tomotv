# CocoaPods must generate both TomoEngine's build directory and its consumers' module-map,
# library and Swift import paths in SwiftPM's shared directory. Otherwise Xcode stages
# SpatialAudioCore twice and its archive signature records collide.
module TomoEngineSPMBuildDirectory
  def configuration_build_dir(dir = Pod::Target::BuildSettings::CONFIGURATION_BUILD_DIR_VARIABLE)
    pod_name == 'TomoEngine' ? dir : super
  end
end

Pod::PodTarget.prepend(TomoEngineSPMBuildDirectory)
