#!/bin/bash
# Build LaunchPad from the working tree and install it in the macOS 26 comparison VM.
#
# Builds LaunchPad.app with scripts/build-app.sh, installs the bundle as
# /Applications/LaunchPad.app, registers it with Launch Services, restarts
# LaunchPad's background process (the launchd agent io.github.wljf817.LaunchPad)
# from the new bundle, or on the first install runs the launcher twice so that
# it registers the agent and leaves Launchpad closed, and checks that both
# installed executables have the build's SHA-256. Then opens and closes Launchpad once, so that the
# next open is not the first after the background process started. Launchpad is closed afterwards.
# record-launchpad.sh runs it before every take.
#
# Needs key-based SSH login to the VM. Never needs sudo.
#
# Usage: tools/compare/install-launchpad.sh <user>@<vm-address>

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <user>@<vm-address>" >&2; exit 2; }
vm_dest=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/tools/compare/vm-common.sh"

app_path=/Applications/LaunchPad.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

app=$("$repo/scripts/build-app.sh" | tee /dev/stderr | tail -1)
executables=(Contents/MacOS/LaunchPad Contents/Helpers/LaunchPadAgent.app/Contents/MacOS/LaunchPadAgent)
agent_job="gui/\$(id -u)/io.github.wljf817.LaunchPad"
# An earlier single-process build ran as "LaunchPad"; the launcher itself exits at once.
vm "pkill -x LaunchPad; for _ in \$(seq 50); do pgrep -x LaunchPad >/dev/null || break; sleep 0.1; done; ! pgrep -x LaunchPad >/dev/null && rm -rf $app_path.new && mkdir $app_path.new"
COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C "$app" . | vm "tar -xf - -C $app_path.new"
vm "rm -rf $app_path && mv $app_path.new $app_path && $lsregister -f $app_path"
if vm "launchctl print $agent_job >/dev/null 2>&1"; then
    # A rebuilt bundle is a new background item to macOS, which shows its notification again
    # (REF-DEV-013); wait for it to go away.
    vm "launchctl kickstart -k $agent_job; sleep 8"
else
    # The first run registers the agent (macOS shows its background-item notification, REF-DEV-013)
    # and opens Launchpad; the second closes it. Wait for the notification to go away.
    vm "open -a $app_path; sleep 3; open -a $app_path; sleep 8"
fi
vm "for _ in \$(seq 50); do pgrep -x LaunchPadAgent >/dev/null && break; sleep 0.1; done; pgrep -x LaunchPadAgent >/dev/null"
# Open and close once, so that a take records a later open, as the reference takes do: the first
# open after the background process starts is slower.
vm "open -a $app_path; sleep 2; open -a $app_path; sleep 2"
for executable in "${executables[@]}"; do
    local_sum=$(shasum -a 256 "$app/$executable" | cut -d' ' -f1)
    remote_sum=$(vm "shasum -a 256 $app_path/$executable" | cut -d' ' -f1)
    if [[ $local_sum != "$remote_sum" ]]; then
        echo "the installed $executable's SHA-256 $remote_sum differs from the build's $local_sum" >&2
        exit 1
    fi
done
echo "installed $app_path in the VM, background process running" >&2
