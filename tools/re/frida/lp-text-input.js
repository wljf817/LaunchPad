// Record how the macOS 15 Launchpad in Dock (reference VM) talks to its text input service
// com.apple.dock.ecti: the search field's connection steps, every XPC message to and from the
// service with its replies, the mini view hand-over (_DSXSetMiniView), the events forwarded to the
// service and when queued events go out, and the keys and clicks that reach the search field.
// Frida 17 core API only (REF-ENV-003), helpers as lp-search-field.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-text-input.js" }.
// Post keys and clicks with vm-input over SSH. Sample the service process and its windows at the
// same time with `window-list processes <seconds> 20 com.apple.dock.ecti` (tools/re/window-list.swift),
// which stamps its lines with the same clock. Fetch the file with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-text-input-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread):
//   header    frida, pid, utc
//   call      enter and leave of the ECTextInputLayer methods below, with the arguments, the return
//             value and the field's state on leave (state: _pid, _psn, _windowID, the two bit-field
//             bytes from _mouseDownInHost on, _queuedEvents count, _globalHostFrame, _actualWidth,
//             _connection, _stringValue, _hostLayer's contextId and frame)
//   key       -[ECSBLayer keyDown:] / -keyUp: with keyData and flags, and the result
//   mouse     -[ECSBLayer leftMouseDown:in:] (when it exists) with the event's location and the result
//   xpc       xpc_connection_create / _set_instance / _set_event_handler / _resume / _cancel /
//             _send_message / _send_message_with_reply on a connection to com.apple.dock.ecti, with
//             the message's description
//   reply     a reply block for such a send runs: the reply's description
//   event     the connection's event handler runs: the event's description
//   post      CGEventPostToPid: pid, type, keycode, field 51, location, window location, timestamp
//             and flags of the event as posted
//   move      CGSMoveWindow / SLSMoveWindow from Dock: connection, window, point
//   dsx       Dock's _DSXSetMiniView handler, its "shown" step and the block that sends it: the
//             argument registers
//   visible   -[Springboard setVisible:reason:]
//   note      hooks not installed, failures
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
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);
const msgPoint = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);

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
    o = ivar_getOffset(class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name))).toNumber();
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
const path = home + '/frida-gadget/lp-text-input-' + utc + '.jsonl';
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

function state(f) {
  try {
    const queued = at(f, '_queuedEvents').readPointer();
    const host = at(f, '_hostLayer').readPointer();
    const conn = at(f, '_connection').readPointer();
    const bits = at(f, '_mouseDownInHost');
    return {
      field: f.toString(),
      pid: at(f, '_pid').readS32(),
      psn: [at(f, '_psn').readU32(), at(f, '_psn').add(4).readU32()],
      windowID: at(f, '_windowID').readU32(),
      bits: ['0x' + bits.readU8().toString(16), '0x' + bits.add(1).readU8().toString(16)],
      queued: queued.isNull() ? null : Number(msgU(queued, sel('count'))),
      globalHostFrame: rect([0, 8, 16, 24].map((k) => at(f, '_globalHostFrame').add(k).readDouble())),
      actualWidth: at(f, '_actualWidth').readDouble(),
      connection: conn.isNull() ? null : conn.toString(),
      stringValue: str(at(f, '_stringValue').readPointer()),
      hostContextId: host.isNull() ? null : msgU32(host, sel('contextId')),
      hostFrame: host.isNull() ? null : rect(msgRect(host, sel('frame'))),
      textFieldActive: !!msgB(f, sel('textFieldActive')),
      hasFocus: !!msgB(f, sel('hasFocus')),
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
  // ECEvent wraps a CGEvent (_event).
  if (obj.isNull()) return null;
  try {
    return eventInfo(obj.add(ivarOffset('ECEvent', '_event')).readPointer());
  } catch (e) {
    return { class: className(obj), error: String(e) };
  }
}

// --- ECTextInputLayer -----------------------------------------------------

function hookInstance(className_, selector, onEnter, onLeave) {
  const m = class_getInstanceMethod(cls(className_), sel(selector));
  if (m.isNull()) {
    write({ type: 'note', what: 'no method', fn: className_ + '.' + selector });
    return;
  }
  Interceptor.attach(method_getImplementation(m), { onEnter, onLeave });
}

const bool2 = (c) => !!(c.x2.toInt32() & 1);
const methods = {
  '_setupConnection': null,
  '_ensureConnection': null,
  '_doCommunicationSetup': null,
  '_sendSetMiniViewMessage': null,
  '_getStringValueWithBlock:': null,
  '_updateStringValue:width:complete:': (c) => ({ string: str(c.x2), width: c.d0, complete: !!(c.x3.toInt32() & 1) }),
  '_updateStringValue': null,
  '_closeConnection': null,
  'invalidate': null,
  '_fetchPSN': null,
  'registerContext:window:': (c) => ({ context: c.x2.toUInt32(), window: c.x3.toUInt32() }),
  '_getHostFrame': null,
  '_synchronizeWindowLocation': null,
  '_forwardEvent:': (c) => eventInfo(c.x2),  // the CGEvent itself
  '_processPendingEvents': null,
  'handleKeyEvent:': (c) => ecEvent(c.x2),
  '_sendStringValueMessage': null,
  'setTextFieldActive:': bool2,
  'setHasFocus:': bool2,
  'setStringValue:': (c) => str(c.x2),
  'setFont:': (c) => c.x2.toString(),
  'setForegroundColor:': (c) => c.x2.toString(),
  'selectAllText': null,
  'setFrame:': (c) => ({ x: c.d0, y: c.d1, w: c.d2, h: c.d3 }),
  'leftMouseDown:': (c) => ecEvent(c.x2),
  'leftMouseUp:': (c) => ecEvent(c.x2),
  'leftMouseDragged:': (c) => ecEvent(c.x2),
  'mouseMoved:': (c) => ecEvent(c.x2),
  '_darkenCancelLayer:': bool2,
};
for (const [selector, arg] of Object.entries(methods)) {
  hookInstance('ECTextInputLayer', selector,
    function () {
      this.self = this.context.x0;
      const rec = { type: 'call', ph: 'enter', fn: selector, state: state(this.self) };
      if (arg !== null) rec.arg = arg(this.context);
      write(rec);
    },
    function (retval) {
      const rec = { type: 'call', ph: 'leave', fn: selector, state: state(this.self) };
      if (selector === '_getHostFrame') rec.ret = { x: this.context.d0, y: this.context.d1, w: this.context.d2, h: this.context.d3 };
      else if (selector === '_fetchPSN') rec.ret = retval.toString();
      else if (selector.startsWith('leftMouse') || selector === 'mouseMoved:' || selector === 'handleKeyEvent:') rec.ret = retval.toInt32() & 1;
      write(rec);
    });
}

for (const selector of ['keyDown:', 'keyUp:']) {
  hookInstance('ECSBLayer', selector,
    function () {
      this.ev = this.context.x2;
      write({ type: 'key', ph: 'enter', fn: selector, keyData: Number(msgU(this.ev, sel('keyData'))) & 0xffff,
        event: ecEvent(this.ev) });
    },
    function (retval) {
      write({ type: 'key', ph: 'leave', fn: selector, ret: retval.toInt32() & 1 });
    });
}
hookInstance('ECSBLayer', 'leftMouseDown:in:',
  function () {
    write({ type: 'mouse', ph: 'enter', fn: 'leftMouseDown:in:', event: ecEvent(this.context.x2),
      inClass: className(this.context.x3) });
  },
  function (retval) {
    write({ type: 'mouse', ph: 'leave', fn: 'leftMouseDown:in:', ret: retval.toInt32() & 1 });
  });

hookInstance('Springboard', 'setVisible:reason:',
  function () {
    write({ type: 'visible', ph: 'enter', visible: bool2(this.context) });
  },
  function () {
    write({ type: 'visible', ph: 'leave' });
  });

// --- libxpc ---------------------------------------------------------------

const ecti = new Set();
const hookedInvokes = new Set();

function attachBlock(block, kind, conn) {
  // The block's invoke function runs with the block in x0 and the object in x1.
  const invoke = block.add(16).readPointer().strip();
  const key = kind + invoke.toString();
  if (hookedInvokes.has(key)) return;
  hookedInvokes.add(key);
  Interceptor.attach(invoke, {
    onEnter() {
      write({ type: kind, invoke: invoke.toString(), object: xdesc(this.context.x1) });
    },
    onLeave() {
      write({ type: kind, ph: 'leave', invoke: invoke.toString() });
    },
  });
}

Interceptor.attach(Module.getGlobalExportByName('xpc_connection_create'), {
  onEnter() {
    this.name = this.context.x0.isNull() ? null : this.context.x0.readUtf8String();
  },
  onLeave(retval) {
    if (this.name === 'com.apple.dock.ecti') {
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
    attachBlock(this.context.x1, 'event', this.context.x0);
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
    attachBlock(this.context.x3, 'reply', this.context.x0);
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
  });
}

// --- Dock's _DSXSetMiniView handler ---------------------------------------

const dock = Process.mainModule;
const slide = dock.base.sub(ptr('0x100000000'));
// Dock 15.6.1 (24G90) addresses, research/macos-15.6.1-24G90/notes/text-input/decompile-list-2..4.txt.
const dsx = {
  handler: '0x10008D270',
  handlerNotifyShown: '0x10008D480',
  notifyShownBlock: '0x10008E520',
};
for (const [name, address] of Object.entries(dsx)) {
  Interceptor.attach(ptr(address).add(slide), {
    onEnter() {
      const c = this.context;
      write({ type: 'dsx', ph: 'enter', fn: name,
        regs: [c.x0, c.x1, c.x2, c.x3, c.x4, c.x5].map((r) => r.toString()) });
    },
    onLeave(retval) {
      write({ type: 'dsx', ph: 'leave', fn: name, ret: retval.toString() });
    },
  });
}

const atLoad = new NativeCallback(function () {
  write({ type: 'note', what: 'loaded' });
}, 'void', ['pointer']);
dispatch_async_f(mainQueue, ptr(0), atLoad);
