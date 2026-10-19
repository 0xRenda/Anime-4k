#!/usr/bin/env ruby
# CI builds an app-only iPhone/iPad target. Upstream widgets and share/watch
# extensions have separate provisioning requirements and aren't needed for IPA.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'vlc-ios-master/VLC.xcodeproj'))
target = project.targets.find { |item| item.name == 'VLC-iOS-no-watch' }
abort 'Missing Roxy target' unless target
target.dependencies.to_a.each do |dependency|
  product_type = dependency.target&.product_type.to_s
  dependency.remove_from_project if product_type.include?('extension') || product_type.include?('watchapp')
end
target.copy_files_build_phases.to_a.each do |phase|
  phase.remove_from_project if phase.name.to_s.include?('Extension') || phase.dst_subfolder_spec.to_s == '13'
end
target.build_configurations.each do |config|
  settings = config.build_settings
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  settings['PRODUCT_NAME'] = 'Roxy Player'
  settings['PRODUCT_MODULE_NAME'] = 'VLC'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = ENV.fetch('ROXY_BUNDLE_ID', 'com.roxy.player')
  settings['GROUP_IDENTIFIER'] = ENV.fetch('ROXY_APP_GROUP', 'group.' + settings['PRODUCT_BUNDLE_IDENTIFIER'])
  settings['KEYCHAIN_ACCESS_GROUP'] = settings['PRODUCT_BUNDLE_IDENTIFIER']
  settings['DEVELOPMENT_TEAM'] = ENV.fetch('APPLE_TEAM_ID', '')
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
  settings['SWIFT_COMPILATION_MODE'] = 'wholemodule'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Resources/iOS/Roxy.entitlements'
  if ENV['ROXY_SIGNED'] == 'true'
    settings['CODE_SIGN_STYLE'] = 'Manual'
    settings['CODE_SIGN_IDENTITY'] = ENV.fetch('ROXY_SIGNING_IDENTITY')
    settings['PROVISIONING_PROFILE_SPECIFIER'] = ENV.fetch('ROXY_PROFILE_NAME')
  end
end
project.save
puts 'Prepared app-only Roxy Player target'
