#
# Be sure to run `pod lib lint toxcore.podspec' to ensure this is a
# valid spec and remove all comments before submitting the spec.
#
# Any lines starting with a # are optional, but encouraged
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = "toxcore"
  s.version          = "0.0.0-2ab3b14-2"
  s.summary          = "Cocoapods wrapper for toxcore"
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

  s.source_files = 'toxcore/toxcore/*.{c,h}', 'toxcore/toxencryptsave/*.{c,h}', 'toxcore/toxdns/*.{c,h}', 'toxcore/toxav/*.{c,h}'

  s.dependency 'libsodium', '~> 1.0.1'
  s.dependency 'libopus-patched-config', '1.1'

  s.ios.vendored_frameworks = 'vpx.framework'
  s.osx.vendored_frameworks = 'vpx.framework'
  s.xcconfig = { 'FRAMEWORK_SEARCH_PATHS' => '"${PODS_ROOT}"'}

end
