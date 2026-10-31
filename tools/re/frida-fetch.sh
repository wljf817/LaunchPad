#!/bin/bash
# Copy the records that tools/re/frida/ca-anim.js wrote in the macOS 15
# reference VM (~/frida-gadget/*.jsonl of the VM account) into
# research/macos-<version>-<build>/frida/ (local only, gitignored). Files
# already fetched are never overwritten; each fetched file is checked against
# its SHA-256 in the VM. The files stay in the VM. Prints the output directory.
#
# Needs key-based SSH login to the VM. Never needs sudo.
#
# Usage: tools/re/frida-fetch.sh <user>@<vm-address>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <user>@<vm-address>" >&2
    exit 2
fi
dest=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)

vm() { ssh -o BatchMode=yes "$dest" "$@"; }

version=$(vm sw_vers -productVersion)
build=$(vm sw_vers -buildVersion)
out="$repo/research/macos-$version-$build/frida"
mkdir -p "$out"

# No AppleDouble files, no extended attributes. -k keeps files already here.
vm 'cd frida-gadget && COPYFILE_DISABLE=1 tar --no-xattrs -cf - *.jsonl' \
    | tar -xkf - -C "$out"

# Every file in the VM must now be here with the same content.
vm 'cd frida-gadget && shasum -a 256 *.jsonl' | (cd "$out" && shasum -a 256 -c --quiet -)

echo "$out"
