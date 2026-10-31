// Record the search field and the "no results" layers of this project's background process
// (LaunchPadAgent, macOS 26 comparison VM) in the shape of the "tree" lines of lp-search-field.js,
// so the two can be compared (search spec, "打开后的搜索框 layer", "打开后的位置", "打开后的
// 「无结果」"). Frida 17 core API only (no Objective-C bridge), as lp-search-field.js.
//
// Load it through REA into the agent started with frida-gadget listening (as lp-paging-launchpad.js),
// while the overlay is open. On load it reads the state once on the main queue. The controller comes
// from the application delegate's `springboard`; the rest goes through the same Objective-C names as
// in Dock. Swift stored properties appear as ivars named like the property.
//
// File: $HOME/frida-gadget/lp-search-field-launchpad-<UTC load time>.jsonl in the target process,
// created exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the line is
// written on the main thread):
//   header    frida, pid, utc
//   tree      as lp-search-field.js's: the grid layer (bounds, adjusted top margin, scale factor, the
//             field's index among its sublayers, every sublayer's class and frame, the scroll layer's
//             frame, the adjusted margins and the notch height the layout uses), the "no results"
//             container and text layer, the field's ivars, its layer properties and every
//             sublayer's, the placeholder's text attributes; and, for the placeholder, the line
//             metrics (ascent, descent, leading of a CTLine made from the placeholder string with
//             _placeholderAttributes) the field's layout reads
//   note      failures
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
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
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
const CFRelease = gf('CFRelease', 'void', ['pointer']);
const CGImageGetTypeID = gf('CGImageGetTypeID', 'ulong', []);
const CTFontGetTypeID = gf('CTFontGetTypeID', 'ulong', []);
const CGColorGetTypeID = gf('CGColorGetTypeID', 'ulong', []);
const CTFontCopyPostScriptName = gf('CTFontCopyPostScriptName', 'pointer', ['pointer']);
const CTFontGetSize = gf('CTFontGetSize', 'double', ['pointer']);
const CFAttributedStringCreate = gf('CFAttributedStringCreate', 'pointer', ['pointer', 'pointer', 'pointer']);
const CTLineCreateWithAttributedString = gf('CTLineCreateWithAttributedString', 'pointer', ['pointer']);
const CTLineGetTypographicBounds = gf('CTLineGetTypographicBounds', 'double', ['pointer', 'pointer', 'pointer', 'pointer']);
const pthread_main_np = gf('pthread_main_np', 'int', []);
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
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}
// Swift stored properties appear as ivars named like the property; looked up on the object's class.
function ivarAddress(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className(obj) + '.' + name);
  return obj.add(ivar_getOffset(iv).toNumber());
}
function ivar(obj, name) {
  return ivarAddress(obj, name).readPointer();
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
const path = home + '/frida-gadget/lp-search-field-launchpad-' + utc + '.jsonl';
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

function grid() {
  const app = msgP(cls('NSApplication'), sel('sharedApplication'));
  const controller = ivar(msgP(app, sel('delegate')), 'springboard');
  if (controller.isNull()) throw new Error('no controller yet');
  return msgP(ivar(controller, 'springboard'), sel('layer'));
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
  };
}

function textInfo(layer) {
  return {
    string: str(msgP(layer, sel('string'))),
    font: cf(msgP(layer, sel('font'))),
    fontSize: msgD(layer, sel('fontSize')),
    foregroundColor: color(msgP(layer, sel('foregroundColor'))),
    compositingFilter: description(msgP(layer, sel('compositingFilter'))),
    preferredFrameSize: msgSize(layer, sel('preferredFrameSize')),
    alignmentMode: str(msgP(layer, sel('alignmentMode'))),
    wrapped: !!msgB(layer, sel('isWrapped')),
    truncationMode: str(msgP(layer, sel('truncationMode'))),
  };
}

// ascent, descent and leading of a CTLine made from the string with the attributes.
function lineMetrics(string, attributes) {
  if (string.isNull() || attributes.isNull()) return null;
  const attributed = CFAttributedStringCreate(NULL, string, attributes);
  const line = CTLineCreateWithAttributedString(attributed);
  CFRelease(attributed);
  if (line.isNull()) return null;
  const out = Memory.alloc(24);
  const width = CTLineGetTypographicBounds(line, out, out.add(8), out.add(16));
  CFRelease(line);
  return { width, ascent: out.readDouble(), descent: out.add(8).readDouble(), leading: out.add(16).readDouble() };
}

function tree(why) {
  try {
    const g = grid();
    const f = msgP(g, sel('searchTextInputLayer'));
    const gridSublayers = msgP(g, sel('sublayers'));
    const roles = new Map();
    for (const name of ['_hostLayer', '_magnifyLayer', '_cancelSearchLayer', '_placeholderLayer']) {
      roles.set(ivar(f, name).toString(), name);
    }
    const sublayers = msgP(f, sel('sublayers'));
    const subs = [];
    const n = sublayers.isNull() ? 0 : Number(msgU(sublayers, sel('count')));
    for (let i = 0; i < n; i++) {
      const l = msgPU(sublayers, sel('objectAtIndex:'), i);
      subs.push(layerInfo(l, roles.get(l.toString()) || null));
    }
    const placeholder = ivar(f, '_placeholderLayer');
    const attributes = ivar(f, '_placeholderAttributes');
    const ph = placeholder.isNull() ? null : Object.assign(textInfo(placeholder),
      { lineMetrics: lineMetrics(msgP(placeholder, sel('string')), attributes) });
    const flags = {};
    for (const name of ['_textFieldActive', '_fadeWhenNotActive', '_hasFocus', '_layoutRTL', '_queueEvents']) {
      flags[name] = '0x' + ivarAddress(f, name).readU8().toString(16);
    }
    const gridSubs = [];
    const gn = Number(msgU(gridSublayers, sel('count')));
    for (let i = 0; i < gn; i++) {
      const l = msgPU(gridSublayers, sel('objectAtIndex:'), i);
      gridSubs.push({ class: className(l), frame: rect(msgRect(l, sel('frame'))) });
    }
    const container = ivar(g, '_noResultsContainerLayer');
    const noResults = msgP(g, sel('noResultsLayer'));
    write({
      type: 'tree',
      why,
      grid: {
        bounds: rect(msgRect(g, sel('bounds'))),
        adjustedTopMargin: msgD(g, sel('adjustedTopMargin')),
        adjustedLeftMargin: msgD(g, sel('adjustedLeftMargin')),
        adjustedRightMargin: msgD(g, sel('adjustedRightMargin')),
        adjustedBottomMargin: msgD(g, sel('adjustedBottomMargin')),
        scaleFactor: ivarAddress(g, 'scaleFactor').readFloat(),
        fieldIndex: Number(msgUP(gridSublayers, sel('indexOfObjectIdenticalTo:'), f)),
        sublayerCount: gn,
        sublayers: gridSubs,
        scrollLayerFrame: rect(msgRect(msgP(g, sel('scrollLayer')), sel('frame'))),
      },
      noResults: {
        container: Object.assign(layerInfo(container, 'container'),
          { allowsGroupBlending: !!msgB(container, sel('allowsGroupBlending')) }),
        layer: Object.assign(layerInfo(noResults, 'noResults'), textInfo(noResults)),
      },
      ivars: {
        type: ivarAddress(f, '_type').readS64().toNumber(),
        size: [ivarAddress(f, '_size').readDouble(), ivarAddress(f, '_size').add(8).readDouble()],
        margin: ivarAddress(f, '_margin').readDouble(),
        scaleFactor: ivarAddress(f, '_scaleFactor').readFloat(),
        pid: ivarAddress(f, '_pid').readS32(),
        flags,
        placeholderAttributes: description(attributes),
        stringValue: str(ivar(f, '_stringValue')),
        eventDelegateIsGrid: msgP(f, sel('eventDelegate')).equals(g),
      },
      field: layerInfo(f, 'field'),
      sublayers: subs,
      placeholder: ph,
    });
  } catch (e) {
    write({ type: 'note', what: 'tree failed', why, error: String(e), stack: e.stack });
  }
}

const atLoad = new NativeCallback(function () {
  tree('load');
}, 'void', ['pointer']);
dispatch_async_f(mainQueue, ptr(0), atLoad);
