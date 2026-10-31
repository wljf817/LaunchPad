// Attach check for Dock in the macOS 15 reference VM. Frida 17 core API only:
// no Objective-C bridge is assumed; objcBridge reports whether one is present.
//
// Load through REA: start_frida_session { mode: "attach", pid, remote }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/attach-check.js" }.
//
// cpuSubtype is read from the main module's Mach-O header (offset 8, capability
// bits masked off); 2 means arm64e.

const main = Process.mainModule;

send({
  frida: Frida.version,
  pid: Process.id,
  arch: Process.arch,
  platform: Process.platform,
  cpuSubtype: main.base.add(8).readU32() & 0x00ffffff,
  mainModule: main.path,
  objcBridge: typeof ObjC !== 'undefined',
});
