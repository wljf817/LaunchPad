#!/bin/bash
# Install or remove the test apps of the grid-items-still scene in a VM: one
# minimal bundle per line of grid-items-scene.tsv in /Applications/LPGridScene/
# (executable copied from /usr/bin/true, as the test bundles of REF-LAYOUT-008),
# bundle identifier io.github.wljf817.lptest.grid.<n>. The same script serves
# the reference VM (macOS 15) and the comparison VM (macOS 26). Dock sees the
# change through FSEvents; this project's background process does not follow
# FSEvents yet (phase 6), so in the comparison VM the script then stops it,
# clears the stored FSEvents UUID of its /Applications source in its database
# so that the next start scans that source fully, and kills it to restart.
# With --paging, install and remove also handle the second page of the
# page-control-* scenes (paging spec): one minimal bundle per line of
# page-control-scene.tsv in /Applications/LPPageScene/, bundle identifier
# io.github.wljf817.lptest.page.<n>; list prints those titles too.
# Needs key-based SSH login and passwordless sudo in the VM.
#
# Usage: tools/compare/grid-items-apps.sh <user>@<vm-address> install|remove|list [--paging]

set -euo pipefail

[[ $# -eq 2 || ( $# -eq 3 && $3 == --paging ) ]] || { echo "usage: $0 <user>@<vm-address> install|remove|list [--paging]" >&2; exit 2; }
vm_dest=$1
action=$2
paging=${3:+1}
repo=$(cd "$(dirname "$0")/../.." && pwd)
scene="$repo/tools/compare/grid-items-scene.tsv"
dir=/Applications/LPGridScene
paging_scene="$repo/tools/compare/page-control-scene.tsv"
paging_dir=/Applications/LPPageScene

vm() { ssh -o BatchMode=yes "$vm_dest" "$@"; }

# In the comparison VM, makes this project's background process scan /Applications fully once.
rescan_launchpad() {
    [[ $(vm sw_vers -productVersion) == 15.* ]] && return
    vm "set -e; db=\$(getconf DARWIN_USER_DIR)io.github.wljf817.LaunchPad.launchpad/db/db; pkill -STOP -x LaunchPadAgent; sqlite3 \"\$db\" \"UPDATE app_sources SET fsevent_uuid = NULL WHERE uuid = 'system'\"; pkill -KILL -x LaunchPadAgent; sleep 10; pgrep -x LaunchPadAgent >/dev/null"
}

# Title of every app, in the order of the scene file ($1, default the grid-items-still scene).
titles() { grep -v '^#' "${1:-$scene}" | cut -f1; }
# The shell commands that install the apps of scene file $1 in directory $2, bundle identifiers
# with prefix $3.
install_script() {
    local file=$1 target=$2 prefix=$3 n=0 title app plist
    printf '%s' "; sudo rm -rf '$target'; sudo mkdir -p '$target'; sudo chown \$(id -u):\$(id -g) '$target'"
    while IFS= read -r title; do
        n=$((n + 1))
        app="$target/$title.app"
        plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>app</string><key>CFBundleIdentifier</key><string>$prefix.$n</string><key>CFBundleName</key><string>$title</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>"
        printf '%s' "; mkdir -p '$app/Contents/MacOS'; cp /usr/bin/true '$app/Contents/MacOS/app'; printf '%s' '$plist' > '$app/Contents/Info.plist'"
    done < <(titles "$file")
    printf '%s' "; for a in '$target'/*.app; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"\$a\"; done; ls '$target' | wc -l"
}
# The shell commands that remove directory $1 and unregister its apps.
remove_script() {
    printf '%s' "; for a in '$1'/*.app; do [ -e \"\$a\" ] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u \"\$a\" || true; done; sudo rm -rf '$1'; [ ! -e '$1' ] && echo removed"
}

case $action in
    install)
        script="set -e$(install_script "$scene" "$dir" io.github.wljf817.lptest.grid)"
        if [[ -n $paging ]]; then
            script+=$(install_script "$paging_scene" "$paging_dir" io.github.wljf817.lptest.page)
        fi
        vm "$script"
        rescan_launchpad
        ;;
    remove)
        script="set -e$(remove_script "$dir")"
        if [[ -n $paging ]]; then
            script+=$(remove_script "$paging_dir")
        fi
        vm "$script"
        rescan_launchpad
        ;;
    list)
        titles
        if [[ -n $paging ]]; then
            titles "$paging_scene"
        fi
        ;;
    *)
        echo "usage: $0 <user>@<vm-address> install|remove|list [--paging]" >&2
        exit 2
        ;;
esac
