#!/bin/bash
# Record this project for a scene in the macOS 26 comparison VM and fetch the
# take into research/launchpad/recordings/<scene>/<commit>[-dirty]-<UTC>.mov
# (local only, gitignored).
#
# Refuses to record unless the VM runs REF-ENV-006's system and the scene has a
# reference take. Installs LaunchPad from the working tree with
# install-launchpad.sh. Then runs --before in the VM (for example opening
# Launchpad for a scene that starts open; installing restarts the background
# process, which closes it), records with the
# display mode of REF-ENV-004, refusing when the appearance, languages or
# accessibility settings differ from the scene's reference take, runs --after
# in the VM once recording has stopped, and fetches the take with its
# metadata, checking SHA-256. Takes are never overwritten, and the VM's copies
# are kept. The steps shared with record-vm.sh are in vm-common.sh.
#
# Needs key-based SSH login to the VM and the Screen Recording permission for
# /usr/libexec/sshd-keygen-wrapper in the VM. Never needs sudo.
#
# Usage: tools/compare/record-launchpad.sh <user>@<vm-address> <scene> --pre-roll <s> --duration <s>
#            [--before '<command>'] [--after '<command>'] [--display-name '<name>'] -- <trigger command> [args...]
# Example: tools/compare/record-launchpad.sh shizuku@192.168.64.3 overlay-shell-open --pre-roll 1 --duration 3 \
#            --after 'open -a /Applications/LaunchPad.app' -- open -a /Applications/LaunchPad.app

set -euo pipefail

comparison_system=26.6.2-25G83      # REF-ENV-006
reference_system=macos-15.6.1-24G90 # REF-ENV-001

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

system="$(vm sw_vers -productVersion)-$(vm sw_vers -buildVersion)"
if [[ $system != "$comparison_system" ]]; then
    echo "the VM runs macOS $system, not REF-ENV-006's $comparison_system" >&2
    exit 1
fi

reference="$repo/research/$reference_system/recordings/$scene/reference.json"
if [[ ! -e $reference ]]; then
    echo "$reference does not exist; record the scene's reference take first" >&2
    exit 1
fi

commit=$(git -C "$repo" rev-parse --short HEAD)
dirty=
[[ -z $(git -C "$repo" status --porcelain) ]] || dirty=1
name="$commit${dirty:+-dirty}-$(date -u +%Y%m%dT%H%M%SZ)"
out="$repo/research/launchpad/recordings/$scene"

"$repo/tools/compare/install-launchpad.sh" "$vm_dest"

install_frame_record
remote_home=$(vm 'printf %s "$HOME"')
remote_reference="$remote_home/frame-compare/scenes/$scene.json"
vm "mkdir -p $remote_home/frame-compare/scenes && cat > $remote_reference" < "$reference"

if [[ -n $before ]]; then
    vm "$before"
fi
record_in_vm "$name" --match-scene "$remote_reference" --git-commit "$commit" ${dirty:+--git-dirty}
if [[ -n $after ]]; then
    vm "$after"
fi

fetch_take "$name" "$out"
echo "$out/$name.mov"
exit "$record_status"
