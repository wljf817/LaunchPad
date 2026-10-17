#!/bin/bash
# Restart Dock in the macOS 15 reference VM so that it loads frida-gadget
# (installed by tools/re/frida-gadget-install.sh), then wait until the gadget
# listens on 127.0.0.1:27043 inside the VM. Prints Dock's new pid.
#
# Opens ~/frida-gadget/restart-dock-with-gadget.command, which runs in the
# VM's GUI session (a Terminal window appears in the VM). Needed after every
# VM reboot or Dock restart. Needs a logged-in desktop and key-based SSH login;
# never needs sudo.
#
# Usage: tools/re/frida-gadget-dock.sh <user>@<vm-address>

set -euo pipefail

PORT=27043

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <user>@<vm-address>" >&2
    exit 2
fi

ssh -o BatchMode=yes "$1" "open ~/frida-gadget/restart-dock-with-gadget.command
for i in \$(seq 20); do
    sleep 1
    pid=\$(pgrep -x Dock || true)
    if [ -n \"\$pid\" ] && lsof -nP -a -p \"\$pid\" -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
        echo \"Dock pid \$pid, frida-gadget listening on 127.0.0.1:$PORT\"
        exit 0
    fi
done
echo 'frida-gadget did not start listening in Dock' >&2
exit 1"
