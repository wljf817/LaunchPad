#!/bin/bash
# Install frida-gadget in the macOS 15 reference VM under ~/frida-gadget/ of
# the VM account. Dock loads it at launch (see tools/re/frida-gadget-dock.sh)
# and the gadget listens on 127.0.0.1:27043 inside the VM; the host reaches it
# through tools/re/frida-tunnel.sh.
#
# frida-server cannot inject into processes in this VM: creating a thread in
# another task fails with "(os/kern) protection failure" (REF-ENV-003). A
# gadget loaded by the target itself needs no remote thread.
#
# Needs key-based SSH login to the VM. Never needs sudo.
#
# VERSION must equal the Frida bundled with REA (the npm package "frida"
# inside rea-agents). When REA updates it, change VERSION and XZ_SHA256 to the
# matching frida-gadget-<version>-macos-universal.dylib.xz release asset. The
# universal dylib must contain an arm64e slice, because Dock is arm64e.
#
# Usage: tools/re/frida-gadget-install.sh <user>@<vm-address> <frida-gadget-17.23.2-macos-universal.dylib.xz>

set -euo pipefail

VERSION=17.23.2
# SHA-256 of frida-gadget-17.23.2-macos-universal.dylib.xz, from the GitHub release metadata.
XZ_SHA256=6e0d65e83bfaae6a32f021b081cf7e2f3b3625818e3b47a822844ee570cded09
PORT=27043

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <user>@<vm-address> <frida-gadget-$VERSION-macos-universal.dylib.xz>" >&2
    exit 2
fi
dest=$1
xz_file=$2

actual=$(shasum -a 256 "$xz_file" | cut -d ' ' -f 1)
if [[ $actual != "$XZ_SHA256" ]]; then
    echo "SHA-256 of $xz_file is $actual, expected $XZ_SHA256" >&2
    exit 1
fi

vm() { ssh -o BatchMode=yes "$dest" "$@"; }

vm 'mkdir -p frida-gadget'
xz -dc "$xz_file" | vm 'cat > frida-gadget/frida-gadget.dylib'

# Read by the gadget from the file next to the dylib with the same base name.
vm 'cat > frida-gadget/frida-gadget.config' <<EOF
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": $PORT,
    "on_port_conflict": "pick-next",
    "on_load": "resume"
  }
}
EOF

# Run in the VM's GUI session by tools/re/frida-gadget-dock.sh: launchctl
# setenv only reaches Dock's launchd domain from that session, not from SSH.
# The variable is removed again right after Dock relaunches, so apps started
# later do not load the gadget.
vm 'cat > frida-gadget/restart-dock-with-gadget.command' <<'EOF'
#!/bin/sh
launchctl setenv DYLD_INSERT_LIBRARIES "$HOME/frida-gadget/frida-gadget.dylib"
killall Dock
sleep 3
launchctl unsetenv DYLD_INSERT_LIBRARIES
echo "Dock restarted with frida-gadget. This window can be closed."
EOF
vm 'chmod 755 frida-gadget/restart-dock-with-gadget.command'

echo "frida-gadget $VERSION installed in ~/frida-gadget of $dest"
