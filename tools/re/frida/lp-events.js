// Trace how the macOS 15 Launchpad in Dock (reference VM) receives events and
// which path closes it: the window-server notification events Dock reads, the
// events handed to Launchpad, and Launchpad's event and cancel methods.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge
// (REF-ENV-003), so Objective-C is driven through the runtime's C functions and
// objc_msgSend, as in lp-trace.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-events.js" }.
// Read the lines with frida_session_status, or fetch the file with
// tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-events-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written. Every line is
// also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header  frida, pid, utc
//   ev      an event Dock took from its connection (CGEventCreateNextEvent):
//           et (CGEvent type), loc (for mouse events), key (keycode, for key
//           events), flags (CGEventFlags, for key events) and f (integer fields 64..72, for notification events,
//           type 21). Whether Launchpad got the event shows in the
//           handleSpringboardEvent:type: calls that follow it.
//   call    ph "enter" | "leave", fn (Class.selector), args, ret; for
//           -lostKeyFocus: the args also hold the state it checks (alert panel,
//           search field focus)
//   note    hooks not installed
//
// Events of type 5, 6, 7, 22, 27 and 29 (moves, drags, scrolls, gestures) are
// not written.
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
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);

const CGEventGetType = gf('CGEventGetType', 'uint32', ['pointer']);
const CGEventGetLocation = gf('CGEventGetLocation', ['double', 'double'], ['pointer']);
const CGEventGetFlags = gf('CGEventGetFlags', 'uint64', ['pointer']);
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
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
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-events-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

// --- events Dock takes from its connection --------------------------------

const SKIPPED = new Set([5, 6, 7, 22, 27, 29]);
const MOUSE = new Set([1, 2, 3, 4, 25, 26]);
const KEY = new Set([10, 11, 12]);

Interceptor.attach(Module.getGlobalExportByName('CGEventCreateNextEvent'), {
  onLeave(ret) {
    if (ret.isNull()) return;
    const et = CGEventGetType(ret);
    if (SKIPPED.has(et)) return;
    const line = { type: 'ev', et };
    if (MOUSE.has(et)) line.loc = CGEventGetLocation(ret);
    if (KEY.has(et)) {
      line.key = Number(CGEventGetIntegerValueField(ret, 9));
      line.flags = '0x' + CGEventGetFlags(ret).toString(16);
    }
    if (et === 21) {
      line.f = [];
      for (let i = 64; i <= 72; i++) line.f.push(Number(CGEventGetIntegerValueField(ret, i)));
    }
    write(line);
  },
});

// --- methods --------------------------------------------------------------

function ecEvent(e) {
  if (e.isNull()) return null;
  return { type: msgU32(e, sel('type')) };
}

// The state -lostKeyFocus: checks before closing: the active alert panel and
// the search field's text input layer.
const springboardIvar = ivar_getOffset(class_getInstanceVariable(cls('Springboard'),
  Memory.allocUtf8String('_springboard'))).toNumber();

function focusState(self) {
  const panel = msgP(cls('ECAlertPanel'), sel('activeAlertPanel'));
  const input = msgP(self.add(springboardIvar).readPointer(), sel('activeTextInputLayer'));
  return {
    panel: className(panel),
    input: className(input),
    hasFocus: input.isNull() ? null : !!msgB(input, sel('hasFocus')),
    textFieldActive: input.isNull() ? null : !!msgB(input, sel('textFieldActive')),
  };
}

const HOOKS = [
  ['DockAppEventHandler', 'handleSpringboardEvent:type:', a => [a[3].toUInt32()], r => r.toUInt32() & 1],
  ['Springboard', 'handleEvent:', null, r => r.toUInt32() & 1],
  ['Springboard', 'setVisible:reason:', a => [a[2].toUInt32() & 1, str(a[3])], null],
  ['Springboard', 'lostKeyFocus:', a => [a[2].isNull() ? null : msgU32(a[2], sel('notifyCode')), focusState(a[0])], null],
  ['Springboard', 'leftMouseDown:', a => [ecEvent(a[2])], r => r.toUInt32() & 1],
  ['Springboard', 'keyDown:', a => [msgU32(a[2], sel('keyData'))], r => r.toUInt32() & 1],
  ['Springboard', 'cancelActionWithEvent:sender:', a => [className(a[3])], null],
  ['Springboard', 'performCancel', null, null],
  ['ECSBSpringboard', 'cancelGridActionWithEvent:sender:', a => [className(a[3])], null],
  ['ECSBLayer', 'leftMouseDown:', null, r => r.toUInt32() & 1],
  ['ECSBLayer', 'leftMouseUp:', null, r => r.toUInt32() & 1],
  ['ECModalEventController', 'addHandler:externalEventSource:usingMouseHysteresis:',
    a => [className(a[2]), a[3].toUInt32() & 1, a[4].toUInt32() & 1], null],
  ['ECModalEventController', 'removeHandler:', a => [className(a[2])], null],
];

for (const [c, s, args, ret] of HOOKS) {
  const k = cls(c);
  const m = k.isNull() ? ptr(0) : class_getInstanceMethod(k, sel(s));
  if (m.isNull()) {
    write({ type: 'note', text: 'not found: ' + c + ' ' + s });
    continue;
  }
  const impl = method_getImplementation(m);
  if (Instruction.parse(impl).mnemonic === 'b') {
    write({ type: 'note', text: 'thunk, not traced: ' + c + ' ' + s });
    continue;
  }
  const fn = c + '.' + s;
  Interceptor.attach(impl, {
    onEnter(a) {
      write({ type: 'call', ph: 'enter', fn, args: args === null ? [] : args(a) });
    },
    onLeave(r) {
      if (ret !== null) write({ type: 'call', ph: 'leave', fn, ret: ret(r) });
    },
  });
}
