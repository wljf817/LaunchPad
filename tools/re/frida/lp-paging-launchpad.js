// Record the page indicator of this project's background process (LaunchPadAgent, macOS 26
// comparison VM) in the same shape as the "snapshot" lines of lp-paging.js, so the two can be
// compared. Frida 17 core API only (no Objective-C bridge), as lp-paging.js.
//
// Load it through REA into the agent started with frida-gadget listening (as for lp-graph.js). On
// load, and again every time "snap" is written to $HOME/frida-gadget/lp-paging-launchpad-cmd.txt
// (read every 200 ms, then emptied), it reads the state on the main queue: the controller is the
// Swift global launchpadSpringboard; the rest goes through the same Objective-C names as in Dock.
//
// File: $HOME/frida-gadget/lp-paging-launchpad-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header    frida, pid, utc
//   snapshot  why, state (the fields of lp-paging.js's snapshot)
//   call      ECSBLayer's mouse methods, in the shape of lp-paging.js's call lines: the event's
//             location and timestamp, and after the call the return value and the drag state
//             (isDragScrolling, startScrollValue, startLocation, lastLocation, lastTime,
//             scrollValue, currentPageIndex). ECPagerLayer's own methods are reached from Swift
//             directly (super calls, property setters), not through their Objective-C entry points,
//             so only the entry points the dispatcher calls are traced. ECSBLayer's -scrollWheel: and
//             -gesture: in the shape of lp-paging.js's: the event's fields, and after the call the
//             return value and the scroll state (isGestureScrolling, cummulativeDelta,
//             startScrollValue, lastTime, timer, scrollValue, currentPageIndex)
//   timer     during -[ECSBLayer scrollWheel:], dispatch_source_set_timer's start, interval and leeway
//             and the start's delay after mach_absolute_time on entry, in nanoseconds
//   note      failures, and methods not traced
//
// Nothing is written to the process's objects.

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
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgL = new NativeFunction(msgSendPtr, 'long', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);
const msgPoint = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);
const msgU64 = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const CGColorGetNumberOfComponents = gf('CGColorGetNumberOfComponents', 'ulong', ['pointer']);
const CGColorGetComponents = gf('CGColorGetComponents', 'pointer', ['pointer']);
const getenv = gf('getenv', 'pointer', ['pointer']);
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
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}
// An ivar looked up on the object's own class (Swift stored properties are ivars by their names).
function ivar(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className(obj) + '.' + name);
  return obj.add(ivar_getOffset(iv).toNumber()).readPointer();
}
function ivarAddress(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className(obj) + '.' + name);
  return obj.add(ivar_getOffset(iv).toNumber());
}
function frame(layer) {
  return msgRect(layer, sel('frame'));
}
function bounds(layer) {
  return msgRect(layer, sel('bounds'));
}
function color(c) {
  if (c.isNull()) return null;
  const n = Number(CGColorGetNumberOfComponents(c));
  const p = CGColorGetComponents(c);
  const out = [];
  for (let k = 0; k < n; k++) out.push(p.add(8 * k).readDouble());
  return out;
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-paging-launchpad-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

// --- state ----------------------------------------------------------------

const globalName = '$s9LaunchPad20launchpadSpringboardAA0D0CSgvp';
// A local symbol: not an export, and findSymbolByName does not see it, so the symbol table is searched.
const springboardGlobal = (() => {
  const found = Process.mainModule.enumerateSymbols().find(s => s.name === globalName);
  return found === undefined ? null : found.address;
})();

function state() {
  if (springboardGlobal === null) throw new Error('not found: ' + globalName);
  const sb = springboardGlobal.readPointer();
  if (sb.isNull()) throw new Error('no controller yet');
  const ecsb = ivar(sb, 'springboard');
  const pager = msgP(ecsb, sel('pager'));
  const grid = msgP(pager, sel('layer'));
  const control = msgP(grid, sel('controlLayer'));
  const scroll = msgP(grid, sel('scrollLayer'));
  const pages = msgP(pager, sel('pages'));
  const pageCount = Number(msgU(pages, sel('count')));
  const dots = [];
  const indicators = msgP(control, sel('indicatorLayers'));
  const n = Number(msgU(indicators, sel('count')));
  for (let i = 0; i < n; i++) {
    const dot = msgPU(indicators, sel('objectAtIndex:'), i);
    const inner = ivar(dot, '_layer');
    const contents = msgP(inner, sel('contents'));
    dots.push({
      class: className(dot),
      frame: frame(dot),
      index: Number(msgU(dot, sel('index'))),
      state: Number(msgL(dot, sel('state'))),
      hidden: !!msgB(dot, sel('isHidden')),
      layer: {
        frame: frame(inner),
        cornerRadius: msgD(inner, sel('cornerRadius')),
        backgroundColor: color(msgP(inner, sel('backgroundColor'))),
        contents: contents.isNull() ? null : className(contents),
        allowsHitTesting: !!msgB(inner, sel('allowsHitTesting')),
        minificationFilter: str(msgP(inner, sel('minificationFilter'))),
      },
    });
  }
  return {
    visible: !!msgB(sb, sel('visible')),
    currentPageIndex: Number(msgU(pager, sel('currentPageIndex'))),
    pages: { count: pageCount },
    gridFrame: frame(grid),
    bottomMargin: msgD(grid, sel('bottomMargin')),
    pagerControlVisibility: Number(msgL(grid, sel('pagerControlVisibility'))),
    scrollBounds: bounds(scroll),
    control: { class: className(control), hidden: !!msgB(control, sel('isHidden')), frame: frame(control), sublayers: n },
    dots,
  };
}

let why = 'load';
const take = new NativeCallback(() => {
  try {
    write({ type: 'snapshot', why, state: state() });
  } catch (e) {
    write({ type: 'note', text: 'snapshot failed: ' + e });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, take);

const cmdPath = home + '/frida-gadget/lp-paging-launchpad-cmd.txt';
setInterval(() => {
  let text = '';
  try {
    text = File.readAllText(cmdPath);
  } catch (e) {
    return;
  }
  if (text.trim() === '') return;
  new File(cmdPath, 'w').close();
  why = text.trim();
  dispatch_async_f(mainQueue, NULL, take);
}, 200);

// --- drag scrolling --------------------------------------------------------

const event = e => ({ loc: msgPoint(e, sel('location')), time: msgU64(e, sel('time')).toString() });
const mouse = a => [event(a[2])];
function dragState(layer) {
  const point = name => [ivarAddress(layer, name).readDouble(), ivarAddress(layer, name).add(8).readDouble()];
  return {
    isDragScrolling: ivarAddress(layer, 'isDragScrolling').readU8() & 1,
    startScrollValue: ivarAddress(layer, 'startScrollValue').readDouble(),
    startLocation: point('startLocation'),
    lastLocation: point('lastLocation'),
    lastTime: ivarAddress(layer, 'lastTime').readU64().toString(),
    scrollValue: msgD(layer, sel('scrollValue')),
    currentPageIndex: Number(msgU(layer, sel('currentPageIndex'))),
  };
}
const mouseRet = (r, self) => [r.toUInt32() & 1, dragState(self)];

// --- scroll wheel and gestures ----------------------------------------------

const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
const mach_absolute_time = gf('mach_absolute_time', 'uint64', []);
const mach_timebase_info = gf('mach_timebase_info', 'int', ['pointer']);
const timebase = Memory.alloc(8);
mach_timebase_info(timebase);
let inScrollWheel = false;
function scrollEvent(e) {
  const cg = msgP(e, sel('event'));
  const field = n => CGEventGetIntegerValueField(cg, n).toString();
  return {
    type: Number(msgL(e, sel('type'))),
    time: msgU64(e, sel('time')).toString(),
    loc: msgPoint(e, sel('location')),
    deltaX: msgD(e, sel('deltaX')),
    deltaY: msgD(e, sel('deltaY')),
    isMomentum: !!msgB(e, sel('isMomentum')),
    gestureType: Number(msgL(e, sel('gestureType'))),
    gesturePhase: Number(msgU(e, sel('gesturePhase'))),
    navigationGestureType: msgL(e, sel('navigationGestureType')).toString(),
    fields: { 88: field(88), 96: field(96), 97: field(97), 99: field(99), 123: field(123) },
  };
}
function scrollState(layer) {
  return {
    isGestureScrolling: ivarAddress(layer, 'isGestureScrolling').readU8() & 1,
    cummulativeDelta: ivarAddress(layer, 'cummulativeDelta').readDouble(),
    startScrollValue: ivarAddress(layer, 'startScrollValue').readDouble(),
    lastTime: ivarAddress(layer, 'lastTime').readU64().toString(),
    timer: !ivarAddress(layer, 'scrollWheelTimer').readPointer().isNull(),
    scrollValue: msgD(layer, sel('scrollValue')),
    currentPageIndex: Number(msgU(layer, sel('currentPageIndex'))),
  };
}
const scrollRet = (r, self) => [r.toUInt32() & 1, scrollState(self)];

Interceptor.attach(libdispatch.getExportByName('dispatch_source_set_timer'), {
  onEnter(a) {
    if (!inScrollWheel) return;
    const start = uint64(a[1].toString(10));
    const delay = start.sub(mach_absolute_time()).toNumber() * timebase.readU32() / timebase.add(4).readU32();
    write({ type: 'timer', start: start.toString(), interval: uint64(a[2].toString(10)).toString(),
      leeway: uint64(a[3].toString(10)).toString(), delayNs: Math.round(delay) });
  },
});

// [class, selector, args on enter, ret on leave (retval, self)]
const HOOKS = [
  ['ECSBLayer', 'leftMouseDown:', mouse, mouseRet],
  ['ECSBLayer', 'leftMouseDragged:', mouse, mouseRet],
  ['ECSBLayer', 'leftMouseUp:', mouse, mouseRet],
  ['ECSBLayer', 'scrollWheel:', a => { inScrollWheel = true; return [scrollEvent(a[2])]; },
    (r, self) => { inScrollWheel = false; return scrollRet(r, self); }],
  ['ECSBLayer', 'gesture:', a => [scrollEvent(a[2])], scrollRet],
];

for (const [c, s_, args, ret] of HOOKS) {
  const k = objc_getClass(Memory.allocUtf8String(c));
  const m = k.isNull() ? ptr(0) : class_getInstanceMethod(k, sel(s_));
  if (m.isNull()) {
    write({ type: 'note', text: 'not found: ' + c + ' ' + s_ });
    continue;
  }
  const impl = method_getImplementation(m);
  if (Instruction.parse(impl).mnemonic === 'b') {
    write({ type: 'note', text: 'thunk, not traced: ' + c + ' ' + s_ });
    continue;
  }
  const fn = c + '.' + s_;
  Interceptor.attach(impl, {
    onEnter(a) {
      this.self = a[0];
      write({ type: 'call', ph: 'enter', fn, self: className(a[0]), args: args(a, this.context) });
    },
    onLeave(r) {
      if (ret !== null) write({ type: 'call', ph: 'leave', fn, ret: ret(r, this.self) });
    },
  });
}
