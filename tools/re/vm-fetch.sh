#!/bin/bash
# Copy Dock.app, the arm64e dyld shared cache and SystemVersion.plist from the
# macOS 15 reference VM into research/macos-<version>-<build>/ (local only,
# gitignored). Guest paths are kept under root/. Also writes vm-info.txt
# (system version, hardware model, SIP status, boot-args stored in NVRAM and
# boot-args the running kernel was booted with) and SHA256SUMS.
#
# Needs key-based SSH login to the VM. Never needs sudo.
#
# Usage: tools/re/vm-fetch.sh <user>@<vm-address>

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
out="$repo/research/macos-$version-$build"
mkdir -p "$out/root"

# No AppleDouble files, no extended attributes.
remote_tar='COPYFILE_DISABLE=1 tar --no-xattrs -cf -'

vm "cd / && $remote_tar System/Library/CoreServices/SystemVersion.plist System/Library/CoreServices/Dock.app" \
    | tar -xf - -C "$out/root"
vm "cd / && $remote_tar System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e*" \
    | tar -xf - -C "$out/root"

vm 'sw_vers; uname -a; sysctl hw.model; csrutil status; nvram boot-args 2>&1 || true; sysctl kern.bootargs' > "$out/vm-info.txt"

(cd "$out" && find root -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)

echo "$out"
