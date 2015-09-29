#
# Be sure to run `pod lib lint toxcore.podspec' to ensure this is a
# valid spec and remove all comments before submitting the spec.
#
# Any lines starting with a # are optional, but encouraged
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = "toxav"
  s.version          = "0.0.1-adab1e3"
  s.summary          = "Cocoapods wrapper for toxav"
  s.homepage         = "https://github.com/Antidote-for-Tox/toxcore"
  s.license          = 'GPLv3'
  s.author           = { "Dmytro Vorobiov" => "d@dvor.me" }
  s.source           = {
      :git => "https://github.com/Antidote-for-Tox/toxcore.git",
      :tag => s.version.to_s,
      :submodules => true
  }

  s.ios.deployment_target = '7.0'
  s.osx.deployment_target = '10.9'
  s.requires_arc = true

  # Preserve the layout of headers in the toxcore directory
  s.header_mappings_dir = 'toxcore'

  s.source_files = 'toxcore/toxav/*.{m,h}'

  s.dependency 'libopus-patched-config', '1.1'

  s.ios.vendored_frameworks = 'ios/vpx.framework'
  s.osx.vendored_frameworks = 'osx/vpx.framework'
  s.xcconfig = { 'FRAMEWORK_SEARCH_PATHS' => '"${PODS_ROOT}"'}

  s.dependency 'toxcore', s.version.to_s

end
