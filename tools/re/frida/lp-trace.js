// Trace the open and close sequence of the macOS 15 Launchpad in Dock
// (reference VM) on one clock, to measure call order, transaction use,
// completion order, window levels and the background image's timing.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge
// (REF-ENV-003), so Objective-C is driven through the runtime's C functions and
// objc_msgSend, as in ca-anim.js. Load it together with ca-anim.js to get the
// animations on the same clock (both use CACurrentMediaTime).
//
// Load through REA: start_frida_session { mode: "attach", remote }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-trace.js" }.
// Before unloading, wait for the message {type: "sampler", state: "stopped"}
// (sent about 2 s after the last open or close; the sampler runs callbacks on
// Dock's main queue, which must not outlive the script). Fetch the file with
// tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-trace-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written. REA messages
// carry only the file path, sampler state and script errors.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header  frida, pid, utc, dockBase, slide, springboard, launchpadWid,
//           dockBarWid, dockConnection, ca (the CA::Transaction::commit symbol
//           if found)
//   call    ph "enter" | "leave", fn (Class.selector or C function name), args,
//           ret, caller (Dock file address, or module+offset), depth (nesting
//           of traced Launchpad methods on the main thread), bg (true when not
//           on the main thread)
//   block   ph, invoke (Dock file address of the block function), block
//           (address): execution of completion blocks
//   sample  every ~8 ms on Dock's main queue while a trace window is active
//           (from each open or close request until 2 s after it, longer when
//           a longer transaction duration is set): vis (_visible), oc
//           (_openCount), att (overlay container attached to the window's root
//           layer), op [model, presentation] opacity of the overlay container,
//           sx [model, presentation] transform.scale.x of the main grid layer,
//           dl (background image layer address), dc (it has contents), dn
//           (sublayer count of the background container)
//   anim    the animation stored on the overlay container ("opacity"), the
//           main grid layer ("transform") or the background image layer
//           ("contents") the first time a sample sees it: beginTime, duration,
//           timing function, fromValue, toValue
//   sampler state "started" | "stopped"
//   note    hooks not installed (method not found, thunk) and other remarks
//
// Mode: "full" by default. With "light" as the first line of
// $HOME/frida-gadget/lp-trace-mode.txt, only -setVisible:reason:,
// LPSpringboard's -setVisible:slow:forGaming:reason:, -performEnterAnimation:,
// -performExitAnimation:, -orderWindowOn:, -layerForSpace:andDisplay:, the
// background image's -setContents:, -setOverrideShowType:,
// -removeOverrideShowType:, CGSSetWindowLevel, CGSHWCaptureWindowList and the
// four known completion block functions are traced, there is no sampler, and
// "anim" lines are read once after each request returns and after the
// background image is set (retried every 2 ms until the animation is
// committed), so that the trace itself slows Dock's main thread as little as
// possible.
//
// Methods whose body is a single branch (thunks such as
// -cleanupBeforeExitAnimation) are not traced: the interceptor would follow
// the branch into the shared objc_msgSend stub.
//
// Traced (enter and leave): Springboard -setVisible:reason:,
// -setVisible:slow:forGaming:reason: (Springboard's and LPSpringboard's),
// -_enterExitAnimation:slow:, -prepareForEnterAnimation,
// -performEnterAnimation:, -performExitAnimation:,
// -_cleanupBeforeExitAnimation, -_cleanupAfterExitAnimation:openCount:,
// -cleanupBeforeExitAnimation, -cleanupAfterExitAnimation, -orderWindowOn:,
// -updateDesktopImages, -_desktopPictureChanged:, -_newDesktopLayer,
// -_applyDesktopFilters, -processPendingUpdates;
// WallpaperAgentDesktopPictureManager -layerForSpace:andDisplay:;
// DockVisibility -setOverrideShowType:, -removeOverrideShowType:,
// -forceDockHiddenWithReason:, -removeForceDockHiddenWithReason:,
// -_setVisibilityStateAlreadyLocked:showsDock:updateRect:setOldFullScreenMode:;
// CGSSetWindowLevel, CGSHWCaptureWindowList, CPSStealKeyFocusOnConnection,
// CPSReleaseKeyFocusOnConnection. Only inside a trace window: DockGlobals
// -slowMotionAllowed, -axReduceMotion, +[ECModalEventController shiftKeyDown],
// +[CATransaction begin], +commit, +flush, +setCompletionBlock: (the block's
// function is then traced as a block), +animationDuration (return value),
// +setAnimationDuration:, +setAnimationTimingFunction:,
// SLSTransactionOrderWindowGroup, SLSTransactionCommit,
// SLSTransactionSetSafeApertureOverride, CoreCursorSet,
// CGSSetDisplayAcceleratorBoost, and CA::Transaction::commit when its symbol
// is found. -[CALayer setContents:] on the layer returned by
// -layerForSpace:andDisplay:, from its return until that layer gets contents
// (with the transaction's duration, timing function and disableActions).
//
// Nothing is written to Dock's objects.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  const p = Module.findGlobalExportByName(name);
  return p === null ? null : new NativeFunction(p, ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const class_getClassMethod = nf(libobjc, 'class_getClassMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgVPU = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'uint64']);
const msgVUP = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'uint64', 'pointer']);

const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const CFArrayGetCount = nf(cf, 'CFArrayGetCount', 'long', ['pointer']);
const CFArrayGetValueAtIndex = nf(cf, 'CFArrayGetValueAtIndex', 'pointer', ['pointer', 'long']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGImageGetTypeID = nf(cg, 'CGImageGetTypeID', 'ulong', []);
const CGImageGetWidth = nf(cg, 'CGImageGetWidth', 'size_t', ['pointer']);
const CGImageGetHeight = nf(cg, 'CGImageGetHeight', 'size_t', ['pointer']);
const CGColorGetTypeID = nf(cg, 'CGColorGetTypeID', 'ulong', []);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const NSGetSizeAndAlignment = nf(Process.getModuleByName('Foundation'), 'NSGetSizeAndAlignment', 'pointer', ['pointer', 'pointer', 'pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);
const pthread_main_np = new NativeFunction(Module.getGlobalExportByName('pthread_main_np'), 'int', []);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_time = nf(libdispatch, 'dispatch_time', 'uint64', ['uint64', 'int64']);
const dispatch_after_f = nf(libdispatch, 'dispatch_after_f', 'void', ['uint64', 'pointer', 'pointer', 'pointer']);
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
  const c = objc_getClass(Memory.allocUtf8String(name));
  if (c.isNull()) throw new Error('class not found: ' + name);
  return c;
}

const C = {
  CATransaction: cls('CATransaction'),
  CALayer: cls('CALayer'),
  CAMediaTimingFunction: cls('CAMediaTimingFunction'),
  NSString: cls('NSString'),
  NSNumber: cls('NSNumber'),
  NSValue: cls('NSValue'),
  NSNotification: cls('NSNotification'),
};
const cgImageTypeID = CGImageGetTypeID().toString();
const cgColorTypeID = CGColorGetTypeID().toString();

// --- numbers (exact shortest decimal, as in ca-anim.js) -------------------

function num(x) {
  if (Number.isFinite(x)) return x;
  if (Number.isNaN(x)) return 'nan';
  return x > 0 ? 'inf' : '-inf';
}

const NUMBER_MARK = '\u0001';
const NUMBER_TEXT = /"\\u0001([^"]*)"/g;
const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);

function pow10(n) {
  return 10n ** BigInt(n);
}

function exactNumber(x) {
  if (x === 0) return '0';
  f64[0] = x;
  const bits = u64[0];
  const neg = (bits >> 63n) === 1n;
  const biased = (bits >> 52n) & 0x7ffn;
  const frac = bits & ((1n << 52n) - 1n);
  const m = biased === 0n ? frac : frac | (1n << 52n);
  const e = Number(biased === 0n ? -1074n : biased - 1075n);
  const twoUp = e - 2 >= 0 ? 1n << BigInt(e - 2) : 1n;
  const twoDown = e - 2 < 0 ? 1n << BigInt(2 - e) : 1n;
  const lowGap = frac === 0n && biased > 1n ? 1n : 2n;
  const even = (m & 1n) === 0n;
  const p = Math.floor(Math.log10(Math.abs(x)));
  for (let n = 1; n <= 17; n++) {
    const k = p - n + 1;
    const up10 = k > 0 ? pow10(k) : 1n;
    const down10 = k < 0 ? pow10(-k) : 1n;
    const value = 4n * m * twoUp * down10;
    const unit = up10 * twoDown;
    let d = value / unit;
    const rest = value - d * unit;
    if (2n * rest > unit || (2n * rest === unit && (d & 1n) === 1n)) d += 1n;
    const diff = d * unit - value;
    const gap = (diff >= 0n ? 2n : lowGap) * twoUp * down10;
    const dist = diff >= 0n ? diff : -diff;
    if (dist < gap || (dist === gap && even)) return (neg ? '-' : '') + decimal(d.toString(), k);
  }
  throw new Error('exactNumber failed for ' + x);
}

function decimal(digits, k) {
  digits = digits.replace(/0+$/, z => { k += z.length; return ''; });
  if (digits === '') return '0';
  const point = digits.length + k;
  if (k >= 0 && point <= 21) return digits + '0'.repeat(k);
  if (point > 0 && point <= 21) return digits.slice(0, point) + '.' + digits.slice(point);
  if (point <= 0 && point > -6) return '0.' + '0'.repeat(-point) + digits;
  return digits[0] + (digits.length > 1 ? '.' + digits.slice(1) : '') + 'e' + (point - 1);
}

// --- values ---------------------------------------------------------------

function isKind(obj, c) {
  return !!msgBP(obj, sel('isKindOfClass:'), c);
}

function str(nsString) {
  if (nsString.isNull()) return null;
  return msgP(nsString, sel('UTF8String')).readUtf8String();
}

function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}

const nsStrings = new Map();
function nsString(text) {
  let s = nsStrings.get(text);
  if (s === undefined) {
    s = msgPP(C.NSString, sel('stringWithUTF8String:'), Memory.allocUtf8String(text));
    msgP(s, sel('retain'));
    nsStrings.set(text, s);
  }
  return s;
}

function timingPoints(tf) {
  if (tf.isNull()) return null;
  const pt = Memory.alloc(8);
  const points = [];
  for (let i = 0; i < 4; i++) {
    msgVUP(tf, sel('getControlPointAtIndex:values:'), i, pt);
    points.push([num(pt.readFloat()), num(pt.add(4).readFloat())]);
  }
  return points;
}

// Small values only: numbers, strings, CATransform3D as its m11 (scale x).
function small(obj) {
  if (obj.isNull()) return null;
  const tid = CFGetTypeID(obj).toString();
  if (tid === cgImageTypeID) {
    return { cgImage: [CGImageGetWidth(obj).toNumber(), CGImageGetHeight(obj).toNumber()] };
  }
  if (tid === cgColorTypeID) return { cgColor: true };
  if (isKind(obj, C.NSString)) return str(obj);
  if (isKind(obj, C.NSNumber)) return num(msgD(obj, sel('doubleValue')));
  if (isKind(obj, C.NSValue)) {
    const typePtr = msgP(obj, sel('objCType'));
    const type = typePtr.readUtf8String();
    const sizeBuf = Memory.alloc(16);
    NSGetSizeAndAlignment(typePtr, sizeBuf, sizeBuf.add(8));
    const size = sizeBuf.readU64().toNumber();
    const buf = Memory.alloc(Math.max(size, 1));
    msgVPU(obj, sel('getValue:size:'), buf, size);
    if (type.startsWith('{CATransform3D=')) {
      const m = [];
      for (let i = 0; i < 16; i++) m.push(num(buf.add(i * 8).readDouble()));
      return { transform: m };
    }
    return { objCType: type };
  }
  return { class: className(obj) };
}

// --- Dock -----------------------------------------------------------------

const dock = Process.mainModule;
const fileBase = ptr('0x100000000');
const slide = dock.base.sub(fileBase);
const dockEnd = dock.base.add(dock.size);

function dockAddr(fileAddr) {
  return ptr(fileAddr).add(slide);
}

function inDock(p) {
  return p.compare(dock.base) >= 0 && p.compare(dockEnd) < 0;
}

function where(address) {
  const a = address.strip();
  if (inDock(a)) return '0x' + a.sub(slide).toString(16);
  const m = Process.findModuleByAddress(a);
  return m === null ? a.toString() : m.name + '+0x' + a.sub(m.base).toString(16);
}

const springboardGlobal = dockAddr('0x100448168');
const dockBarGlobal = dockAddr('0x100448138');
const dockGlobalsGlobal = dockAddr('0x100448200');

// Springboard ivar offsets (notes/lp-model/ivar-offsets.txt).
const IV = { window: 0x8, layer: 0x10, springboard: 0x28, desktopContainer: 0xe0, desktopLayer: 0xe8, openCount: 0x100, flags: 0x134 };

function sb() {
  return springboardGlobal.readPointer();
}

function windowWid(win) {
  return win.isNull() ? null : msgU32(win, sel('wid'));
}

// --- output ---------------------------------------------------------------

function utcStamp(d) {
  return d.toISOString().replace(/[-:]/g, '');
}

const loadDate = new Date();
const path = getenv(Memory.allocUtf8String('HOME')).readUtf8String() +
  '/frida-gadget/lp-trace-' + utcStamp(loadDate) + '.jsonl';
const file = new File(path, 'wx');

function writeLine(obj) {
  const text = JSON.stringify(obj, (k, v) => typeof v === 'number' ? NUMBER_MARK + exactNumber(v) : v);
  file.write(text.replace(NUMBER_TEXT, '$1') + '\n');
  file.flush();
}

function now() {
  return CACurrentMediaTime();
}

// Mode: "full" (default) or "light", from the first line of
// $HOME/frida-gadget/lp-trace-mode.txt if that file exists.
let mode = 'full';
try {
  const m = File.readAllText(getenv(Memory.allocUtf8String('HOME')).readUtf8String() + '/frida-gadget/lp-trace-mode.txt').split('\n')[0].trim();
  if (m === 'light') mode = 'light';
} catch (e) {
  mode = 'full';
}
const LIGHT = mode === 'light';

function fail(e) {
  send({ type: 'error', message: String(e), stack: e.stack });
}

// --- trace window and sampler ---------------------------------------------

let activeUntil = 0;
let samplerRunning = false;

function active() {
  return now() < activeUntil;
}

function extend(seconds) {
  const until = now() + seconds;
  if (until > activeUntil) activeUntil = until;
  if (!LIGHT) ensureSampler();
}

const seenAnimations = new Set();

// Returns "none", "uncommitted" (beginTime still 0: not recorded yet),
// "seen" or "recorded".
function animRecord(t, which, layer, key) {
  if (layer.isNull()) return 'none';
  const a = msgPP(layer, sel('animationForKey:'), nsString(key));
  if (a.isNull()) return 'none';
  const id = a.toString();
  const begin = msgD(a, sel('beginTime'));
  if (begin === 0) return 'uncommitted';
  // Addresses are reused by later animation objects: the key includes the
  // layer, the key path and the begin time.
  const seenKey = layer.toString() + '/' + key + '/' + id + '/' + begin;
  if (seenAnimations.has(seenKey)) return 'seen';
  seenAnimations.add(seenKey);
  const rec = {
    type: 'anim', t, which, key, address: id, class: className(a),
    beginTime: num(msgD(a, sel('beginTime'))),
    duration: num(msgD(a, sel('duration'))),
    timingFunction: timingPoints(msgP(a, sel('timingFunction'))),
  };
  if (!!msgBP(a, sel('respondsToSelector:'), sel('fromValue'))) {
    rec.fromValue = small(msgP(a, sel('fromValue')));
    rec.toValue = small(msgP(a, sel('toValue')));
  }
  writeLine(rec);
  return 'recorded';
}

function scaleX(layer) {
  if (layer.isNull()) return null;
  const v = msgPP(layer, sel('valueForKeyPath:'), nsString('transform.scale.x'));
  return v.isNull() ? null : num(msgD(v, sel('doubleValue')));
}

function sample() {
  const t = now();
  const s = sb();
  if (s.isNull()) return;
  const L = s.add(IV.layer).readPointer();
  const D = s.add(IV.desktopLayer).readPointer();
  const DC = s.add(IV.desktopContainer).readPointer();
  const ecsb = s.add(IV.springboard).readPointer();
  const G = ecsb.isNull() ? NULL : msgP(ecsb, sel('layer'));
  const pL = msgP(L, sel('presentationLayer'));
  const pG = G.isNull() ? NULL : msgP(G, sel('presentationLayer'));
  const subs = msgP(DC, sel('sublayers'));
  const rec = {
    type: 'sample', t,
    vis: s.add(IV.flags).readU8() & 1,
    oc: s.add(IV.openCount).readU32(),
    att: !msgP(L, sel('superlayer')).isNull(),
    op: [num(msgF(L, sel('opacity'))), pL.isNull() ? null : num(msgF(pL, sel('opacity')))],
    sx: [scaleX(G), scaleX(pG)],
    dl: D.isNull() ? null : D.toString(),
    dc: D.isNull() ? null : !msgP(D, sel('contents')).isNull(),
    dn: subs.isNull() ? 0 : msgU(subs, sel('count')).toNumber(),
  };
  writeLine(rec);
  animRecord(t, 'overlay', L, 'opacity');
  animRecord(t, 'grid', G, 'transform');
  animRecord(t, 'background', D, 'contents');
  if (!subs.isNull()) {
    const n = msgU(subs, sel('count')).toNumber();
    for (let i = 0; i < n; i++) {
      const l = msgPU(subs, sel('objectAtIndex:'), i);
      if (!l.equals(D)) animRecord(t, 'background-other', l, 'contents');
      animRecord(t, 'background-opacity', l, 'opacity');
    }
  }
}

const sampleCallback = new NativeCallback(() => {
  try {
    sample();
  } catch (e) {
    fail(e);
  }
  if (now() < activeUntil) {
    schedule();
  } else {
    samplerRunning = false;
    writeLine({ type: 'sampler', state: 'stopped', t: now() });
    send({ type: 'sampler', state: 'stopped' });
  }
}, 'void', ['pointer']);

function schedule() {
  dispatch_after_f(dispatch_time(0, 8000000), mainQueue, NULL, sampleCallback);
}

// Light mode: instead of the sampler, read the stored animations once after
// each open or close request and after the background image is set, retrying
// every 2 ms (up to 100 times) while one of them is not committed yet.
let oneShotTries = 0;
const oneShotCallback = new NativeCallback(() => {
  let again = false;
  try {
    const s = sb();
    const L = s.add(IV.layer).readPointer();
    const D = s.add(IV.desktopLayer).readPointer();
    const ecsb = s.add(IV.springboard).readPointer();
    const G = ecsb.isNull() ? NULL : msgP(ecsb, sel('layer'));
    const t = now();
    const r = [animRecord(t, 'overlay', L, 'opacity'), animRecord(t, 'grid', G, 'transform'), animRecord(t, 'background', D, 'contents')];
    again = r.indexOf('uncommitted') >= 0;
  } catch (e) {
    fail(e);
  }
  if (again && oneShotTries++ < 100) dispatch_after_f(dispatch_time(0, 2000000), mainQueue, NULL, oneShotCallback);
}, 'void', ['pointer']);

function oneShot() {
  oneShotTries = 0;
  dispatch_after_f(dispatch_time(0, 0), mainQueue, NULL, oneShotCallback);
}

function ensureSampler() {
  if (samplerRunning) return;
  samplerRunning = true;
  writeLine({ type: 'sampler', state: 'started', t: now() });
  send({ type: 'sampler', state: 'started' });
  schedule();
}

// --- hooks ----------------------------------------------------------------

const hooked = new Map();
let depth = 0;

function argValue(kind, a, ctx, index) {
  switch (kind) {
    case 'bool': return a.and(0xff).toInt32();
    case 'u32': return a.and(0xffffffff).toUInt32();
    case 'i32': return a.toInt32();
    case 'u64': return '0x' + a.toString(16);
    case 'ptr': return a.toString();
    case 'str': return a.isNull() ? null : str(a);
    case 'obj': return a.isNull() ? null : { class: className(a), address: a.toString() };
    case 'tf': return timingPoints(a);
    case 'note': {
      if (a.isNull()) return null;
      const info = msgP(a, sel('userInfo'));
      return {
        name: str(msgP(a, sel('name'))),
        object: small(msgP(a, sel('object'))),
        userInfo: info.isNull() ? null : str(msgP(info, sel('description'))),
      };
    }
    default: return null;
  }
}

function common(rec) {
  if (pthread_main_np() === 0) rec.bg = true;
  return rec;
}

// spec: { args: [[index, kind, name]], ret: kind, gate, enter(args, rec), leave(retval, rec, state) }
function hookAt(name, address, spec) {
  const key = address.strip().toString();
  if (hooked.has(key)) {
    writeLine({ type: 'note', t: now(), note: 'same implementation', fn: name, as: hooked.get(key) });
    return;
  }
  // A method whose body is a single branch (a thunk that forwards to another
  // selector) is not traced: the interceptor would follow the branch and
  // hook the shared objc_msgSend stub, so every send of the forwarded
  // selector would be recorded under this name.
  const a = address.strip();
  if (inDock(a) && (a.readU32() & 0xfc000000) === 0x14000000) {
    writeLine({ type: 'note', t: now(), note: 'thunk (single branch), not traced', fn: name });
    return;
  }
  hooked.set(key, name);
  Interceptor.attach(address, {
    onEnter(args) {
      this.rec = null;
      try {
        if (spec.gate && !active()) return;
        if (spec.before) spec.before.call(this, args);
        const rec = common({ type: 'call', ph: 'enter', fn: name, t: now(), caller: where(this.returnAddress) });
        if (spec.lp) rec.depth = depth++;
        if (spec.args) {
          rec.args = {};
          for (const [i, kind, label] of spec.args) rec.args[label] = argValue(kind, args[i], this.context, i);
        }
        if (spec.enter) spec.enter.call(this, args, rec);
        this.rec = rec;
        writeLine(rec);
      } catch (e) {
        fail(e);
      }
    },
    onLeave(retval) {
      if (this.rec === null) return;
      try {
        if (spec.lp) depth--;
        const rec = common({ type: 'call', ph: 'leave', fn: name, t: now() });
        if (spec.ret) rec.ret = argValue(spec.ret, retval, this.context, -1);
        if (spec.leave) spec.leave.call(this, retval, rec);
        writeLine(rec);
      } catch (e) {
        fail(e);
      }
    },
  });
}

function methodImp(className_, selName, isClassMethod) {
  const c = cls(className_);
  const m = isClassMethod ? class_getClassMethod(c, sel(selName)) : class_getInstanceMethod(c, sel(selName));
  if (m.isNull()) return null;
  return method_getImplementation(m).strip();
}

function hookMethod(className_, selName, spec, isClassMethod) {
  const name = (isClassMethod ? '+' : '-') + '[' + className_ + ' ' + selName + ']';
  try {
    const imp = methodImp(className_, selName, isClassMethod);
    if (imp === null) {
      writeLine({ type: 'note', t: now(), note: 'method not found', fn: name });
      return;
    }
    hookAt(name, imp, spec);
  } catch (e) {
    writeLine({ type: 'note', t: now(), note: 'hook failed: ' + e, fn: name });
  }
}

function hookFunction(fnName, spec) {
  const p = Module.findGlobalExportByName(fnName);
  if (p === null) {
    writeLine({ type: 'note', t: now(), note: 'function not found', fn: fnName });
    return;
  }
  hookAt(fnName, p, spec);
}

// Completion blocks: their functions are traced as "block" lines.
const hookedBlocks = new Set();

function hookBlockFunction(fileAddress) {
  if (hookedBlocks.has(fileAddress)) return;
  hookedBlocks.add(fileAddress);
  Interceptor.attach(dockAddr(fileAddress), {
    onEnter(args) {
      try {
        writeLine(common({ type: 'block', ph: 'enter', invoke: fileAddress, block: args[0].toString(), t: now() }));
      } catch (e) {
        fail(e);
      }
    },
    onLeave() {
      try {
        writeLine(common({ type: 'block', ph: 'leave', invoke: fileAddress, t: now() }));
      } catch (e) {
        fail(e);
      }
    },
  });
}

// Known completion block functions (launchpad.md section 5.1).
for (const a of ['0x10002ec78', '0x100030e58', '0x1000b005c', '0x1000919d0']) hookBlockFunction(a);

// The background image layer whose contents are awaited.
const awaitedLayers = new Set();
let setContentsListener = null;

function startContentsWatch() {
  if (setContentsListener !== null) return;
  const imp = methodImp('CALayer', 'setContents:', false);
  setContentsListener = Interceptor.attach(imp, {
    onEnter(args) {
      const k = args[0].toString();
      if (!awaitedLayers.has(k)) return;
      try {
        writeLine(common({
          type: 'call', ph: 'enter', fn: '-[CALayer setContents:]', t: now(), layer: k,
          caller: where(this.returnAddress),
          contents: small(args[2]),
          transaction: {
            animationDuration: num(msgD(C.CATransaction, sel('animationDuration'))),
            animationTimingFunction: timingPoints(msgP(C.CATransaction, sel('animationTimingFunction'))),
            disableActions: !!msgB(C.CATransaction, sel('disableActions')),
          },
        }));
        if (!args[2].isNull()) {
          if (LIGHT) oneShot();
          awaitedLayers.delete(k);
          if (awaitedLayers.size === 0) setTimeout(stopContentsWatch, 0);
        }
      } catch (e) {
        fail(e);
      }
    },
  });
}

function stopContentsWatch() {
  if (setContentsListener !== null && awaitedLayers.size === 0) {
    setContentsListener.detach();
    setContentsListener = null;
  }
}

const B = 'bool';

// Springboard (Launchpad's controller). In light mode only the calls marked
// "light" below are traced, to keep the trace's own cost on Dock's main thread
// small for timing measurements.
const lp = { lp: true };
hookMethod('Springboard', 'setVisible:reason:', {
  lp: true, args: [[2, B, 'visible'], [3, 'str', 'reason']],
  before() { extend(2.0); },
  leave() { if (LIGHT) oneShot(); },
}); // light
hookMethod('LPSpringboard', 'setVisible:slow:forGaming:reason:', {
  lp: true, args: [[2, B, 'visible'], [3, B, 'slow'], [4, B, 'forGaming'], [5, 'str', 'reason']],
  before(args) { extend(args[3].and(0xff).toInt32() ? 6.0 : 2.0); },
}); // light
hookMethod('Springboard', 'performEnterAnimation:', { lp: true, args: [[2, B, 'slow']] }); // light
hookMethod('Springboard', 'performExitAnimation:', { lp: true, args: [[2, B, 'slow']] }); // light
hookMethod('Springboard', 'orderWindowOn:', { lp: true, args: [[2, B, 'on']] }); // light
hookMethod('_TtC8DockCore35WallpaperAgentDesktopPictureManager', 'layerForSpace:andDisplay:', {
  lp: true, args: [[2, 'obj', 'space'], [3, 'u32', 'display']], ret: 'ptr',
  leave(retval) {
    if (!retval.isNull()) {
      awaitedLayers.add(retval.toString());
      startContentsWatch();
    }
  },
}); // light
hookMethod('DockVisibility', 'setOverrideShowType:', { args: [[2, 'u64', 'type']] }); // light
hookMethod('DockVisibility', 'removeOverrideShowType:', { args: [[2, 'u64', 'type']] }); // light
hookFunction('CGSSetWindowLevel', { args: [[0, 'i32', 'cid'], [1, 'u32', 'wid'], [2, 'i32', 'level']], ret: 'i32' }); // light
hookFunction('CGSHWCaptureWindowList', {
  args: [[0, 'i32', 'cid'], [2, 'u32', 'count'], [3, 'u64', 'options']],
  enter(args, rec) {
    const n = args[2].toUInt32();
    const wids = [];
    for (let i = 0; i < n && i < 16; i++) wids.push(args[1].add(i * 4).readU32());
    rec.args.wids = wids;
  },
  leave(retval, rec) {
    if (retval.isNull()) { rec.ret = null; return; }
    const n = CFArrayGetCount(retval).toNumber();
    const images = [];
    for (let i = 0; i < n; i++) images.push(small(CFArrayGetValueAtIndex(retval, i)));
    rec.ret = images;
  },
}); // light

if (!LIGHT) {
  hookMethod('Springboard', 'setVisible:slow:forGaming:reason:', {
    lp: true, args: [[2, B, 'visible'], [3, B, 'slow'], [4, B, 'forGaming'], [5, 'str', 'reason']],
  });
  hookMethod('Springboard', '_enterExitAnimation:slow:', { lp: true, args: [[2, B, 'enter'], [3, B, 'slow']] });
  hookMethod('Springboard', 'prepareForEnterAnimation', lp);
  hookMethod('Springboard', '_cleanupBeforeExitAnimation', lp);
  hookMethod('Springboard', '_cleanupAfterExitAnimation:openCount:', { lp: true, args: [[2, 'ptr', 'layer'], [3, 'u32', 'openCount']],
    enter(args, rec) { rec.openCountNow = sb().add(IV.openCount).readU32(); } });
  hookMethod('Springboard', 'cleanupBeforeExitAnimation', lp);
  hookMethod('Springboard', 'cleanupAfterExitAnimation', lp);
  hookMethod('Springboard', 'updateDesktopImages', { lp: true,
    enter(args, rec) {
      const s = sb();
      rec.desktopLayer = s.add(IV.desktopLayer).readPointer().toString();
      rec.visible = s.add(IV.flags).readU8() & 1;
      rec.desktopStale = (s.add(0x135).readU8() >> 3) & 1;
      rec.desktopLastUUID = str(s.add(0x118).readPointer());
    },
    leave(retval, rec) {
      const s = sb();
      rec.desktopStale = (s.add(0x135).readU8() >> 3) & 1;
      rec.desktopLastUUID = str(s.add(0x118).readPointer());
      rec.desktopLayer = s.add(IV.desktopLayer).readPointer().toString();
    } });
  hookMethod('Springboard', '_desktopPictureChanged:', { lp: true, args: [[2, 'note', 'notification']] });
  hookMethod('Springboard', '_newDesktopLayer', { lp: true, ret: 'ptr' });
  hookMethod('Springboard', '_applyDesktopFilters', lp);
  hookMethod('Springboard', 'processPendingUpdates', lp);

  // Dock visibility.
  hookMethod('DockVisibility', 'forceDockHiddenWithReason:', { args: [[2, 'str', 'reason']] });
  hookMethod('DockVisibility', 'removeForceDockHiddenWithReason:', { args: [[2, 'str', 'reason']] });
  hookMethod('DockVisibility', '_setVisibilityStateAlreadyLocked:showsDock:updateRect:setOldFullScreenMode:', {
    args: [[2, B, 'alreadyLocked'], [3, B, 'showsDock'], [4, B, 'updateRect'], [5, B, 'setOldFullScreenMode']] });

  // Variants (only inside a trace window).
  hookMethod('DockGlobals', 'slowMotionAllowed', { gate: true, ret: B });
  hookMethod('DockGlobals', 'axReduceMotion', { gate: true, ret: B });
  hookMethod('ECModalEventController', 'shiftKeyDown', { gate: true, ret: B }, true);

  // Core Animation transactions (only inside a trace window).
  hookMethod('CATransaction', 'begin', { gate: true }, true);
  hookMethod('CATransaction', 'commit', { gate: true }, true);
  hookMethod('CATransaction', 'flush', { gate: true }, true);
  hookMethod('CATransaction', 'setCompletionBlock:', {
    gate: true, args: [[2, 'ptr', 'block']],
    enter(args, rec) {
      const b = args[2];
      if (b.isNull()) return;
      const invoke = b.add(16).readPointer().strip();
      rec.invoke = where(invoke);
      if (inDock(invoke)) hookBlockFunction('0x' + invoke.sub(slide).toString(16));
    },
  }, true);
  hookMethod('CATransaction', 'animationDuration', {
    gate: true,
    leave(retval, rec) {
      const d = this.context.d0;
      rec.ret = typeof d === 'number' ? num(d) : num(msgD(C.CATransaction, sel('animationDuration')));
    },
  }, true);
  hookMethod('CATransaction', 'setAnimationDuration:', {
    gate: true,
    enter(args, rec) {
      const d = this.context.d0;
      if (typeof d === 'number') {
        rec.args = { duration: num(d) };
        if (d > 1) extend(d + 1.0);
      }
    },
    leave(retval, rec) {
      rec.now = num(msgD(C.CATransaction, sel('animationDuration')));
    },
  }, true);
  hookMethod('CATransaction', 'setAnimationTimingFunction:', { gate: true, args: [[2, 'tf', 'timingFunction']] }, true);

  // Window server.
  hookFunction('CPSStealKeyFocusOnConnection', { args: [[0, 'i32', 'cid'], [1, 'u64', 'flags']], ret: 'i32' });
  hookFunction('CPSReleaseKeyFocusOnConnection', { args: [[0, 'i32', 'cid']], ret: 'i32' });
  hookFunction('CoreCursorSet', { gate: true, args: [[0, 'i32', 'cid'], [1, 'i32', 'cursor']], ret: 'i32' });
  hookFunction('CGSSetDisplayAcceleratorBoost', { gate: true, args: [[0, 'u32', 'display'], [1, 'i32', 'boost']], ret: 'i32' });
  hookFunction('SLSTransactionOrderWindowGroup', { gate: true, args: [[0, 'ptr', 'transaction'], [1, 'u32', 'wid'], [2, 'i32', 'order'], [3, 'u32', 'relativeTo']] });
  hookFunction('SLSTransactionCommit', { gate: true, args: [[0, 'ptr', 'transaction'], [1, 'i32', 'flag']], ret: 'i32' });
  hookFunction('SLSTransactionSetSafeApertureOverride', { gate: true, args: [[0, 'ptr', 'transaction'], [1, 'u32', 'display']],
    enter(args, rec) { const d = this.context.d0; if (typeof d === 'number') rec.args.value = num(d); } });
}

// CA::Transaction::commit, the commit of the outermost (also implicit)
// transaction, if its symbol can be found.
let caCommit = null;
try {
  const qc = Process.getModuleByName('QuartzCore');
  caCommit = qc.findExportByName('_ZN2CA11Transaction6commitEv');
  if (caCommit === null) {
    const s = DebugSymbol.fromName('_ZN2CA11Transaction6commitEv');
    if (s !== null && !s.address.isNull()) caCommit = s.address;
  }
} catch (e) {
  caCommit = null;
}
if (caCommit !== null && !LIGHT) hookAt('CA::Transaction::commit', caCommit, { gate: true });

// --- header ---------------------------------------------------------------

(function header() {
  const s = sb();
  const dockBar = dockBarGlobal.readPointer();
  const dockGlobals = dockGlobalsGlobal.readPointer();
  writeLine({
    type: 'header', t: now(), frida: Frida.version, pid: Process.id, utc: loadDate.toISOString(),
    dockBase: dock.base.toString(), slide: slide.toString(),
    springboard: s.toString(),
    launchpadWid: windowWid(s.add(IV.window).readPointer()),
    dockBarWid: dockBar.isNull() ? null : windowWid(msgP(dockBar, sel('window'))),
    dockConnection: dockGlobals.isNull() ? null : msgU32(dockGlobals, sel('dockConnection')),
    caCommit: caCommit === null ? null : where(caCommit),
    mode,
  });
})();

send({ type: 'file', path });
