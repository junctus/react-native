#!/usr/bin/env ruby
# Adds (or refreshes) the NeoTunnel packet-tunnel-provider **system extension**
# target in macos/NeoMac.xcodeproj. Idempotent: safe to re-run (e.g. after
# pod install). macOS requires the system-extension model (not an app extension)
# for a packet tunnel distributed outside the Mac App Store (Developer ID).
#
#   ruby scripts/add-tunnel-target.rb
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT = File.join(ROOT, 'macos', 'NeoMac.xcodeproj')
EXT = 'NeoTunnel'
APP = 'NeoMac-macOS'
APP_BUNDLE_ID = 'org.reactjs.native.NeoMac'

proj = Xcodeproj::Project.open(PROJECT)
app = proj.targets.find { |t| t.name == APP } or abort "app target #{APP} not found"

# --- clean any previous run -------------------------------------------------
# Remove dependencies first (a dep whose target was already deleted has a nil
# target, which later trips add_dependency), then the target, group, and phase.
app.dependencies.dup.each do |d|
  d.remove_from_project if d.target.nil? || d.target.name == EXT
end
app.build_phases.select { |p|
  p.isa == 'PBXCopyFilesBuildPhase' &&
    ['Embed App Extensions', 'Embed System Extensions'].include?(p.display_name)
}.each(&:remove_from_project)
proj.targets.select { |t| t.name == EXT }.each(&:remove_from_project)
if (g = proj.main_group.children.find { |c| c.display_name == EXT })
  g.remove_from_project
end

# --- create the system-extension target ------------------------------------
# The xcodeproj gem has no :system_extension helper, so create a target and
# retarget it: system-extension product type, a real main() entry point (no
# NSExtensionMain), and a .systemextension wrapper.
ext = proj.new_target(:app_extension, EXT, :osx, '14.0', proj.products_group, :swift)
ext.product_type = 'com.apple.product-type.system-extension'
# The bundle must be named after its bundle id: OSSystemExtensionManager locates
# a system extension by its on-disk name (PRODUCT_NAME), not just
# CFBundleIdentifier — a mismatch fails activation with "Extension not found in
# App bundle". So PRODUCT_NAME = the full bundle id, and PRODUCT_MODULE_NAME is
# pinned to the short name to keep the Swift module (NEProviderClasses) valid.
EXT_BUNDLE_ID = "#{APP_BUNDLE_ID}.#{EXT}"
pref = ext.product_reference
pref.name = "#{EXT_BUNDLE_ID}.systemextension"
pref.path = "#{EXT_BUNDLE_ID}.systemextension"
pref.explicit_file_type = 'wrapper.system-extension'
pref.last_known_file_type = nil

common = {
  'PRODUCT_NAME'                     => EXT_BUNDLE_ID,
  'PRODUCT_MODULE_NAME'              => EXT,
  'PRODUCT_BUNDLE_IDENTIFIER'        => EXT_BUNDLE_ID,
  'MACOSX_DEPLOYMENT_TARGET'         => '14.0',
  'SWIFT_VERSION'                    => '5.0',
  'INFOPLIST_FILE'                   => "#{EXT}/Info.plist",
  'GENERATE_INFOPLIST_FILE'          => 'NO',
  'CODE_SIGN_ENTITLEMENTS'           => "#{EXT}/#{EXT}.entitlements",
  'CODE_SIGN_STYLE'                  => 'Automatic',
  'SKIP_INSTALL'                     => 'YES',
  'WRAPPER_EXTENSION'                => 'systemextension',
  # A system extension is a normal executable (main.swift), not an app extension.
  'APPLICATION_EXTENSION_API_ONLY'   => 'NO',
  'CLANG_ENABLE_MODULES'             => 'YES',
  # The vendored Rust lib is arm64-only unless x86_64 was built (see
  # scripts/build-rust.sh), so build the active arch to match the app target.
  'ONLY_ACTIVE_ARCH'                 => 'YES',
  'SWIFT_INCLUDE_PATHS'              => '$(SRCROOT)/../native/Generated',
  # Link the Rust core by absolute path. A LIBRARY_SEARCH_PATHS + -lneo_ffi pair
  # is rebased onto the SDK dir in the pods-merged workspace build and not found;
  # a full path passed straight to ld is unambiguous. -force_load keeps UniFFI's
  # scaffolding (registered via constructors, not otherwise referenced).
  'OTHER_LDFLAGS'                    => ['-force_load', '$(PROJECT_DIR)/../native/Libs/libneo_ffi.a'],
  'ENABLE_HARDENED_RUNTIME'          => 'YES',
  'LD_RUNPATH_SEARCH_PATHS'          => ['$(inherited)', '@executable_path/../Frameworks',
                                         '@executable_path/../../../../Frameworks'],
}
ext.build_configurations.each { |c| common.each { |k, v| c.build_settings[k] = v } }

# --- source & resource files ------------------------------------------------
# Group path is EXT, so children are named relative to it.
group = proj.main_group.new_group(EXT, "#{EXT}")
main = group.new_reference('main.swift')
provider = group.new_reference('PacketTunnelProvider.swift')
group.new_reference('Info.plist')
group.new_reference("#{EXT}.entitlements")
# The generated UniFFI bindings, compiled into this target (shared with the pod).
# From macos/NeoTunnel/ up to the repo root, then into native/Generated.
bindings = group.new_reference('../../native/Generated/neo_ffi.swift')

ext.source_build_phase.add_file_reference(main)
ext.source_build_phase.add_file_reference(provider)
ext.source_build_phase.add_file_reference(bindings)

# --- frameworks -------------------------------------------------------------
ext.add_system_framework(%w[NetworkExtension Security])
# The Rust static lib is linked via OTHER_LDFLAGS (above); add a navigator-only
# reference so it's visible in Xcode without going through the Frameworks phase.
group.new_reference('../../native/Libs/libneo_ffi.a')

# --- wire the extension into the app ---------------------------------------
# A system extension lives in Contents/Library/SystemExtensions, not PlugIns.
app.add_dependency(ext)
embed = app.new_copy_files_build_phase('Embed System Extensions')
embed.symbol_dst_subfolder_spec = :wrapper
embed.dst_path = 'Contents/Library/SystemExtensions'
ref = embed.add_file_reference(ext.product_reference)
ref.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Ensure the app actually uses its entitlements (NE requires it) — it was unset.
app.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{APP}/NeoMac.entitlements"
end

proj.save
puts "added system-extension target #{EXT} (#{APP_BUNDLE_ID}.#{EXT}); app embeds & depends on it"
