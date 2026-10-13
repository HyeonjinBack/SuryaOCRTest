#!/usr/bin/env ruby
# Only needed when regenerating the checked-in Xcode project.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
path = File.join(root, 'SuryaStudy.xcodeproj')
abort "Project already exists: #{path}. Remove it explicitly to regenerate." if File.exist?(path)
project = Xcodeproj::Project.new(path)
project.root_object.attributes['LastUpgradeCheck'] = '2700'
project.root_object.development_region = 'ko'
project.root_object.known_regions = ['ko', 'en', 'Base']

app = project.new_target(:application, 'SuryaStudy', :osx, '14.0')
app.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.swiftstudy.SuryaStudy',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SWIFT_VERSION' => '5.0',
    'SWIFT_OBJC_BRIDGING_HEADER' => '$(SRCROOT)/App/SuryaStudy-Bridging-Header.h',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0',
    'ARCHS' => 'arm64',
    'ONLY_ACTIVE_ARCH' => 'YES',
    'INFOPLIST_FILE' => 'Resources/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_STYLE' => 'Manual',
    'CODE_SIGN_IDENTITY' => '-',
    'CODE_SIGN_ENTITLEMENTS' => 'Resources/SuryaStudy.entitlements',
    'ENABLE_APP_SANDBOX' => 'YES',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'CLANG_ENABLE_MODULES' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => ['$(inherited)', '$(PROJECT_DIR)/Vendor/llama.xcframework/macos-arm64_x86_64'],
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    'SWIFT_EMIT_LOC_STRINGS' => 'YES'
  })
  config.build_settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO' if config.name == 'Release'
end

%w[App Core Runtime].each do |directory|
  group = project.main_group.new_group(directory, directory)
  Dir.glob(File.join(root, directory, '*')).sort.each do |file|
    ref = group.new_file(File.basename(file))
    app.source_build_phase.add_file_reference(ref) if %w[.swift .cpp].include?(File.extname(file))
  end
end

resources = project.main_group.new_group('Resources', 'Resources')
resources.new_file('Info.plist')
resources.new_file('SuryaStudy.entitlements')
licenses = resources.new_file('Licenses')
licenses.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(licenses)
models = project.main_group.new_file('Models')
models.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(models)

vendor = project.main_group.new_group('Vendor', 'Vendor')
framework = vendor.new_file('llama.xcframework')
framework.last_known_file_type = 'wrapper.xcframework'
app.frameworks_build_phase.add_file_reference(framework)
embed = app.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'
embedded = embed.add_file_reference(framework)
embedded.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

tests = project.new_target(:unit_test_bundle, 'SuryaStudyTests', :osx, '14.0')
tests.add_dependency(app)
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.swiftstudy.SuryaStudyTests',
    'SWIFT_VERSION' => '5.0',
    'ARCHS' => 'arm64',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'CODE_SIGN_STYLE' => 'Manual',
    'CODE_SIGN_IDENTITY' => '-',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/SuryaStudy.app/Contents/MacOS/SuryaStudy',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@loader_path/../Frameworks', '@executable_path/../Frameworks']
  })
end
test_group = project.main_group.new_group('Tests', 'Tests')
Dir.glob(File.join(root, 'Tests', '*.swift')).sort.each do |file|
  tests.source_build_phase.add_file_reference(test_group.new_file(File.basename(file)))
end

project.build_configurations.each do |config|
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
end
project.files.select { |file| file.path&.end_with?('/Cocoa.framework') }.each do |file|
  file.path = 'System/Library/Frameworks/Cocoa.framework'
  file.source_tree = 'SDKROOT'
end
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.launch_action.build_configuration = 'Debug'
scheme.test_action.build_configuration = 'Debug'
scheme.profile_action.build_configuration = 'Release'
scheme.archive_action.build_configuration = 'Release'
scheme.save_as(path, 'SuryaStudy', true)
puts "Created #{path}"
