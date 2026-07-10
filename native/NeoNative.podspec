Pod::Spec.new do |s|
  s.name         = "NeoNative"
  s.version      = "0.1.0"
  s.summary      = "neo Rust core bindings and daemon control for the neo macOS app"
  s.description  = <<-DESC
    Links the neo-ffi Rust static library through UniFFI-generated Swift
    bindings (identity operations in-process) and manages the neo daemon
    binary for network operations (client, snapshot, send).
  DESC
  s.homepage     = "https://github.com/neo/neo-mac"
  s.license      = { :type => "AGPL-3.0-or-later" }
  s.authors      = { "neo" => "noreply@neo.invalid" }
  s.platforms    = { :osx => "11.0" }
  s.source       = { :path => "." }
  s.swift_version = "5.0"

  s.source_files = "Sources/**/*.{swift,m,h}", "Generated/neo_ffi.swift"
  # The UniFFI C header + module map are found via SWIFT_INCLUDE_PATHS below,
  # not compiled as pod headers.
  s.preserve_paths = "Generated/**/*", "Libs/**/*", "Bin/**/*"

  # Rust core: static library built by scripts/build-rust.sh.
  s.vendored_libraries = "Libs/libneo_ffi.a"

  # The neo CLI daemon, copied into the app bundle's Resources by CocoaPods.
  s.resources = ["Bin/neo"]

  s.frameworks = "Security", "NetworkExtension"

  s.pod_target_xcconfig = {
    "SWIFT_INCLUDE_PATHS" => "$(PODS_TARGET_SRCROOT)/Generated",
    "DEFINES_MODULE" => "YES",
  }

  s.dependency "React-Core"
end
