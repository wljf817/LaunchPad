// Record the search field of the macOS 15 Launchpad in Dock (reference VM): its layer subtree
// (frames, contents, hidden, opacity, the placeholder's text attributes), the ivars its layout
// reads, the frame -[ECSBLayer layout] gives it, the transaction state while
// -[ECTextInputLayer layout] runs, the animations its layout leaves on the sublayers, and the
// state setters as they are called.
// Frida 17 core API only (REF-ENV-003), helpers as lp-keyboard.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-search-field.js" }.
// Post keys with lp-input.js in the same session. Fetch the file with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-search-field-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread):
//   header    frida, pid, utc
//   tree      why, the grid layer (bounds, adjusted top margin, scale factor, the field's index
//             among its sublayers, every sublayer's class and frame, the scroll layer's frame),
//             the "no results" container and text layer (as a sublayer below, plus
//             allowsGroupBlending, string, font, fontSize, alignmentMode, preferredFrameSize) and
//             the field: its ivars (_type, _size, _margin,
//             _scaleFactor, the flag bytes, _placeholderAttributes), its layer properties and
//             every sublayer's (class, role, frame, bounds, hidden, opacity, contents image size,
//             contentsScale, contentsCenter, contentsGravity, animation keys with each
//             animation's class, key path, duration, begin time, timing function, from and to
//             values), and for the placeholder its string, font (PostScript name, size),
//             fontSize, foregroundColor and preferredFrameSize. Taken when the script loads,
//             1 s after -[Springboard setVisible:reason:] returns, right after every state
//             setter returns and 1 s after that
//   layout    enter and leave of -[ECTextInputLayer layout] and -setFrame:: the field's frame,
//             textFieldActive, and the current transaction's animationDuration,
//             animationTimingFunction and disableActions
//   call      enter and leave of the field's state setters (setTextFieldActive:, setHasFocus:,
//             setStringValue:, setFadeWhenNotActive:, setScaleFactor:, _darkenCancelLayer:) with
//             the argument
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

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const class_getClassMethod = nf(libobjc, 'class_getClassMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgUP = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);
const msgSize = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const CGColorGetNumberOfComponents = gf('CGColorGetNumberOfComponents', 'ulong', ['pointer']);
const CGColorGetComponents = gf('CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = gf('CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = gf('CGColorSpaceCopyName', 'pointer', ['pointer']);
const CGImageGetWidth = gf('CGImageGetWidth', 'ulong', ['pointer']);
const CGImageGetHeight = gf('CGImageGetHeight', 'ulong', ['pointer']);
const CFGetTypeID = gf('CFGetTypeID', 'ulong', ['pointer']);
const CGImageGetTypeID = gf('CGImageGetTypeID', 'ulong', []);
const CTFontGetTypeID = gf('CTFontGetTypeID', 'ulong', []);
const CGColorGetTypeID = gf('CGColorGetTypeID', 'ulong', []);
const CTFontCopyPostScriptName = gf('CTFontCopyPostScriptName', 'pointer', ['pointer']);
const CTFontGetSize = gf('CTFontGetSize', 'double', ['pointer']);
const pthread_main_np = gf('pthread_main_np', 'int', []);
const getenv = gf('getenv', 'pointer', ['pointer']);
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
function ivarOffset(className_, name) {
  return ivar_getOffset(class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name))).toNumber();
}
function ivar(obj, className_, name) {
  return obj.add(ivarOffset(className_, name)).readPointer();
}
function description(obj) {
  return obj.isNull() ? null : str(msgP(obj, sel('description')));
}
function rect(r) {
  return r === null ? null : { x: r[0], y: r[1], w: r[2], h: r[3] };
}
function color(c) {
  if (c.isNull()) return null;
  const n = Number(CGColorGetNumberOfComponents(c));
  const p = CGColorGetComponents(c);
  const components = [];
  for (let k = 0; k < n; k++) components.push(p.add(8 * k).readDouble());
  const name = CGColorSpaceCopyName(CGColorGetColorSpace(c));
  return { components, space: str(name) };
}
function cf(obj) {
  // A CF object that may be a CGImage, a CTFont, a CGColor or an Objective-C object.
  if (obj.isNull()) return null;
  const id = Number(CFGetTypeID(obj));
  if (id === Number(CGImageGetTypeID())) return { image: [Number(CGImageGetWidth(obj)), Number(CGImageGetHeight(obj))] };
  if (id === Number(CTFontGetTypeID())) return { font: str(CTFontCopyPostScriptName(obj)), size: CTFontGetSize(obj) };
  if (id === Number(CGColorGetTypeID())) return { color: color(obj) };
  return { class: className(obj), description: description(obj) };
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-search-field-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

// --- state ----------------------------------------------------------------

const dock = Process.mainModule;
// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2 (as lp-paging.js).
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

function grid() {
  const sb = springboardGlobal.readPointer();
  const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
  return msgP(msgP(ecsb, sel('pager')), sel('layer'));
}
function field() {
  return ivar(grid(), 'ECSBLayer', '_searchTextInputLayer');
}

function animations(layer) {
  const keys = msgP(layer, sel('animationKeys'));
  if (keys.isNull()) return [];
  const out = [];
  const n = Number(msgU(keys, sel('count')));
  for (let i = 0; i < n; i++) {
    const key = msgPU(keys, sel('objectAtIndex:'), i);
    const a = msgPP(layer, sel('animationForKey:'), key);
    const entry = { key: str(key), class: className(a) };
    if (msgUP(a, sel('respondsToSelector:'), sel('keyPath'))) entry.keyPath = str(msgP(a, sel('keyPath')));
    entry.duration = msgD(a, sel('duration'));
    entry.beginTime = msgD(a, sel('beginTime'));
    entry.timingFunction = description(msgP(a, sel('timingFunction')));
    if (msgUP(a, sel('respondsToSelector:'), sel('fromValue'))) {
      entry.from = description(msgP(a, sel('fromValue')));
      entry.to = description(msgP(a, sel('toValue')));
    }
    out.push(entry);
  }
  return out;
}

function layerInfo(layer, role) {
  if (layer.isNull()) return { role, layer: null };
  return {
    role,
    class: className(layer),
    frame: rect(msgRect(layer, sel('frame'))),
    bounds: rect(msgRect(layer, sel('bounds'))),
    hidden: !!msgB(layer, sel('isHidden')),
    opacity: msgF(layer, sel('opacity')),
    contents: cf(msgP(layer, sel('contents'))),
    contentsScale: msgD(layer, sel('contentsScale')),
    contentsCenter: rect(msgRect(layer, sel('contentsCenter'))),
    contentsGravity: str(msgP(layer, sel('contentsGravity'))),
    animations: animations(layer),
  };
}

function tree(why) {
  try {
    const g = grid();
    const f = field();
    const gridSublayers = msgP(g, sel('sublayers'));
    const roles = new Map();
    const named = ['_hostLayer', '_magnifyLayer', '_cancelSearchLayer', '_placeholderLayer'];
    for (const name of named) roles.set(ivar(f, 'ECTextInputLayer', name).toString(), name);
    const sublayers = msgP(f, sel('sublayers'));
    const subs = [];
    const n = sublayers.isNull() ? 0 : Number(msgU(sublayers, sel('count')));
    for (let i = 0; i < n; i++) {
      const l = msgPU(sublayers, sel('objectAtIndex:'), i);
      subs.push(layerInfo(l, roles.get(l.toString()) || null));
    }
    const placeholder = ivar(f, 'ECTextInputLayer', '_placeholderLayer');
    const ph = placeholder.isNull() ? null : {
      string: str(msgP(placeholder, sel('string'))),
      font: cf(msgP(placeholder, sel('font'))),
      fontSize: msgD(placeholder, sel('fontSize')),
      foregroundColor: color(msgP(placeholder, sel('foregroundColor'))),
      preferredFrameSize: msgSize(placeholder, sel('preferredFrameSize')),
      alignmentMode: str(msgP(placeholder, sel('alignmentMode'))),
      wrapped: !!msgB(placeholder, sel('isWrapped')),
      truncationMode: str(msgP(placeholder, sel('truncationMode'))),
    };
    const flags = {};
    for (const name of ['_textFieldActive', '_fadeWhenNotActive', '_hasFocus', '_layoutRTL', '_queueEvents', '_hasConnection']) {
      flags[name] = '0x' + f.add(ivarOffset('ECTextInputLayer', name)).readU8().toString(16);
    }
    const gridSubs = [];
    const gn = Number(msgU(gridSublayers, sel('count')));
    for (let i = 0; i < gn; i++) {
      const l = msgPU(gridSublayers, sel('objectAtIndex:'), i);
      gridSubs.push({ class: className(l), frame: rect(msgRect(l, sel('frame'))) });
    }
    const container = ivar(g, 'ECSBLayer', '_noResultsContainerLayer');
    const noResults = ivar(g, 'ECSBLayer', '_noResultsLayer');
    write({
      type: 'tree',
      why,
      grid: {
        bounds: rect(msgRect(g, sel('bounds'))),
        adjustedTopMargin: msgD(g, sel('adjustedTopMargin')),
        scaleFactor: msgF(g, sel('scaleFactor')),
        fieldIndex: Number(msgUP(gridSublayers, sel('indexOfObjectIdenticalTo:'), f)),
        sublayerCount: gn,
        sublayers: gridSubs,
        scrollLayerFrame: rect(msgRect(ivar(g, 'ECPagerLayer', '_scrollLayer'), sel('frame'))),
      },
      noResults: {
        container: Object.assign(layerInfo(container, 'container'),
          { allowsGroupBlending: !!msgB(container, sel('allowsGroupBlending')) }),
        layer: Object.assign(layerInfo(noResults, 'noResults'), {
          string: str(msgP(noResults, sel('string'))),
          font: cf(msgP(noResults, sel('font'))),
          fontSize: msgD(noResults, sel('fontSize')),
          alignmentMode: str(msgP(noResults, sel('alignmentMode'))),
          preferredFrameSize: msgSize(noResults, sel('preferredFrameSize')),
        }),
      },
      ivars: {
        type: f.add(ivarOffset('ECTextInputLayer', '_type')).readS64().toNumber(),
        size: [f.add(ivarOffset('ECTextInputLayer', '_size')).readDouble(),
          f.add(ivarOffset('ECTextInputLayer', '_size') + 8).readDouble()],
        margin: f.add(ivarOffset('ECTextInputLayer', '_margin')).readDouble(),
        scaleFactor: f.add(ivarOffset('ECTextInputLayer', '_scaleFactor')).readFloat(),
        flags,
        placeholderAttributes: description(ivar(f, 'ECTextInputLayer', '_placeholderAttributes')),
        stringValue: str(msgP(f, sel('stringValue'))),
      },
      field: layerInfo(f, 'field'),
      sublayers: subs,
      placeholder: ph,
    });
  } catch (e) {
    write({ type: 'note', what: 'tree failed', why, error: String(e) });
  }
}

const later = new NativeCallback(function (ctx) {
  const why = pending.get(ctx.toString());
  pending.delete(ctx.toString());
  tree(why);
}, 'void', ['pointer']);
const pending = new Map();
let nextContext = 1;
function treeLater(why, seconds) {
  const ctx = ptr(nextContext++);
  pending.set(ctx.toString(), why);
  dispatch_after_f(dispatch_time(0, seconds * 1e9), mainQueue, ctx, later);
}

// --- hooks ----------------------------------------------------------------

function hookInstance(className_, selector, onEnter, onLeave) {
  const m = class_getInstanceMethod(cls(className_), sel(selector));
  if (m.isNull()) {
    write({ type: 'note', what: 'no method', fn: className_ + '.' + selector });
    return;
  }
  Interceptor.attach(method_getImplementation(m), { onEnter, onLeave });
}

const CATransaction = cls('CATransaction');
function transaction() {
  return {
    animationDuration: msgD(CATransaction, sel('animationDuration')),
    animationTimingFunction: description(msgP(CATransaction, sel('animationTimingFunction'))),
    disableActions: !!msgB(CATransaction, sel('disableActions')),
  };
}

for (const selector of ['layout', 'setFrame:']) {
  hookInstance('ECTextInputLayer', selector,
    function () {
      this.self = this.context.x0;
      write({ type: 'layout', ph: 'enter', fn: selector, frame: rect(msgRect(this.self, sel('frame'))),
        textFieldActive: !!msgB(this.self, sel('textFieldActive')), transaction: transaction() });
    },
    function () {
      write({ type: 'layout', ph: 'leave', fn: selector, frame: rect(msgRect(this.self, sel('frame'))),
        textFieldActive: !!msgB(this.self, sel('textFieldActive')), transaction: transaction() });
    });
}

const setters = {
  'setTextFieldActive:': (c) => !!(c.x2.toInt32() & 1),
  'setHasFocus:': (c) => !!(c.x2.toInt32() & 1),
  'setFadeWhenNotActive:': (c) => !!(c.x2.toInt32() & 1),
  'setStringValue:': (c) => str(c.x2),
  'setScaleFactor:': (c) => '(float in s0)',
  '_darkenCancelLayer:': (c) => !!(c.x2.toInt32() & 1),
};
for (const [selector, arg] of Object.entries(setters)) {
  hookInstance('ECTextInputLayer', selector,
    function () {
      this.self = this.context.x0;
      write({ type: 'call', ph: 'enter', fn: selector, arg: arg(this.context) });
    },
    function () {
      write({ type: 'call', ph: 'leave', fn: selector });
      if (this.self.equals(field())) {
        tree('after ' + selector);
        treeLater('1 s after ' + selector, 1);
      }
    });
}

hookInstance('Springboard', 'setVisible:reason:',
  function () {
    this.visible = !!(this.context.x2.toInt32() & 1);
  },
  function () {
    treeLater('1 s after setVisible:' + this.visible, 1);
  });

const atLoad = new NativeCallback(function () {
  tree('load');
}, 'void', ['pointer']);
dispatch_async_f(mainQueue, ptr(0), atLoad);
