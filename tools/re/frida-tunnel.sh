#!/bin/bash
# Forward 127.0.0.1:27043 on the host to frida-gadget in Dock inside the
# macOS 15 reference VM, which listens on the VM's loopback only (see
# tools/re/frida-gadget-install.sh and tools/re/frida-gadget-dock.sh). REA then
# connects with remote: {address: "127.0.0.1:27043"}.
#
# The forward runs in the background and ends when its SSH connection drops,
# for example when the VM reboots; rerun this script then. It needs key-based
# SSH login to the VM and never asks for a password. It fails if the host
# port is already taken, for example by a forward that is still running.
#
# Usage: tools/re/frida-tunnel.sh <user>@<vm-address>

set -euo pipefail

PORT=27043

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <user>@<vm-address>" >&2
    exit 2
fi

exec ssh -f -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -L "127.0.0.1:$PORT:127.0.0.1:$PORT" "$1"
