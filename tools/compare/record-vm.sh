#!/bin/bash
# Record a reference take of a scene in the macOS 15 reference VM and fetch it
# into research/macos-<version>-<build>/recordings/<scene>/ (local only,
# gitignored).
#
# Copies frame-record to ~/frame-compare/ in the VM when it changed, refuses
# to record while a Frida client is attached to Dock's gadget, runs --before
# (for example opening Launchpad for a scene that starts open), records with
# the display mode of REF-ENV-004, runs --after (for example closing
# Launchpad again) once recording has stopped, and fetches the take with its
# metadata, checking SHA-256. Takes are never overwritten, and the VM's copies
# are kept. The steps shared with record-launchpad.sh are in vm-common.sh.
#
# Needs key-based SSH login to the VM and the Screen Recording permission for
# /usr/libexec/sshd-keygen-wrapper in the VM. Never needs sudo.
#
# Usage: tools/compare/record-vm.sh <user>@<vm-address> <scene> --pre-roll <s> --duration <s>
#            [--before '<command>'] [--after '<command>'] [--display-name '<name>'] -- <trigger command> [args...]
# Example: tools/compare/record-vm.sh shizuku@192.168.64.2 overlay-open --pre-roll 1 --duration 3 \
#            --after 'open -a Launchpad' -- open -a Launchpad

set -euo pipefail

gadget_port=27043 # REF-ENV-003

usage() {
    echo "usage: $0 <user>@<vm-address> <scene> --pre-roll <s> --duration <s> [--before '<command>'] [--after '<command>'] [--display-name '<name>'] -- <trigger> [args...]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
vm_dest=$1
shift
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/tools/compare/vm-common.sh"
parse_record_args "$@"

version=$(vm sw_vers -productVersion)
build=$(vm sw_vers -buildVersion)
out="$repo/research/macos-$version-$build/recordings/$scene"
mkdir -p "$out"

install_frame_record

# Reference takes are recorded without a Frida client attached to Dock.
if [[ -n $(vm "lsof -nP -iTCP:$gadget_port -sTCP:ESTABLISHED 2>/dev/null || true") ]]; then
    echo "a Frida client is connected to the gadget on port $gadget_port; detach it first" >&2
    exit 1
fi
dock_pid=$(vm pgrep -x Dock)
if vm "lsof -p $dock_pid 2>/dev/null || true" | grep -q frida-gadget; then gadget=true; else gadget=false; fi

take="take-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -n $before ]]; then
    vm "$before"
fi
record_in_vm "$take" --dock-gadget-loaded "$gadget"
if [[ -n $after ]]; then
    vm "$after"
fi

fetch_take "$take" "$out"
echo "$out/$take.mov"
exit "$record_status"
