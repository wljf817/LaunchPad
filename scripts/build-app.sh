#!/bin/sh
# Builds LaunchPad and assembles a signed LaunchPad.app in the SwiftPM build directory (.build/,
# git-ignored). The last line of output is the path of the app bundle. The bundles are signed with
# the "LaunchPad Code Signing" identity when the keychain has one, ad-hoc otherwise.
#
# LaunchPad.app is the launcher, built like the original's Launchpad.app: a background app that
# sends a toggle message and exits. LaunchPad's background process, which shows Launchpad, is the
# app inside it, Contents/Helpers/LaunchPadAgent.app, started by launchd as an agent
# (Contents/Library/LaunchAgents) at login (app-bundle). The text input service, an XPC service as
# the original's com.apple.dock.ecti is (REF-SEARCH-011), is inside the background process's bundle:
# Contents/XPCServices/io.github.wljf817.LaunchPad.ecti.xpc.

set -eu

cd "$(dirname "$0")/.."

swift build -c release --product LaunchPad
swift build -c release --product LaunchPadLauncher
swift build -c release --product LaunchPadECTI
bin_dir=$(swift build -c release --show-bin-path)
app="$bin_dir/LaunchPad.app"
agent="$app/Contents/Helpers/LaunchPadAgent.app"
ecti="$agent/Contents/XPCServices/io.github.wljf817.LaunchPad.ecti.xpc"

# Assemble a fresh bundle rather than overwriting the signed executables in place: the system may
# check rewritten code against the signature it cached for the old file and kill the process.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents" \
    "$agent/Contents/MacOS" "$agent/Contents/Resources" "$ecti/Contents/MacOS" "$ecti/Contents/Resources"
cp "$bin_dir/LaunchPadLauncher" "$app/Contents/MacOS/LaunchPad"
cp "$bin_dir/LaunchPad" "$agent/Contents/MacOS/LaunchPadAgent"
cp Sources/LaunchPad/Resources/LaunchPadLayout.plist "$agent/Contents/Resources/"
cp -R Sources/LaunchPad/Resources/*.lproj "$agent/Contents/Resources/"
# The search field's images, drawn by tools/assets/search-field-images.swift (REF-SEARCH-003).
cp Sources/LaunchPad/Resources/ectl_search_*.png "$agent/Contents/Resources/"
cp "$bin_dir/LaunchPadECTI" "$ecti/Contents/MacOS/io.github.wljf817.LaunchPad.ecti"
# LaunchPad's own nib source, with the objects of the original service's nib (REF-SEARCH-011).
xcrun ibtool --compile "$ecti/Contents/Resources/MainMenu.nib" Sources/LaunchPadECTI/Resources/MainMenu.xib

# LSMinimumSystemVersion must match the deployment target in Package.swift.
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LaunchPad</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.wljf817.LaunchPad.launcher</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>LaunchPad</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

cat > "$agent/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>LaunchPadAgent</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.wljf817.LaunchPad</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>LaunchPadAgent</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

# The service's keys other than its names are the original service's (REF-SEARCH-011): an
# application with the _NSApplicationMain run loop, joining the existing session, one instance per
# search field.
cat > "$ecti/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>io.github.wljf817.LaunchPad.ecti</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.wljf817.LaunchPad.ecti</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>io.github.wljf817.LaunchPad.ecti</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMainNibFile</key>
	<string>MainMenu</string>
	<key>NSPrincipalClass</key>
	<string>ECTIHelperApp</string>
	<key>XPCService</key>
	<dict>
		<key>JoinExistingSession</key>
		<true/>
		<key>RunLoopType</key>
		<string>_NSApplicationMain</string>
		<key>ServiceType</key>
		<string>Application</string>
		<key>_MultipleInstances</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# The launchd agent: started at login and again when it exits, with LaunchPad's Mach service, as
# the Dock's launchd job declares com.apple.dock.server (REF-DEV-013), and spawned as an app, as
# the Dock's job is (REF-ARCH-009).
cat > "$app/Contents/Library/LaunchAgents/io.github.wljf817.LaunchPad.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>io.github.wljf817.LaunchPad</string>
	<key>BundleProgram</key>
	<string>Contents/Helpers/LaunchPadAgent.app/Contents/MacOS/LaunchPadAgent</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>io.github.wljf817.LaunchPad.launcher</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>io.github.wljf817.LaunchPad.server</key>
		<true/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>POSIXSpawnType</key>
	<string>App</string>
</dict>
</plist>
PLIST

# A self-signed certificate the user creates in Keychain Access gives a designated requirement of
# identifier and certificate, the same for every build, so the Accessibility permission granted to
# the background process survives a rebuild; an ad-hoc signature's requirement is its cdhash. The
# identity is picked by its SHA-1, as codesign matches names by substring. find-identity lists the
# untrusted self-signed identity only without -v.
identity=$(security find-identity -p codesigning |
    sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "LaunchPad Code Signing".*/\1/p' | head -n 1)
identity=${identity:--}

# Keep the get-task-allow entitlement that SwiftPM signs debug executables with, so the bundled
# apps stay debuggable. The inner bundles are signed first.
codesign --force --sign "$identity" --preserve-metadata=entitlements "$ecti"
codesign --force --sign "$identity" --preserve-metadata=entitlements "$agent"
codesign --force --sign "$identity" --preserve-metadata=entitlements "$app"

echo "$app"
