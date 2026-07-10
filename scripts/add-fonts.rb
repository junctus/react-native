#!/usr/bin/env ruby
# Adds the bundled Fonts/ directory to the NeoMac-macOS app target's resources
# as a folder reference (copied to Resources/Fonts/), so ATSApplicationFontsPath
# ("Fonts" in Info.plist) registers them. Idempotent.
#
#   ruby scripts/add-fonts.rb
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT = File.join(ROOT, 'macos', 'NeoMac.xcodeproj')
APP = 'NeoMac-macOS'

proj = Xcodeproj::Project.open(PROJECT)
app = proj.targets.find { |t| t.name == APP } or abort "app target #{APP} not found"

# Clean any prior reference.
app.resources_build_phase.files.dup.each do |bf|
  app.resources_build_phase.remove_build_file(bf) if bf.display_name == 'Fonts'
end
proj.main_group.recursive_children.select { |c| c.display_name == 'Fonts' && c.isa == 'PBXFileReference' }
    .each(&:remove_from_project)

# Add Fonts/ as a folder reference under the app group, then to resources.
group = proj.main_group.children.find { |c| c.display_name == APP } || proj.main_group
ref = group.new_reference('Fonts')
ref.last_known_file_type = 'folder'
app.resources_build_phase.add_file_reference(ref)

proj.save
puts "added Fonts/ folder reference to #{APP} resources"
