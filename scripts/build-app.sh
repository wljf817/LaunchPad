#!/bin/sh
# Builds the LaunchPad executable and assembles an ad-hoc signed LaunchPad.app
# in the SwiftPM build directory (.build/, git-ignored). The last line of output
# is the path of the app bundle.

set -eu

cd "$(dirname "$0")/.."

swift build --product LaunchPad
bin_dir=$(swift build --show-bin-path)
app="$bin_dir/LaunchPad.app"

# Assemble a fresh bundle rather than overwriting the signed executable in place:
# the system may check rewritten code against the signature it cached for the
# old file and kill the process.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/LaunchPad" "$app/Contents/MacOS/LaunchPad"

# LSMinimumSystemVersion must match the deployment target in Package.swift.
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LaunchPad</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.wljf817.LaunchPad</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>LaunchPad</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
</dict>
</plist>
EOF

# Keep the get-task-allow entitlement that SwiftPM signs debug executables with,
# so the bundled app stays debuggable.
codesign --force --sign - --preserve-metadata=entitlements "$app"

echo "$app"
