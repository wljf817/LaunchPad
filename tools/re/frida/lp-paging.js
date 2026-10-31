// Trace paging in the macOS 15 Launchpad in Dock (reference VM): setting the current page, the
// scroll to a page, the page change callbacks, the page indicator's layout and its dots' states,
// clicks on the page indicator, drag scrolling, scroll wheel and gesture scrolling with the scroll
// wheel's timer, and the page indicator's layer subtree after each change.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge (REF-ENV-003), so
// Objective-C is driven through the runtime's C functions and objc_msgSend, as in lp-launch.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-paging.js" }. Load
// ca-anim.js too for the animation objects, and post the input with lp-input.js in the same
// session. Fetch the file with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-paging-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread):
//   header    frida, pid, utc, timebase (mach_timebase_info numer and denom)
//   call      ph "enter" | "leave", fn (Class.selector or function), self (class), args, ret.
//             The mouse methods of ECPagerLayer and ECSBLayer give as args the event ({loc, time},
//             time the CGEvent timestamp as a decimal string) and the clocks read on entry ({mach,
//             uptimeNs}: mach_absolute_time and clock_gettime_nsec_np(CLOCK_UPTIME_RAW), decimal
//             strings); ECPagerLayer's give as ret the return value and the drag state after the
//             call (isDragScrolling, startScrollValue, startLocation, lastLocation, lastTime,
//             scrollValue). -setScrollValue: gives the value and whether implicit actions are
//             disabled, and returns the scroll layer's bounds. The scroll wheel and gesture
//             methods of ECPagerLayer and ECSBLayer give the event (type, time, deltaX, deltaY,
//             isMomentum, gestureType, gesturePhase, navigationGestureType, and the CGEvent's
//             integer fields 88 continuous, 96 and 97 point deltas, 99 scroll phase, 123
//             momentum phase) and the clocks, and as ret the return value and the scroll state
//             after the call (isGestureScrolling, cummulativeDelta, startScrollValue, lastTime,
//             timer: whether _scrollWheelTimer is set, scrollValue). ECSBPager.canScroll
//             returns its value
//   timer     during -[ECSBLayer scrollWheel:], dispatch_source_set_timer's start, interval and
//             leeway (decimal strings) and the delay of the start after mach_absolute_time on
//             entry, in nanoseconds (mach units times the timebase)
//   block     ph "enter" | "leave": the scroll wheel timer's block, with the scroll state and
//             currentPageIndex
//   snapshot  why, and the state: visible, currentPageIndex, pages (count and each page's
//             recentlyViewed), scroll layer bounds, the page indicator's hidden, frame and
//             sublayer count, and per dot its class, frame, index, state, and its sublayer's
//             frame, cornerRadius, backgroundColor (components), contents (null or class),
//             allowsHitTesting; the main grid layer's bottomMargin and
//             pagerControlVisibility. Taken when the script loads, when
//             -[Springboard setVisible:reason:] returns, 0.1 s after that and when
//             -scrollToPageIndex: returns, and again 1 s after that (on the main queue)
//   note      hooks not installed
//
// The empty methods -[ECSBSpringboard willChangeToPageIndex:], -didChangeToPageIndex: and
// -[Springboard willChangeToPage:] are a single return instruction, too short to hook; their
// calls show as the ECSBPager callbacks around them. Nothing is written to Dock's objects.

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
const CFStringGetCStringPtr = gf('CFStringGetCStringPtr', 'pointer', ['pointer', 'uint32']);
const pthread_main_np = gf('pthread_main_np', 'int', []);
const getenv = gf('getenv', 'pointer', ['pointer']);
const mach_absolute_time = gf('mach_absolute_time', 'uint64', []);
const clock_gettime_nsec_np = gf('clock_gettime_nsec_np', 'uint64', ['uint32']);
const mach_timebase_info = gf('mach_timebase_info', 'int', ['pointer']);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_after_f = nf(libdispatch, 'dispatch_after_f', 'void', ['uint64', 'pointer', 'pointer', 'pointer']);
const dispatch_async_f = nf(libdispatch, 'dispatch_async_f', 'void', ['pointer', 'pointer', 'pointer']);
const dispatch_time = nf(libdispatch, 'dispatch_time', 'uint64', ['uint64', 'int64']);
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
function ivarAddress(obj, className_, name) {
  const off = ivar_getOffset(class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name))).toNumber();
  return obj.add(off);
}
function ivar(obj, className_, name) {
  return ivarAddress(obj, className_, name).readPointer();
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
const path = home + '/frida-gadget/lp-paging-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

const timebase = Memory.alloc(8);
mach_timebase_info(timebase);
write({ type: 'header', frida: Frida.version, pid: Process.id, utc, timebase: [timebase.readU32(), timebase.add(4).readU32()] });

// --- state ----------------------------------------------------------------

const dock = Process.mainModule;
// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2 (as hide-grid.js).
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

function state() {
  const sb = springboardGlobal.readPointer();
  const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
  const pager = msgP(ecsb, sel('pager'));
  const grid = msgP(pager, sel('layer'));
  const control = ivar(grid, 'ECPagerLayer', '_controlLayer');
  const scroll = ivar(grid, 'ECPagerLayer', '_scrollLayer');
  const pages = msgP(pager, sel('pages'));
  const pageCount = Number(msgU(pages, sel('count')));
  const recentlyViewed = [];
  for (let i = 0; i < pageCount; i++) {
    recentlyViewed.push(!!msgB(msgPU(pages, sel('objectAtIndex:'), i), sel('recentlyViewed')));
  }
  const dots = [];
  const indicators = msgP(control, sel('indicatorLayers'));
  const n = Number(msgU(indicators, sel('count')));
  for (let i = 0; i < n; i++) {
    const dot = msgPU(indicators, sel('objectAtIndex:'), i);
    const inner = ivar(dot, 'ECPagerIndicatorLayer', '_layer');
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
    pages: { count: pageCount, recentlyViewed },
    gridFrame: frame(grid),
    bottomMargin: msgD(grid, sel('bottomMargin')),
    pagerControlVisibility: Number(msgL(grid, sel('pagerControlVisibility'))),
    scrollBounds: bounds(scroll),
    control: { class: className(control), hidden: !!msgB(control, sel('isHidden')), frame: frame(control), sublayers: n },
    dots,
  };
}

function snapshot(why) {
  try {
    write({ type: 'snapshot', why, state: state() });
  } catch (e) {
    write({ type: 'note', text: 'snapshot failed: ' + e });
  }
}

const pending = new Map();
let pendingId = 0;
const fire = new NativeCallback(ctx => {
  const why = pending.get(ctx.toInt32());
  pending.delete(ctx.toInt32());
  snapshot(why);
}, 'void', ['pointer']);

// Takes a snapshot on the main queue after `seconds`.
function snapshotLater(why, seconds) {
  const id = ++pendingId;
  pending.set(id, why);
  dispatch_after_f(dispatch_time(0, Math.round(seconds * 1e9)), mainQueue, ptr(id), fire);
}

// --- Objective-C methods ---------------------------------------------------

const disableActions = () => !!msgB(cls('CATransaction'), sel('disableActions'));
const index = a => a[2].toUInt32();
const layerClass = a => className(a[3]);
// CLOCK_UPTIME_RAW is 8 in <time.h>.
const clocks = () => ({ mach: mach_absolute_time().toString(), uptimeNs: clock_gettime_nsec_np(8).toString() });
const event = e => ({ loc: msgPoint(e, sel('location')), time: msgU64(e, sel('time')).toString() });
const mouse = a => [event(a[2]), clocks()];
function dragState(layer) {
  return {
    isDragScrolling: ivarAddress(layer, 'ECPagerLayer', '_isDragScrolling').readU8() & 1,
    startScrollValue: ivarAddress(layer, 'ECPagerLayer', '_startScrollValue').readDouble(),
    startLocation: [ivarAddress(layer, 'ECPagerLayer', '_startLocation').readDouble(),
      ivarAddress(layer, 'ECPagerLayer', '_startLocation').add(8).readDouble()],
    lastLocation: [ivarAddress(layer, 'ECPagerLayer', '_lastLocation').readDouble(),
      ivarAddress(layer, 'ECPagerLayer', '_lastLocation').add(8).readDouble()],
    lastTime: ivarAddress(layer, 'ECPagerLayer', '_lastTime').readU64().toString(),
    scrollValue: msgD(layer, sel('scrollValue')),
  };
}
const mouseRet = (r, self) => [r.toUInt32() & 1, dragState(self)];
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
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
    isGestureScrolling: (ivarAddress(layer, 'ECPagerLayer', '_isGestureScrolling').readU8() >> 1) & 1,
    cummulativeDelta: ivarAddress(layer, 'ECPagerLayer', '_cummulativeDelta').readDouble(),
    startScrollValue: ivarAddress(layer, 'ECPagerLayer', '_startScrollValue').readDouble(),
    lastTime: ivarAddress(layer, 'ECPagerLayer', '_lastTime').readU64().toString(),
    timer: !ivar(layer, 'ECPagerLayer', '_scrollWheelTimer').isNull(),
    scrollValue: msgD(layer, sel('scrollValue')),
  };
}
const scrollArgs = a => [scrollEvent(a[2]), clocks()];
const scrollRet = (r, self) => [r.toUInt32() & 1, scrollState(self)];
const scrollBounds = (r, self) => bounds(ivar(self, 'ECPagerLayer', '_scrollLayer'));

// [class, selector, args on enter (args), ret on leave (retval, self), after leave (self, args)]
const HOOKS = [
  ['ECPagerLayer', 'setCurrentPageIndex:', a => [index(a), Number(msgU(a[0], sel('currentPageIndex')))],
    (r, self) => Number(msgU(self, sel('currentPageIndex')))],
  ['ECSBLayer', 'setCurrentPageIndex:', a => [index(a)], null],
  ['ECPager', 'setCurrentPageIndex:', a => [index(a)], null],
  ['ECSBSpringboard', 'setCurrentPageIndex:', a => [index(a)], null],
  ['ECPagerLayer', 'scrollToPageIndex:', a => [index(a), bounds(ivar(a[0], 'ECPagerLayer', '_scrollLayer')),
    { disableActions: disableActions() }], (r, self) => bounds(ivar(self, 'ECPagerLayer', '_scrollLayer')),
    () => snapshotLater('scrolled + 1 s', 1)],
  ['ECPagerLayer', 'setScrollValue:', (a, c) => [c.d0, { disableActions: disableActions() }], scrollBounds],
  ['ECSBLayer', 'setScrollValue:', (a, c) => [c.d0, { disableActions: disableActions() }], scrollBounds],
  ['ECPagerLayer', 'leftMouseDown:', mouse, mouseRet],
  ['ECPagerLayer', 'leftMouseDragged:', mouse, mouseRet],
  ['ECPagerLayer', 'leftMouseUp:', mouse, mouseRet],
  ['ECSBLayer', 'leftMouseDragged:', mouse, r => r.toUInt32() & 1],
  ['ECSBLayer', 'scrollWheel:', a => { inScrollWheel = true; return scrollArgs(a); },
    (r, self) => { inScrollWheel = false; return scrollRet(r, self); }],
  ['ECSBLayer', 'gesture:', scrollArgs, scrollRet],
  ['ECPagerLayer', 'scrollWheel:', scrollArgs, scrollRet],
  ['ECPagerLayer', 'gesture:', scrollArgs, scrollRet],
  ['ECSBPager', 'canScroll', () => [], r => r.toUInt32() & 1],
  ['ECSBPager', 'willChangeToPageIndex:', a => [index(a)], null],
  ['ECSBPager', 'didChangeToPageIndex:', a => [index(a)], null],
  ['ECSBPager', 'setSelectedItem:', a => [className(a[2])], null],
  ['ECSBPager', 'setVisible:', a => [a[2].toUInt32() & 1], null],
  ['Springboard', 'didChangeToPage:', a => [className(a[2])], null],
  ['ECPagerControlLayer', 'layout', () => [{ disableActions: disableActions() }], null],
  ['ECPagerControlLayer', 'leftMouseDown:in:', a => [layerClass(a)], r => r.toUInt32() & 1],
  ['ECPagerControlLayer', 'leftMouseDragged:in:', a => [layerClass(a)], r => r.toUInt32() & 1],
  ['ECPagerControlLayer', 'leftMouseUp:in:', a => [layerClass(a), Number(msgU(a[3], sel('index')))], r => r.toUInt32() & 1],
  ['ECPagerIndicatorLayer', 'setState:', a => [a[2].toInt32(), Number(msgU(a[0], sel('index'))), Number(msgL(a[0], sel('state'))),
    { disableActions: disableActions() }], null],
  ['ECSBLayer', 'leftMouseDown:', mouse, r => r.toUInt32() & 1],
  ['ECSBLayer', 'leftMouseUp:', mouse, r => r.toUInt32() & 1],
  ['Springboard', 'cancelActionWithEvent:sender:', a => [className(a[3])], null],
  ['Springboard', 'setVisible:reason:', a => [a[2].toUInt32() & 1, str(a[3])], null,
    () => { snapshot('setVisible returned'); snapshotLater('setVisible + 0.1 s', 0.1); }],
];

for (const [c, s, args, ret, after] of HOOKS) {
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
      this.self = a[0];
      this.args = a;
      write({ type: 'call', ph: 'enter', fn, self: className(a[0]), args: args === null ? [] : args(a, this.context) });
    },
    onLeave(r) {
      if (ret !== null) write({ type: 'call', ph: 'leave', fn, ret: ret(r, this.self) });
      if (after !== undefined && after !== null) after(this.self);
    },
  });
}

// --- The scroll wheel's timer (REF-PAGING-006) ------------------------------

Interceptor.attach(libdispatch.getExportByName('dispatch_source_set_timer'), {
  onEnter(a) {
    if (!inScrollWheel) return;
    const now = mach_absolute_time();
    const start = uint64(a[1].toString(10));
    const delay = start.sub(now).toNumber() * timebase.readU32() / timebase.add(4).readU32();
    write({ type: 'timer', start: start.toString(), interval: uint64(a[2].toString(10)).toString(),
      leeway: uint64(a[3].toString(10)).toString(), delayNs: Math.round(delay) });
  },
});

// The block of -[ECSBLayer scrollWheel:]'s timer in Dock 15.6.1 (24G90).
const wheelBlock = ptr('0x10008222c').add(dock.base.sub(ptr('0x100000000')));
Interceptor.attach(wheelBlock, {
  onEnter(a) {
    this.layer = a[0].add(0x20).readPointer();
    write({ type: 'block', ph: 'enter', state: scrollState(this.layer),
      currentPageIndex: Number(msgU(this.layer, sel('currentPageIndex'))) });
  },
  onLeave() {
    write({ type: 'block', ph: 'leave', state: scrollState(this.layer),
      currentPageIndex: Number(msgU(this.layer, sel('currentPageIndex'))) });
  },
});

// --- Accessibility notification ---------------------------------------------

Interceptor.attach(Module.getGlobalExportByName('_AXUIElementPostNotification'), {
  onEnter(a) {
    const name = a[1];
    let text = null;
    if (!name.isNull()) {
      const p = CFStringGetCStringPtr(name, 0x08000100);
      text = p.isNull() ? str(name) : p.readUtf8String();
    }
    write({ type: 'call', ph: 'enter', fn: '_AXUIElementPostNotification', args: [text] });
  },
});

const atLoad = new NativeCallback(() => snapshot('load'), 'void', ['pointer']);
dispatch_async_f(mainQueue, NULL, atLoad);
