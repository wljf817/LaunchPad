// Time the path of a key from the window server to the screen, in the macOS 15 Launchpad in Dock
// (reference VM) and in this project's background process (LaunchPadAgent, comparison VM): when the
// process receives the event, when the controller handles it and its -keyDown:, the selection and
// launch calls on the way, and the Core Animation transactions the main thread commits meanwhile.
// One clock per VM: every line has t = CACurrentMediaTime() in seconds, the clock of frame-record's
// frame times, so the lines line up with a take recorded at the same time.
// Frida 17 core API only (no Objective-C bridge), as lp-keyboard.js.
//
// Load through REA into Dock (frida-gadget-dock.sh) or into the agent started with frida-gadget
// listening, as lp-keyboard.js and lp-keyboard-launchpad.js.
//
// File: $HOME/frida-gadget/lp-key-latency-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Nothing is sent as a message, so that no line waits
// on the client.
//
// Lines ("k"), each with t and, for calls, main (whether on the main thread):
//   header    frida, pid, process, mach timebase (numer, denom), t and mach_absolute_time() at load,
//             and which hooks were installed
//   recv      the process takes events from the window server: in Dock its event port's callback
//             (ph enter | leave); in the agent -[NSApplication nextEventMatchingMask:untilDate:
//             inMode:dequeue:] returning an event (type, ts = the event's CGEventGetTimestamp)
//   send      the agent's -[NSApplication sendEvent:] (ph enter | leave, type)
//   he        -[Springboard handleEvent:] (ph enter | leave): type, keyCode, ts, flags; leave has ret
//   kd        -[Springboard keyDown:] (ph enter | leave)
//   ku        -[Springboard keyUp:] (ph enter | leave)
//   sel       the selected item or an item layer's selected flag is set (fn, ph)
//   launch    the launch path: _launchRunnable, performOpenAnimation, setVisible (fn, ph)
//   flush     +[CATransaction flush] on the main thread (ph)
//   commit    +[CATransaction commit] on the main thread (ph)
//   cacommit  CA::Transaction::commit() on the main thread (ph), when its symbol resolves
//   note      hooks not installed, failures
// CA lines are written only within 0.5 s after a key event reached the controller, to keep the
// file small. Nothing is written to the process's objects.

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
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const CGEventGetType = gf('CGEventGetType', 'uint32', ['pointer']);
const CGEventGetTimestamp = gf('CGEventGetTimestamp', 'uint64', ['pointer']);
const CGEventGetFlags = gf('CGEventGetFlags', 'uint64', ['pointer']);
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
const pthread_main_np = gf('pthread_main_np', 'int', []);
const mach_absolute_time = gf('mach_absolute_time', 'uint64', []);
const mach_timebase_info = gf('mach_timebase_info', 'int', ['pointer']);
const getenv = gf('getenv', 'pointer', ['pointer']);

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

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-key-latency-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj, t) {
  obj.t = t === undefined ? CACurrentMediaTime() : t;
  file.write(JSON.stringify(obj) + '\n');
  file.flush();
}
const isMain = () => pthread_main_np() === 1;

// CA lines only shortly after a key event.
let armedUntil = 0;
const armed = t => t <= armedUntil;

// --- hooks ----------------------------------------------------------------

const installed = [];
function attach(name, address, callbacks) {
  if (address === null || address.isNull()) {
    write({ k: 'note', text: 'not found: ' + name });
    return;
  }
  try {
    Interceptor.attach(address, callbacks);
    installed.push(name);
  } catch (e) {
    write({ k: 'note', text: 'not attached: ' + name + ': ' + e });
  }
}
function imp(className_, selector, classMethod) {
  const c = cls(className_);
  if (c.isNull()) return null;
  const m = class_getInstanceMethod(classMethod ? object_getClass(c) : c, sel(selector));
  return m.isNull() ? null : method_getImplementation(m).strip();
}
function eventFields(e) {
  if (e.isNull()) return { type: null };
  const type = CGEventGetType(e);
  const out = { type, ts: CGEventGetTimestamp(e).toString(), flags: '0x' + CGEventGetFlags(e).toString(16) };
  if (type === 10 || type === 11) out.keyCode = CGEventGetIntegerValueField(e, 9).toNumber();
  return out;
}
function enterLeave(k, fn, address, args) {
  attach(fn, address, {
    onEnter(a) {
      const line = { k, fn, ph: 'enter', main: isMain() };
      if (args) Object.assign(line, args(a));
      write(line);
    },
    onLeave() {
      write({ k, fn, ph: 'leave', main: isMain() });
    },
  });
}
// CA calls on the main thread while armed.
function caHook(k, fn, address) {
  attach(fn, address, {
    onEnter() {
      const t = CACurrentMediaTime();
      this.on = armed(t) && isMain();
      if (this.on) write({ k, ph: 'enter' }, t);
    },
    onLeave() {
      if (this.on) write({ k, ph: 'leave' });
    },
  });
}

const dock = Process.mainModule.name === 'Dock';
const main = Process.mainModule;

// The controller's handleEvent: the event is the first argument after self and _cmd in Dock, the
// first argument of the Swift method in the agent (the method is called directly, not by message).
function handleEventHooks(address, eventArg) {
  attach('handleEvent', address, {
    onEnter(a) {
      const t = CACurrentMediaTime();
      const e = eventFields(a[eventArg]);
      if (e.type === 10 || e.type === 11) armedUntil = t + 0.5;
      write(Object.assign({ k: 'he', ph: 'enter', main: isMain() }, e), t);
    },
    onLeave(r) {
      write({ k: 'he', ph: 'leave', ret: r.toUInt32() & 1 });
    },
  });
}

function swift(name) {
  for (const n of [name, '_' + name]) {
    const s = main.findSymbolByName(n);
    if (s !== null && !s.isNull()) return s;
  }
  return null;
}

if (dock) {
  // Dock's event port callback (paper §4; Dock 15.6.1 (24G90) address), which drains the events.
  const slide = main.base.sub(ptr('0x100000000'));
  enterLeave('recv', 'DockEventPortCallback', ptr('0x1000ad1cc').add(slide));
  handleEventHooks(imp('Springboard', 'handleEvent:'), 2);
  enterLeave('kd', 'Springboard.keyDown:', imp('Springboard', 'keyDown:'));
  enterLeave('ku', 'Springboard.keyUp:', imp('Springboard', 'keyUp:'));
  enterLeave('sel', 'ECSBPager.setSelectedItem:', imp('ECSBPager', 'setSelectedItem:'));
  enterLeave('sel', 'ECSBItemLayer.setSelected:', imp('ECSBItemLayer', 'setSelected:'), a => ({ value: a[2].toUInt32() & 1 }));
  enterLeave('launch', 'LPSpringboard._launchRunnable', imp('LPSpringboard', '_launchRunnable:withImageRect:withEvent:'));
  enterLeave('launch', 'Springboard.performOpenAnimation',
    imp('Springboard', 'performOpenAnimationForRunnable:withImage:atFrame:toFrame:'));
  enterLeave('launch', 'LPSpringboard.setVisible', imp('LPSpringboard', 'setVisible:slow:forGaming:reason:'));
} else {
  const nextEvent = imp('NSApplication', 'nextEventMatchingMask:untilDate:inMode:dequeue:');
  attach('nextEvent', nextEvent, {
    onLeave(r) {
      if (r.isNull()) return;
      const t = CACurrentMediaTime();
      const cg = msgP(r, sel('CGEvent'));
      write(Object.assign({ k: 'recv', fn: 'nextEvent', ph: 'leave', main: isMain() }, eventFields(cg)), t);
    },
  });
  attach('sendEvent', imp('NSApplication', 'sendEvent:'), {
    onEnter(a) {
      write({ k: 'send', ph: 'enter', type: Number(msgU(a[2], sel('type'))), main: isMain() });
    },
    onLeave() {
      write({ k: 'send', ph: 'leave', main: isMain() });
    },
  });
  handleEventHooks(swift('$s9LaunchPad11SpringboardC11handleEventySbyXlF'), 0);
  enterLeave('kd', 'Springboard.keyDown:', imp('Springboard', 'keyDown:'));
  enterLeave('ku', 'Springboard.keyUp:', imp('Springboard', 'keyUp:'));
  enterLeave('sel', 'ECSBPager.selectedItem.setter', swift('$s9LaunchPad9ECSBPagerC12selectedItemAA8ECSBItemCSgvs'));
  enterLeave('sel', 'ECSBItemLayer.selected.setter', swift('$s9LaunchPad13ECSBItemLayerC8selectedSbvs'),
    a => ({ value: a[0].toUInt32() & 1 }));
  for (const [fn, name] of [
    ['LPSpringboard._launchRunnable', '$s9LaunchPad13LPSpringboardC15_launchRunnable_13withImageRect0F5EventyAA10LPRunnableCSg_So6CGRectVAA7ECEventCSgtF'],
    ['LPSpringboard._launchRunnable (specialized)', '$s9LaunchPad13LPSpringboardC15_launchRunnable_13withImageRect0F5EventyAA10LPRunnableCSg_So6CGRectVAA7ECEventCSgtFTf4nndn_n'],
    ['Springboard.performOpenAnimation (specialized)', '$s9LaunchPad11SpringboardC20performOpenAnimation11forRunnable9withImage7atFrame02toL0yAA10LPRunnableCSg_yXlSgSo6CGRectVANtFTf4dnnnn_n'],
    ['LPSpringboard.setVisible', '$s9LaunchPad13LPSpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtF'],
    ['LPSpringboard.setVisible (specialized)', '$s9LaunchPad13LPSpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtFTf4nndnn_n'],
    ['WALayerKitWindow.syncCopy', '$s9LaunchPad16WALayerKitWindowC8syncCopyyyF'],
  ]) {
    enterLeave('launch', fn, swift(name));
  }
}

caHook('flush', '+[CATransaction flush]', imp('CATransaction', 'flush', true));
caHook('commit', '+[CATransaction commit]', imp('CATransaction', 'commit', true));
let caCommit = null;
try {
  caCommit = DebugSymbol.fromName('_ZN2CA11Transaction6commitEv').address;
} catch (e) {
  write({ k: 'note', text: 'DebugSymbol CA::Transaction::commit: ' + e });
}
caHook('cacommit', 'CA::Transaction::commit()', caCommit);

const timebase = Memory.alloc(8);
mach_timebase_info(timebase);
write({
  k: 'header', frida: Frida.version, pid: Process.id, process: main.name, utc, path,
  timebase: [timebase.readU32(), timebase.add(4).readU32()], mach: mach_absolute_time().toString(),
  caCommit: caCommit === null ? null : caCommit.toString(), installed,
});
