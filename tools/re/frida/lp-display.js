// Trace how the macOS 15 Launchpad in Dock (reference VM) follows the displays:
// Dock's display reconfiguration callback and the block it dispatches to the
// main queue, Dock moving to another display, and Launchpad's display methods
// and closes. Frida 17 core API only: scripts loaded through REA have no
// Objective-C bridge (REF-ENV-003), so Objective-C is driven through the
// runtime's C functions and objc_msgSend, as in lp-launch.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-display.js" }.
// Add, remove or switch the second display with tools/compare's virtual-display
// (vm-common.sh) and move the Dock with vm-input. Fetch the file with
// tools/re/frida-fetch.sh.
//
// The callback, its block and Dock's switch to another display are functions
// without Objective-C names; they are hooked at their addresses in Dock 1.8
// (build 2341.6.1) of macOS 15.6.1 (REF-ENV-001), as are the Dock globals read
// below. Other builds need the addresses again (research paper §3.4).
//
// File: $HOME/frida-gadget/lp-display-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written. Every line is
// also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main
// (whether the call runs on the main thread):
//   header  frida, pid, utc, globals (the class of each Dock global used),
//           started (Dock's started flag), state
//   call    ph "enter" | "leave", fn, and per function: display and flags (the
//           callback and its block; the block also the pending mark), to (the
//           display Dock switches to), visible and reason (the closes), state
//   note    hooks not installed
// state: dockDisplay (DockBar's display), visible (Launchpad's _visible),
// lastDisplay (Launchpad's _lastDisplay).
//
// Nothing is written to Dock's objects.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  return new NativeFunction(Module.getGlobalExportByName(name), ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const CACurrentMediaTime = gf('CACurrentMediaTime', 'double', []);
const getenv = gf('getenv', 'pointer', ['pointer']);
const pthread_main_np = gf('pthread_main_np', 'int', []);

const sels = new Map();
function sel(name) {
  let s = sels.get(name);
  if (s === undefined) {
    s = sel_registerName(Memory.allocUtf8String(name));
    sels.set(name, s);
  }
  return s;
}
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}
function string(obj) {
  if (obj.isNull()) return null;
  const p = msgP(obj, sel('UTF8String'));
  return p.isNull() ? null : p.readUtf8String();
}

// --- Dock addresses (macOS 15.6.1, REF-ENV-001) ----------------------------

const dock = Process.getModuleByName('Dock');
function fileAddress(address) {
  return dock.base.add(ptr(address).sub(ptr('0x100000000')));
}
const ADDRESS = {
  callback: '0x10010befc',   // the display reconfiguration callback
  block: '0x10010c774',      // its block on the main queue
  dockSwitch: '0x10010c250', // DockBar moving to another display
  started: '0x10043b960',    // Dock's started flag
  pending: '0x10043b961',    // the pending mark
};
const GLOBALS = {
  dockBar: '0x100448138',
  launchpad: '0x100448168',
  spaces: '0x100448178',
  expose: '0x100448190',
  hotCorners: '0x100448160',
  notificationCenter: '0x100448148',
};
function global(name) {
  return fileAddress(GLOBALS[name]).readPointer();
}

const dockBar = global('dockBar');
const launchpad = global('launchpad');
const lastDisplayOffset = ivar_getOffset(class_getInstanceVariable(cls('Springboard'), Memory.allocUtf8String('_lastDisplay'))).toNumber();

function state() {
  const display = msgP(dockBar, sel('display'));
  return {
    dockDisplay: display.isNull() ? 0 : msgU32(display, sel('identifier')),
    visible: msgB(launchpad, sel('visible')),
    lastDisplay: launchpad.add(lastDisplayOffset).readU32(),
  };
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-display-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

const globals = {};
for (const name of Object.keys(GLOBALS)) globals[name] = className(global(name));
write({ type: 'header', frida: Frida.version, pid: Process.id, utc, globals,
        started: fileAddress(ADDRESS.started).readU8(), state: state() });

// --- hooks ----------------------------------------------------------------

function hookFunction(fn, address, enter, leave) {
  Interceptor.attach(fileAddress(address), {
    onEnter(args) { write(Object.assign({ type: 'call', ph: 'enter', fn }, enter ? enter(args) : {})); },
    onLeave() { if (leave) write(Object.assign({ type: 'call', ph: 'leave', fn }, leave())); },
  });
}

function hookMethod(clsName, selName, enter, leave) {
  const c = cls(clsName);
  const m = c.isNull() ? ptr(0) : class_getInstanceMethod(c, sel(selName));
  if (m.isNull()) {
    write({ type: 'note', msg: 'not hooked: ' + clsName + ' ' + selName });
    return;
  }
  const fn = clsName + '.' + selName;
  Interceptor.attach(method_getImplementation(m), {
    onEnter(args) { write(Object.assign({ type: 'call', ph: 'enter', fn, self: className(args[0]) }, enter ? enter(args) : {})); },
    onLeave() { if (leave) write(Object.assign({ type: 'call', ph: 'leave', fn }, leave())); },
  });
}

const hex = (n) => '0x' + (n >>> 0).toString(16);

hookFunction('displayReconfigurationCallback', ADDRESS.callback,
  (a) => ({ display: a[0].toUInt32(), flags: hex(a[2].toUInt32()) }));
hookFunction('displayReconfigurationBlock', ADDRESS.block,
  (a) => ({ display: a[0].add(0x2c).readU32(), flags: hex(a[0].add(0x28).readU32()),
            pending: fileAddress(ADDRESS.pending).readU8(), state: state() }),
  () => ({ state: state() }));
hookFunction('DockBar.switchToDisplay', ADDRESS.dockSwitch,
  (a) => ({ to: a[1].isNull() ? 0 : msgU32(a[1], sel('identifier')), state: state() }),
  () => ({ state: state() }));

hookMethod('Springboard', 'displayChanged', () => ({ state: state() }), () => ({ state: state() }));
hookMethod('Springboard', 'checkAndUpdateIfDisplayChanged', () => ({ state: state() }), () => ({ state: state() }));
hookMethod('Springboard', 'setVisible:reason:', (a) => ({ visible: (a[2].toUInt32() & 1) === 1, reason: string(a[3]) }));
hookMethod('LPSpringboard', 'setVisible:slow:forGaming:reason:', (a) => ({ visible: (a[2].toUInt32() & 1) === 1, reason: string(a[5]) }));
hookMethod('Springboard', 'performExitAnimation:');
hookMethod('Springboard', 'orderWindowOn:', (a) => ({ on: (a[2].toUInt32() & 1) === 1 }));
hookMethod('ECSBSpringboard', 'setVisible:', (a) => ({ visible: (a[2].toUInt32() & 1) === 1 }));
hookMethod('ECSBSpringboard', 'invalidate');
hookMethod('Spaces', 'handleDisplayReconfig');
hookMethod('DockVisibility', 'forceDockOntoDisplayAtLocation:');
