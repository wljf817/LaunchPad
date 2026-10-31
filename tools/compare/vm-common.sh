#!/bin/bash
# Shared by record-vm.sh (reference takes in the macOS 15 reference VM) and
# record-launchpad.sh (this project in the macOS 26 comparison VM): argument
# parsing, copying frame-record into the VM, recording there and fetching the
# take. Sourced by those scripts, not run on its own. The caller defines usage
# and sets vm_dest (<user>@<vm-address>) and repo (the repository root) first.

expected_mode=1536x960@1x60 # REF-ENV-004

vm() { ssh -o BatchMode=yes "$vm_dest" "$@"; }

# Parses <scene> --pre-roll <s> --duration <s> [--before '<command>'] [--after '<command>']
# [--display-name '<name>'] -- <trigger> [args...] into scene, pre_roll, duration, before, after,
# display_name and the array trigger. --display-name records the display of that name (the second
# display of the multi-display scenes, REF-ENV-009) instead of the main display.
parse_record_args() {
    [[ $# -ge 1 ]] || usage
    scene=$1
    shift
    [[ $scene =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "scene must be kebab-case: $scene" >&2; exit 2; }
    pre_roll=
    duration=
    before=
    after=
    display_name=
    while [[ $# -gt 0 ]]; do
        case $1 in
            --pre-roll) [[ $# -ge 2 ]] || usage; pre_roll=$2; shift 2 ;;
            --duration) [[ $# -ge 2 ]] || usage; duration=$2; shift 2 ;;
            --before) [[ $# -ge 2 ]] || usage; before=$2; shift 2 ;;
            --after) [[ $# -ge 2 ]] || usage; after=$2; shift 2 ;;
            --display-name) [[ $# -ge 2 ]] || usage; display_name=$2; shift 2 ;;
            --) shift; break ;;
            *) usage ;;
        esac
    done
    [[ -n $pre_roll && -n $duration && $# -gt 0 ]] || usage
    trigger=("$@")
}

# Builds frame-record, vm-input and virtual-display and copies each to
# ~/frame-compare/ in the VM when the VM's copy differs.
install_frame_record() {
    local package="$repo/tools/compare" product bin local_sum remote_sum
    for product in frame-record vm-input virtual-display; do
        swift build --package-path "$package" -c release --product "$product" >&2
        bin="$(swift build --package-path "$package" -c release --show-bin-path)/$product"
        local_sum=$(shasum -a 256 "$bin" | cut -d' ' -f1)
        remote_sum=$(vm "shasum -a 256 \"\$HOME/frame-compare/$product\" 2>/dev/null | cut -d' ' -f1" || true)
        if [[ $local_sum != "$remote_sum" ]]; then
            vm "mkdir -p \"\$HOME/frame-compare/takes\" && cat > \"\$HOME/frame-compare/$product.new\" && chmod +x \"\$HOME/frame-compare/$product.new\" && mv \"\$HOME/frame-compare/$product.new\" \"\$HOME/frame-compare/$product\"" < "$bin"
        fi
    done
}

# Records ~/frame-compare/takes/<name>.mov and .json in the VM with the
# expected display mode, pre_roll, duration and trigger; further arguments go
# to frame-record before the trigger. Sets record_status to frame-record's
# exit status.
record_in_vm() {
    local name=$1 extra= id
    shift
    if [[ -n $display_name ]]; then
        id=$(vm "\$HOME/frame-compare/frame-record displays" | awk -v name="$display_name" -F'[ :,]+' '$1 == "display" && index($0, ": " name ",") {print $2}')
        [[ -n $id ]] || { echo "no display named $display_name in the VM" >&2; exit 1; }
        set -- --display "$id" "$@"
    fi
    [[ $# -eq 0 ]] || extra=$(printf '%q ' "$@")
    set +e
    vm "mkdir -p \$HOME/frame-compare/takes && \$HOME/frame-compare/frame-record record --out \$HOME/frame-compare/takes/$name.mov --expect $expected_mode --pre-roll $(printf '%q' "$pre_roll") --duration $(printf '%q' "$duration") $extra-- $(printf '%q ' "${trigger[@]}")"
    record_status=$?
    set -e
}

# Copies <name>.mov and <name>.json from the VM's takes directory into <dir>,
# never overwriting, and checks their SHA-256 against the VM's copies.
fetch_take() {
    local name=$1 dir=$2 sums
    if ! vm "test -f \$HOME/frame-compare/takes/$name.json"; then
        echo "no take recorded; frame-record's message above says why" >&2
        exit "$record_status"
    fi
    mkdir -p "$dir"
    vm "cd \$HOME/frame-compare/takes && COPYFILE_DISABLE=1 tar --no-xattrs -cf - $name.mov $name.json" | tar -xkf - -C "$dir"
    sums=$(vm "cd \$HOME/frame-compare/takes && shasum -a 256 $name.mov $name.json")
    (cd "$dir" && shasum -a 256 -c - <<< "$sums" >&2)
}

# The second display of the multi-display scenes (REF-ENV-009): 1536 x 960
# points like the VM's own display, switching to 1280 x 800 on SIGUSR1.
virtual_display_args="1536 960 --alt 1280x800"

# Prints the number of displays in the VM.
display_count() {
    vm "osascript -l JavaScript -e 'ObjC.import(\"AppKit\"); \$.NSScreen.screens.count'"
}

# Waits up to 10 s until the VM has <count> displays.
wait_for_display_count() {
    local count=$1 i
    for i in $(seq 1 50); do
        [[ $(display_count) == "$count" ]] && return 0
        sleep 0.2
    done
    echo "the VM does not have $count displays" >&2
    return 1
}

# Adds the second display: starts ~/frame-compare/virtual-display in the
# logged-in user's session (it needs the window server of that session), and
# waits for it. Its output goes to ~/frame-compare/virtual-display.log.
start_virtual_display() {
    vm "pgrep -x virtual-display >/dev/null" && { echo "virtual-display is already running" >&2; return 1; }
    vm "sudo launchctl asuser \$(id -u) sudo -u \$(id -un) sh -c 'nohup \$HOME/frame-compare/virtual-display $virtual_display_args > \$HOME/frame-compare/virtual-display.log 2>&1 &'"
    wait_for_display_count 2
}

# Switches the second display between its two modes.
switch_virtual_display() {
    vm "pkill -USR1 -x virtual-display"
}

# Removes the second display.
stop_virtual_display() {
    vm "pkill -x virtual-display || true"
    wait_for_display_count 1
}

# Prints the frame of the Dock's window at the Dock window level, which covers
# the display the Dock is on (REF-DEV-029), as x,y,width,height in global
# points; nothing when there is none on screen.
dock_window_frame() {
    vm "osascript -l JavaScript -e 'ObjC.import(\"AppKit\"); ObjC.import(\"CoreGraphics\"); const dock = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier(\"com.apple.dock\").js[0]; const level = \$.CGWindowLevelForKey(7); const windows = ObjC.deepUnwrap(ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(1, 0))); windows.filter(w => w.kCGWindowOwnerPID == dock.processIdentifier && w.kCGWindowLayer == level).map(w => [w.kCGWindowBounds.X, w.kCGWindowBounds.Y, w.kCGWindowBounds.Width, w.kCGWindowBounds.Height].join(\",\")).join(\" \")'"
}

# Moves the Dock to the display whose bounds are <x>,<y>,<width>,<height> in
# global points, as a user does: the pointer goes down to that display's bottom
# edge and pushes against it, with vm-input move. Retries up to three times and
# fails when the Dock's window is not on that display afterwards.
push_dock_to_display() {
    local frame=$1 x y width height cx bottom attempt input=\$HOME/frame-compare/vm-input
    IFS=, read -r x y width height <<< "$frame"
    cx=$((x + width / 2))
    bottom=$((y + height - 1))
    for attempt in 1 2 3; do
        [[ $(dock_window_frame) == "$frame" ]] && return 0
        vm "$input move $cx $((y + height / 2)); sleep 0.2; for dy in 200 100 40 10 1; do $input move $cx \$(($bottom - \$dy)); sleep 0.05; done; for i in \$(seq 1 20); do $input move $cx $bottom; sleep 0.05; done"
        sleep 1.5
    done
    [[ $(dock_window_frame) == "$frame" ]] && return 0
    echo "the Dock did not move to the display at $frame" >&2
    return 1
}
