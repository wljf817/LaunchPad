// The version of lp-text-input.js for this project's background process (LaunchPadAgent, macOS 26
// comparison VM), with the same lines, so that the two can be compared (text-input task 6.1): the
// search field's connection steps, every XPC message to and from the text input service
// io.github.wljf817.LaunchPad.ecti with its replies, the mini view hand-over (setMiniView and
// miniViewShown, REF-DEV-034), the events forwarded to the service and when queued events go out,
// and the keys and clicks that reach the search field. Frida 17 core API only (REF-ENV-003).
//
// Methods called from Swift directly (not through objc_msgSend) cannot be traced at their
// Objective-C entry points, so the call, key and mouse lines hook the Swift bodies, found by their
// symbols in the main module: self is in x20, the first arguments in x0 and x1. Bodies the compiler
// inlined have no symbol (-_ensureConnection, -registerContext:window:, -handleKeyEvent:,
// -_updateStringValue:width:complete:, -invalidate); their effects show in the lines around them
// and in the state. DSXSetMiniView (Dock's _DSXSetMiniView handler, REF-DEV-034) is a dsx line.
// Swift stored properties appear as ivars named like the property, so the state is read the same
// way as in Dock; the Bool properties are bytes of their own instead of Dock's bit field. Swift
// closures passed as blocks share one invoke function, so reply and event lines are told apart by
// the block passed to libxpc.
//
// Load it through REA into the agent started with frida-gadget listening (as
// lp-keyboard-launchpad.js). Sample the service process and its windows at the same time with
// `window-list processes <seconds> 20 io.github.wljf817.LaunchPad.ecti`. Fetch the file with
// tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-text-input-launchpad-<UTC load time>.jsonl in the target process,
// created exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread): header, call, key, mouse, xpc, reply, event, post, move, dsx, visible,
// note, as in lp-text-input.js. call lines carry the state on enter and leave (state: _pid, _psn,
// _windowID, the Bool properties, _queuedEvents count, _globalHostFrame, _actualWidth, _connection,
// _stringValue, _hostLayer's contextId and frame).
//
// Nothing is written to the process's objects.

'use strict';

const serviceName = 'io.github.wljf817.LaunchPad.ecti';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  return new NativeFunction(Module.getGlobalExportByName(name), ret, args);
}
function gfMaybe(name, ret, args) {
  const p = Module.findGlobalExportByName(name);
  return p === null ? null : new NativeFunction(p, ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const pthread_main_np = gf('pthread_main_np', 'int', []);
const getenv = gf('getenv', 'pointer', ['pointer']);
const free = gf('free', 'void', ['pointer']);
const xpc_copy_description = gf('xpc_copy_description', 'pointer', ['pointer']);
const CGEventGetType = gf('CGEventGetType', 'uint32', ['pointer']);
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
const CGEventGetLocation = gf('CGEventGetLocation', ['double', 'double'], ['pointer']);
const CGEventGetTimestamp = gf('CGEventGetTimestamp', 'uint64', ['pointer']);
const CGEventGetFlags = gf('CGEventGetFlags', 'uint64', ['pointer']);
const CGEventGetWindowLocation = gfMaybe('CGEventGetWindowLocation', ['double', 'double'], ['pointer']);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_async_f = nf(libdispatch, 'dispatch_async_f', 'void', ['pointer', 'pointer', 'pointer']);
const mainQueue = libdispatch.getExportByName('_dispatch_main_q');

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
const offsets = new Map();
function ivarOffset(className_, name) {
  const key = className_ + '.' + name;
  let o = offsets.get(key);
  if (o === undefined) {
    const ivar = class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name));
    if (ivar.isNull()) throw new Error('no ivar ' + key);
    o = ivar_getOffset(ivar).toNumber();
    offsets.set(key, o);
  }
  return o;
}
function at(obj, name) {
  return obj.add(ivarOffset('ECTextInputLayer', name));
}
function rect(r) {
  return { x: r[0], y: r[1], w: r[2], h: r[3] };
}
function xdesc(obj) {
  if (obj.isNull()) return null;
  const p = xpc_copy_description(obj);
  const s = p.readUtf8String();
  free(p);
  return s;
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-text-input-launchpad-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

write({ type: 'header', frida: Frida.version, pid: Process.id, utc,
  hasGetWindowLocation: CGEventGetWindowLocation !== null });

// --- the field's state ----------------------------------------------------

const bools = ['_mouseDownInHost', '_mouseDownInClear', '_hasConnection', '_connectionInvalid',
  '_textFieldActive', '_queueEvents', '_hasFocus', '_updatingValueFromServer'];

function state(f) {
  try {
    const queued = at(f, '_queuedEvents').readPointer();
    const host = at(f, '_hostLayer').readPointer();
    const conn = at(f, '_connection').readPointer();
    const flags = {};
    for (const b of bools) flags[b.slice(1)] = at(f, b).readU8() !== 0;
    return {
      field: f.toString(),
      pid: at(f, '_pid').readS32(),
      psn: [at(f, '_psn').readU32(), at(f, '_psn').add(4).readU32()],
      windowID: at(f, '_windowID').readU32(),
      flags,
      queued: queued.isNull() ? null : Number(msgU(queued, sel('count'))),
      globalHostFrame: rect([0, 8, 16, 24].map((k) => at(f, '_globalHostFrame').add(k).readDouble())),
      actualWidth: at(f, '_actualWidth').readDouble(),
      connection: conn.isNull() ? null : conn.toString(),
      stringValue: str(at(f, '_stringValue').readPointer()),
      hostContextId: host.isNull() ? null : msgU32(host, sel('contextId')),
      hostFrame: host.isNull() ? null : rect(msgRect(host, sel('frame'))),
      textFieldActive: flags.textFieldActive,
      hasFocus: flags.hasFocus,
    };
  } catch (e) {
    return { error: String(e) };
  }
}

function eventInfo(cgEvent) {
  if (cgEvent.isNull()) return null;
  const loc = CGEventGetLocation(cgEvent);
  const out = {
    type: CGEventGetType(cgEvent),
    keycode: Number(CGEventGetIntegerValueField(cgEvent, 9)),
    field51: Number(CGEventGetIntegerValueField(cgEvent, 51)),
    location: [loc[0], loc[1]],
    timestamp: CGEventGetTimestamp(cgEvent).toString(),
    flags: '0x' + CGEventGetFlags(cgEvent).toString(16),
  };
  if (CGEventGetWindowLocation !== null) {
    const w = CGEventGetWindowLocation(cgEvent);
    out.windowLocation = [w[0], w[1]];
  }
  return out;
}
function ecEvent(obj) {
  // ECEvent wraps a CGEvent (-event).
  if (obj.isNull()) return null;
  try {
    return eventInfo(msgP(obj, sel('event')));
  } catch (e) {
    return { class: className(obj), error: String(e) };
  }
}

// --- Swift bodies ---------------------------------------------------------

const symbols = new Map();
for (const s of Process.mainModule.enumerateSymbols()) {
  if (s.name.startsWith('$s9LaunchPad')) symbols.set(s.name, s.address);
}
function hookSwift(mangled, onEnter, onLeave) {
  const p = symbols.get(mangled);
  if (p === undefined) {
    write({ type: 'note', what: 'no symbol', fn: mangled });
    return;
  }
  Interceptor.attach(p, { onEnter, onLeave });
}

const T = '$s9LaunchPad16ECTextInputLayerC';
const bool0 = (c) => !!(c.x0.toInt32() & 1);
const methods = {
  '_setupConnection': [T + '16_setupConnectionyyF', null],
  '_doCommunicationSetup': [T + '21_doCommunicationSetupyyF', null],
  '_sendSetMiniViewMessage': [T + '23_sendSetMiniViewMessageyyF', null],
  '_getStringValueWithBlock:': [T + '15_getStringValue9withBlockyySo8NSStringCSg_12CoreGraphics7CGFloatVSbtc_tF', null],
  '_closeConnection': [T + '16_closeConnectionyyF', null],
  '_synchronizeWindowLocation': [T + '26_synchronizeWindowLocationyyF', null],
  '_forwardEvent:': [T + '13_forwardEventyyyXlSgF', (c) => eventInfo(c.x0)],  // the CGEvent itself
  '_processPendingEvents': [T + '21_processPendingEventsyyF', null],
  'setTextFieldActive:': [T + '15textFieldActiveSbvs', bool0],
  'setHasFocus:': [T + '8hasFocusSbvs', bool0],
  'setStringValue:': [T + '11stringValueSo8NSStringCSgvs', (c) => str(c.x0)],
  'leftMouseDown:': [T + '13leftMouseDownySbAA7ECEventCF', (c) => ecEvent(c.x0)],
};
for (const [selector, [mangled, arg]] of Object.entries(methods)) {
  hookSwift(mangled,
    function () {
      this.self = this.context.x20;
      const rec = { type: 'call', ph: 'enter', fn: selector, state: state(this.self) };
      if (arg !== null) rec.arg = arg(this.context);
      write(rec);
    },
    function (retval) {
      const rec = { type: 'call', ph: 'leave', fn: selector, state: state(this.self) };
      if (selector === 'leftMouseDown:') rec.ret = retval.toInt32() & 1;
      write(rec);
    });
}
// The Objective-C entry points of the same methods, for calls that come through objc_msgSend.
for (const selector of ['leftMouseUp:', 'leftMouseDragged:', 'mouseMoved:', '_darkenCancelLayer:', 'selectAllText']) {
  const m = class_getInstanceMethod(cls('ECTextInputLayer'), sel(selector));
  if (m.isNull()) {
    write({ type: 'note', what: 'no method', fn: 'ECTextInputLayer.' + selector });
    continue;
  }
  Interceptor.attach(method_getImplementation(m), {
    onEnter() {
      this.self = this.context.x0;
      const rec = { type: 'call', ph: 'enter', fn: selector, state: state(this.self) };
      if (selector.endsWith('Layer:')) rec.arg = !!(this.context.x2.toInt32() & 1);
      else if (selector !== 'selectAllText') rec.arg = ecEvent(this.context.x2);
      write(rec);
    },
    onLeave() {
      write({ type: 'call', ph: 'leave', fn: selector, state: state(this.self) });
    },
  });
}

const L = '$s9LaunchPad9ECSBLayerC';
for (const [selector, mangled] of [['keyDown:', L + '7keyDownySbAA7ECEventCF'], ['keyUp:', L + '5keyUpySbAA7ECEventCF']]) {
  hookSwift(mangled,
    function () {
      const ev = this.context.x0;
      write({ type: 'key', ph: 'enter', fn: selector, keyData: Number(msgU(ev, sel('keyData'))) & 0xffff,
        event: ecEvent(ev) });
    },
    function (retval) {
      write({ type: 'key', ph: 'leave', fn: selector, ret: retval.toInt32() & 1 });
    });
}
// A specialization whose arguments are not the method's; the line gives the time only.
hookSwift(L + '13leftMouseDown_2inSbAA7ECEventC_So7CALayerCSgtFTf4dnn_n',
  function () {
    write({ type: 'mouse', ph: 'enter', fn: 'leftMouseDown:in:' });
  },
  function (retval) {
    write({ type: 'mouse', ph: 'leave', fn: 'leftMouseDown:in:', ret: retval.toInt32() & 1 });
  });

const sb = class_getInstanceMethod(cls('Springboard'), sel('setVisible:reason:'));
if (!sb.isNull()) {
  Interceptor.attach(method_getImplementation(sb), {
    onEnter() {
      write({ type: 'visible', ph: 'enter', visible: !!(this.context.x2.toInt32() & 1) });
    },
    onLeave() {
      write({ type: 'visible', ph: 'leave' });
    },
  });
}

// DSXSetMiniView(window:contextID:minimizedWindow:pid:), REF-DEV-034.
hookSwift('$s9LaunchPad14DSXSetMiniView6window9contextID15minimizedWindow3pidys6UInt32V_A2Hs5Int32VtF',
  function () {
    const c = this.context;
    write({ type: 'dsx', ph: 'enter', fn: 'handler',
      args: { window: c.x0.toUInt32(), contextid: c.x1.toUInt32(), minimizedWindow: c.x2.toUInt32(), pid: c.x3.toInt32() } });
  },
  function () {
    write({ type: 'dsx', ph: 'leave', fn: 'handler' });
  });

// --- libxpc ---------------------------------------------------------------

const ecti = new Set();
const hookedInvokes = new Set();
// Swift closures passed as blocks share one invoke function in this process, whatever connection
// they belong to, so a run is written only for the blocks passed for the service's connections.
const blocks = new Map();

function attachBlock(block, kind) {
  // The block's invoke function runs with the block in x0 and the object in x1.
  blocks.set(block.toString(), kind);
  const invoke = block.add(16).readPointer().strip();
  const key = invoke.toString();
  if (hookedInvokes.has(key)) return;
  hookedInvokes.add(key);
  Interceptor.attach(invoke, {
    onEnter() {
      this.block = this.context.x0.toString();
      this.kind = blocks.get(this.block);
      if (this.kind === undefined) return;
      const object = xdesc(this.context.x1);
      this.last = this.kind === 'event' && object !== null && object.includes('Connection invalid');
      write({ type: this.kind, invoke: invoke.toString(), object });
    },
    onLeave() {
      if (this.kind === undefined) return;
      write({ type: this.kind, ph: 'leave', invoke: invoke.toString() });
      // A reply block runs once, an event handler last with "Connection invalid"; the freed block's
      // address can come back for another closure.
      if (this.kind === 'reply' || this.last) blocks.delete(this.block);
    },
  });
}

Interceptor.attach(Module.getGlobalExportByName('xpc_connection_create'), {
  onEnter() {
    this.name = this.context.x0.isNull() ? null : this.context.x0.readUtf8String();
  },
  onLeave(retval) {
    if (this.name === serviceName) {
      ecti.add(retval.toString());
      write({ type: 'xpc', fn: 'xpc_connection_create', name: this.name, connection: retval.toString() });
    }
  },
});
Interceptor.attach(Module.getGlobalExportByName('xpc_connection_set_instance'), {
  onEnter() {
    if (!ecti.has(this.context.x0.toString())) return;
    const bytes = new Uint8Array(this.context.x1.readByteArray(16));
    write({ type: 'xpc', fn: 'xpc_connection_set_instance', connection: this.context.x0.toString(),
      uuid: Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('') });
  },
});
Interceptor.attach(Module.getGlobalExportByName('xpc_connection_set_event_handler'), {
  onEnter() {
    if (!ecti.has(this.context.x0.toString())) return;
    write({ type: 'xpc', fn: 'xpc_connection_set_event_handler', connection: this.context.x0.toString() });
    attachBlock(this.context.x1, 'event');
  },
});
for (const name of ['xpc_connection_resume', 'xpc_connection_cancel']) {
  Interceptor.attach(Module.getGlobalExportByName(name), {
    onEnter() {
      if (!ecti.has(this.context.x0.toString())) return;
      write({ type: 'xpc', fn: name, connection: this.context.x0.toString() });
    },
  });
}
Interceptor.attach(Module.getGlobalExportByName('xpc_connection_send_message'), {
  onEnter() {
    if (!ecti.has(this.context.x0.toString())) return;
    write({ type: 'xpc', fn: 'xpc_connection_send_message', connection: this.context.x0.toString(),
      message: xdesc(this.context.x1) });
  },
});
Interceptor.attach(Module.getGlobalExportByName('xpc_connection_send_message_with_reply'), {
  onEnter() {
    if (!ecti.has(this.context.x0.toString())) return;
    write({ type: 'xpc', fn: 'xpc_connection_send_message_with_reply', connection: this.context.x0.toString(),
      message: xdesc(this.context.x1) });
    attachBlock(this.context.x3, 'reply');
  },
});

// --- events and windows ---------------------------------------------------

Interceptor.attach(Module.getGlobalExportByName('CGEventPostToPid'), {
  onEnter() {
    write({ type: 'post', pid: this.context.x0.toInt32(), event: eventInfo(this.context.x1) });
  },
});
for (const name of ['CGSMoveWindow', 'SLSMoveWindow']) {
  const p = Module.findGlobalExportByName(name);
  if (p === null) {
    write({ type: 'note', what: 'no export', fn: name });
    continue;
  }
  Interceptor.attach(p, {
    onEnter() {
      const pt = this.context.x2.isNull() ? null : [this.context.x2.readDouble(), this.context.x2.add(8).readDouble()];
      write({ type: 'move', fn: name, cid: this.context.x0.toInt32(), wid: this.context.x1.toUInt32(), point: pt });
    },
    onLeave(retval) {
      write({ type: 'move', ph: 'leave', fn: name, ret: retval.toInt32() });
    },
  });
}

const atLoad = new NativeCallback(function () {
  write({ type: 'note', what: 'loaded' });
}, 'void', ['pointer']);
dispatch_async_f(mainQueue, ptr(0), atLoad);
