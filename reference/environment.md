# Environment

The reference environment that every measurement in `reference/` is taken in.

## REF-ENV-001 Reference system version and hardware model

- **Status:** measured
- **Value:**
  - macOS 15.6.1, build 24G90
  - Hardware model: VirtualMac2,1
  - Kernel: Darwin 24.6.0, `xnu-11417.140.69~1/RELEASE_ARM64_VMAPPLE`
- **Source:** `sw_vers`, `uname -a` and `sysctl hw.model` in the reference VM over SSH, saved by `tools/re/vm-fetch.sh` to `research/macos-15.6.1-24G90/vm-info.txt`; update settings with `defaults read /Library/Preferences/com.apple.SoftwareUpdate`.
- **Environment:** —
- **Date:** 2026-10-16
- **Notes:** First confirmation inside the VM; it matches the restore image the VM was created from (`UniversalMac_15.6.1_24G90_Restore.ipsw`). Automatic updates are off: `AutomaticDownload`, `CriticalUpdateInstall` and `ConfigDataInstall` are 0, `AutomaticallyInstallMacOSUpdates` is not set. Software Update offers macOS 15.8.1 and macOS 27.0.1; installing either would change this entry. After a version change, fetch again into a new `research/macos-<version>-<build>/` and update this entry.

## REF-ENV-002 Virtualization host

- **Status:** measured
- **Value:**
  - Host: Mac16,1 (Apple M4), macOS 27.0.1 (26A434)
  - Virtualization: UTM 4.7.5 with the Apple Virtualization framework backend
- **Source:** on the host: `sysctl hw.model machdep.cpu.brand_string`, `sw_vers`, `utmctl version`, and the running `com.apple.Virtualization.VirtualMachine` process that hosts the VM.
- **Environment:** —
- **Date:** 2026-10-16

## REF-ENV-003 Instrumentation setup

- **Status:** measured
- **Value:**
  - SIP: disabled
  - boot-args: `-arm64e_preview_abi`, stored in NVRAM and active in the running kernel
  - Frida client: Frida 17.23.2, the npm package `frida` bundled with REA (rea-agents 6.5.0)
  - Injection: frida-gadget 17.23.2 (`frida-gadget-17.23.2-macos-universal.dylib`, slices x86_64, arm64, arm64e), loaded by Dock at launch through `DYLD_INSERT_LIBRARIES`, listening on 127.0.0.1:27043 inside the VM; reached from the host through an SSH port forward
  - Attaching to Dock and loading `tools/re/frida/attach-check.js`: works. The script reports Frida 17.23.2, CPU subtype 2 (arm64e) and main module `/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock`; Dock keeps its pid after detaching
  - Objective-C bridge (`ObjC`) in scripts loaded through REA: not available
  - frida-server (injection from outside): does not work in this VM, see Notes
- **Source:** `csrutil status`, `nvram boot-args` and `sysctl kern.bootargs` in the VM over SSH (saved to `vm-info.txt` by `tools/re/vm-fetch.sh`); the version of REA's bundled `frida` package; `tools/re/frida-gadget-install.sh`, `tools/re/frida-gadget-dock.sh` and `tools/re/frida-tunnel.sh`; REA `list_frida_processes`, `start_frida_session`, `load_frida_script` and `close_frida_session` with `tools/re/frida/attach-check.js`. Evidence in `research/macos-15.6.1-24G90/notes/frida-attach.md`.
- **Environment:** REF-ENV-001, REF-ENV-002
- **Date:** 2026-10-16
- **Notes:** frida-server 17.24.0, both the `macos-arm64` and the `macos-arm64e` build, listed the VM's processes but could not attach to any of Dock, Finder, SystemUIServer or `/usr/bin/caffeinate`: every attach failed with `Unexpected error while starting thread (thread_create returned '(os/kern) protection failure')`, also after a VM reboot, and the targets kept their pids. The frida-server binary is signed with the Frida author's Developer ID and has no entitlements. Public reports of the same failure on macOS 14.5 and later attribute it to a kernel restriction on remote thread creation and `thread_set_state` for callers without the Apple-private entitlement `com.apple.private.thread-set-state`; that is not verified here. A gadget loaded by the target needs no remote thread, which is why it works. The gadget is checked against the release SHA-256 `6e0d65e83bfaae6a32f021b081cf7e2f3b3625818e3b47a822844ee570cded09` of the `.xz` asset. A frida-server LaunchDaemon `re.frida.server` (17.24.0 arm64e, installed by hand) is still present in the VM; nothing uses it.
