#!/usr/bin/env ruby
# Add a small hosted test bundle to the CI project after archiving the IPA.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'vlc-ios-master/VLC.xcodeproj'))
app = project.targets.find { |target| target.name == 'VLC-iOS-no-watch' }
abort 'Missing app target' unless app
tests = project.targets.find { |target| target.name == 'RoxyPlaybackTests' }
tests ||= project.new_target(:unit_test_bundle, 'RoxyPlaybackTests', :ios, '15.0')
tests.add_dependency(app) unless tests.dependencies.any? { |dependency| dependency.target == app }

tests.build_configurations.each do |config|
  host = app.build_configurations.find { |item| item.name == config.name } || app.build_configurations.find { |item| item.name == 'Release' }
  config.base_configuration_reference = host.base_configuration_reference
  config.build_settings = Marshal.load(Marshal.dump(host.build_settings))
  settings = config.build_settings
  %w[INFOPLIST_FILE CODE_SIGN_ENTITLEMENTS SWIFT_OBJC_BRIDGING_HEADER SWIFT_OBJC_INTERFACE_HEADER_NAME GCC_PREFIX_HEADER ASSETCATALOG_COMPILER_APPICON_NAME].each { |key| settings.delete(key) }
  settings['PRODUCT_NAME'] = 'RoxyPlaybackTests'
  settings['PRODUCT_MODULE_NAME'] = 'RoxyPlaybackTests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.roxy.player.playback-tests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Roxy Player.app/Roxy Player'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  settings['SKIP_INSTALL'] = 'YES'
  settings['ENABLE_TESTING_SEARCH_PATHS'] = 'YES'
  settings['OTHER_LDFLAGS'] = ['-framework', 'XCTest', '-framework', 'VLCKit']
  settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)', '$(BUILT_PRODUCTS_DIR)/PackageFrameworks', '$(PLATFORM_DIR)/Developer/Library/Frameworks']
  settings['HEADER_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/Sources/Playback/Control', '$(SRCROOT)/Sources/App/iOS', '$(SRCROOT)/Sources/Cloud/Document Picker']
end
app.build_configurations.each do |config|
  config.build_settings['ENABLE_TESTABILITY'] = 'YES'
end

group = project.main_group.find_subpath('Roxy playback tests', true)
source = File.join(root, 'tests/RoxyPlaybackTests.m')
reference = group.files.find { |file| file.path == source } || group.new_file(source)
tests.source_build_phase.add_file_reference(reference, true)
%w[mkv mp4].each do |extension|
  path = File.join(root, '.build/playback-fixtures/shared.' + extension)
  reference = group.files.find { |file| file.path == path } || group.new_file(path)
  tests.resources_build_phase.add_file_reference(reference, true)
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.test_action.build_configuration = 'Release'
scheme.save_as(project.path, 'Roxy-PlaybackTests', true)
puts 'Prepared hosted Roxy playback integration tests'
