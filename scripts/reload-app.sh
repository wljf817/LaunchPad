#!/bin/bash
# Builds LaunchPad.app with build-app.sh and restarts LaunchPad's background process on this Mac
# from the new build. The last line of output is the path of the app bundle, as build-app.sh's.
#
# On macOS 27 smd submits the agent's launchd job with a launch constraint (LWCR in
# `launchctl print`) on the cdhash that Background Task Management recorded for the agent, also
# when it is signed with a certificate, so launchd refuses to start a rebuilt agent from that job
# (OS_REASON_CODESIGNING).
# launchd then asks smd for an updated constraint at the next spawn; that fails for this agent, but
# makes Background Task Management record the new cdhash. Registering the agent again afterwards
# submits a job that starts the new build. The launcher only registers the agent while it is not
# registered (REF-DEV-013), so this script does it with scripts/agent-service.swift, run from
# inside the bundle. On macOS 26 a rebuilt agent starts from the job submitted for an earlier
# build, so the comparison VM only needs a kickstart (tools/compare/install-launchpad.sh).

set -euo pipefail

cd "$(dirname "$0")/.."

app=$(scripts/build-app.sh | tee /dev/stderr | tail -1)
agent_app="$app/Contents/Helpers/LaunchPadAgent.app"
job="gui/$(id -u)/io.github.wljf817.LaunchPad"
cdhash=$(codesign -dvvv "$agent_app" 2>&1 | sed -n 's/^CDHash=//p')

field() { launchctl print "$job" 2>/dev/null | sed -n "s/^	$1 = //p"; }
new_build_runs() {
    local pid
    pid=$(field pid)
    # Reads all of codesign's output: grep -q would exit at the match, and codesign's later writes
    # would fail with SIGPIPE, which pipefail turns into a failed check.
    [[ -n $pid && $(codesign -dvvv "$pid" 2>&1 | sed -n 's/^CDHash=//p') == "$cdhash" ]]
}
# Starts the job and waits until the spawn has started the new build (status 0) or failed (1).
spawn() {
    local runs
    runs=$(field runs)
    launchctl kickstart "$@" "$job"
    for _ in $(seq 50); do
        new_build_runs && return 0
        [[ $(field runs) != "$runs" && $(field "job state") == "spawn failed" ]] && return 1
        sleep 0.1
    done
    return 1
}
finish() {
    echo "background process $(field pid) runs the new build (cdhash $cdhash)" >&2
    echo "$app"
    exit 0
}

if launchctl print "$job" >/dev/null 2>&1; then
    spawn -k && finish
    # The spawn at which launchd asks smd for an updated constraint.
    spawn || true
fi
echo "registering the agent again" >&2

helper_dir=$(mktemp -d)
helper="$app/Contents/MacOS/agent-service"
trap 'rm -rf "$helper_dir" "$helper"' EXIT
swiftc -o "$helper_dir/agent-service" scripts/agent-service.swift
cp "$helper_dir/agent-service" "$helper"
# Registers the agent again and waits until the new build runs (status 0) or not (1).
reregister() {
    "$helper" unregister
    # Unregistering returns before launchd has stopped the agent and removed its job, and registering
    # while the job is still there leaves the old job in place.
    for _ in $(seq 100); do
        launchctl print "$job" >/dev/null 2>&1 || break
        sleep 0.1
    done
    "$helper" register
    for _ in $(seq 50); do
        new_build_runs && return 0
        sleep 0.1
    done
    return 1
}
# When the job from the first registration still refuses the new build, register once more.
reregister || { echo "registering the agent once more" >&2; reregister; } || {
    echo "launchd does not run the new build: $(launchctl print "$job" 2>&1 | grep -E 'job state|last exit')" >&2
    exit 1
}
rm "$helper"
finish
