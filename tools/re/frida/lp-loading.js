// Record the startup of the macOS 15 Launchpad in Dock (reference VM) from the
// moment Dock loads: when the controller is activated and started, when the
// first scan completes, and the "Loading" layers shown until then.
// Frida 17 core API only (no Objective-C bridge), as lp-trace.js.
//
// Startup happens before a client can attach, so this script is meant to be
// loaded by frida-gadget itself: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-loading.js"}}
// in frida-gadget.config next to the gadget, restart Dock with the gadget
// (open ~/frida-gadget/restart-dock-with-gadget.command in the VM; Dock then
// does not listen for clients), and restore the listening config afterwards.
// Other processes started while DYLD_INSERT_LIBRARIES is set load the script
// too and leave empty files.
// It can also be loaded through REA into a running Dock; then only later
// events are seen.
//
// File: $HOME/frida-gadget/lp-loading-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header  frida, pid, utc, dockBase
//   call    ph "enter" | "leave", fn (Class.selector or the block's Dock file
//           address), args (BOOL and integer arguments), main (on the main
//           thread), and for Springboard methods deferLayout and startTime
//           (the controller's _deferLayout and _startTime)
//   loading at the leave of -_displayLoadingLayer and -layout, at the enter of
//           -_removeLoadingLayer, and at the enter and leave of the block that
//           completes the removal: the container and text layers (class,
//           superlayer class and index, frame, bounds, hidden, opacity,
//           allowsGroupBlending, contentsScale, compositingFilter), the text
//           layer's string, font (description), fontSize, foregroundColor,
//           alignmentMode, wrapped, truncationMode, preferredFrameSize and
//           text shadow ivars, the main grid layer's hidden, and the current
//           transaction's animationDuration and disableActions
//   anim    at the leave of -_removeLoadingLayer: the animations on the text
//           layer (key, class, keyPath, beginTime, duration, timing function
//           control points, fromValue and toValue descriptions)
//
// Nothing is written to Dock's objects.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgVPP = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer']);
const msgVUP = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'uint64', 'pointer']);
const msgSize = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);

const cf = Process.getModuleByName('CoreFoundation');
const CFCopyDescription = nf(cf, 'CFCopyDescription', 'pointer', ['pointer']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGColorGetNumberOfComponents = nf(cg, 'CGColorGetNumberOfComponents', 'size_t', ['pointer']);
const CGColorGetComponents = nf(cg, 'CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = nf(cg, 'CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = nf(cg, 'CGColorSpaceCopyName', 'pointer', ['pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const NSGetSizeAndAlignment = nf(Process.getModuleByName('Foundation'), 'NSGetSizeAndAlignment', 'pointer', ['pointer', 'pointer', 'pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);
const pthread_main_np = new NativeFunction(Module.getGlobalExportByName('pthread_main_np'), 'int', []);

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
function str(ns) {
  if (ns.isNull()) return null;
  return msgP(ns, sel('UTF8String')).readUtf8String();
}
function cfDescription(p) {
  if (p.isNull()) return null;
  const d = CFCopyDescription(p);
  const s = str(d);
  CFRelease(d);
  return s;
}
function className(p) {
  return p.isNull() ? null : object_getClassName(p).readUtf8String();
}
const NSString = cls('NSString');
function nsString(text) {
  return msgPP(NSString, sel('stringWithUTF8String:'), Memory.allocUtf8String(text));
}
function kvc(obj, key) {
  return msgPP(obj, sel('valueForKey:'), nsString(key));
}
// NSValue or NSNumber from KVC: numbers as numbers, structs of doubles as arrays.
function kvcValue(obj, key) {
  const v = kvc(obj, key);
  if (v.isNull()) return null;
  const type = msgP(v, sel('objCType')).readUtf8String();
  if (type.length === 1) return msgD(v, sel('doubleValue'));
  const size = Memory.alloc(8);
  NSGetSizeAndAlignment(Memory.allocUtf8String(type), size, NULL);
  const n = size.readU64().toNumber();
  const buf = Memory.alloc(n);
  msgVPP(v, sel('getValue:size:'), buf, ptr(n));
  const doubles = [];
  for (let i = 0; i + 8 <= n; i += 8) doubles.push(buf.add(i).readDouble());
  return doubles;
}
function color(c) {
  if (c.isNull()) return null;
  const n = CGColorGetNumberOfComponents(c).toNumber();
  const comps = CGColorGetComponents(c);
  const values = [];
  for (let i = 0; i < n; i++) values.push(comps.add(8 * i).readDouble());
  const space = CGColorSpaceCopyName(CGColorGetColorSpace(c));
  const name = space.isNull() ? null : str(space);
  if (!space.isNull()) CFRelease(space);
  return { space: name, components: values };
}
function ivarPtr(obj, clsName, name) {
  const iv = class_getInstanceVariable(cls(clsName), Memory.allocUtf8String(name));
  return obj.add(ivar_getOffset(iv));
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');
const path = `${home}/frida-gadget/lp-loading-${utc}.jsonl`;
const file = new File(path, 'wx');
function writeLine(rec) {
  rec.t = CACurrentMediaTime();
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}

const dock = Process.getModuleByName('Dock');
writeLine({ type: 'header', frida: Frida.version, pid: Process.id, utc, dockBase: dock.base.toString() });

const C = {
  Springboard: cls('Springboard'),
  LPSpringboard: cls('LPSpringboard'),
  ECSBSpringboard: cls('ECSBSpringboard'),
  ECPager: cls('ECPager'),
  ECSBLayer: cls('ECSBLayer'),
  CATransaction: cls('CATransaction'),
};

function layerInfo(l) {
  if (l.isNull()) return null;
  const sup = msgP(l, sel('superlayer'));
  let index = null;
  if (!sup.isNull()) {
    const subs = msgP(sup, sel('sublayers'));
    index = msgPP(subs, sel('indexOfObjectIdenticalTo:'), l).toString();
  }
  return {
    address: l.toString(), class: className(l), superlayer: className(sup), index,
    frame: kvcValue(l, 'frame'), bounds: kvcValue(l, 'bounds'),
    hidden: !!msgB(l, sel('isHidden')), opacity: msgF(l, sel('opacity')),
    allowsGroupBlending: !!msgB(l, sel('allowsGroupBlending')),
    contentsScale: msgD(l, sel('contentsScale')),
    compositingFilter: cfDescription(msgP(l, sel('compositingFilter'))),
  };
}

function loadingState(sb, where) {
  const container = ivarPtr(sb, 'Springboard', '_loadingContainerLayer').readPointer();
  const text = ivarPtr(sb, 'Springboard', '_loadingLayer').readPointer();
  const grid = msgP(ivarPtr(sb, 'Springboard', '_springboard').readPointer(), sel('layer'));
  const rec = {
    type: 'loading', where, container: layerInfo(container), text: layerInfo(text),
    gridHidden: grid.isNull() ? null : !!msgB(grid, sel('isHidden')),
    transaction: { duration: msgD(C.CATransaction, sel('animationDuration')), disableActions: !!msgB(C.CATransaction, sel('disableActions')) },
  };
  if (!text.isNull()) {
    const size = msgSize(text, sel('preferredFrameSize'));
    Object.assign(rec.text, {
      string: str(msgP(text, sel('string'))),
      font: cfDescription(msgP(text, sel('font'))),
      fontSize: msgD(text, sel('fontSize')),
      foregroundColor: color(msgP(text, sel('foregroundColor'))),
      alignmentMode: str(msgP(text, sel('alignmentMode'))),
      wrapped: !!msgB(text, sel('isWrapped')),
      truncationMode: str(msgP(text, sel('truncationMode'))),
      preferredFrameSize: size,
      textShadowColor: color(ivarPtr(text, 'ECShadowTextLayer', '_textShadowColor').readPointer()),
      textShadowOffset: [ivarPtr(text, 'ECShadowTextLayer', '_textShadowOffset').readDouble(),
        ivarPtr(text, 'ECShadowTextLayer', '_textShadowOffset').add(8).readDouble()],
      textShadowBlur: ivarPtr(text, 'ECShadowTextLayer', '_textShadowBlur').readDouble(),
      textShadowHidden: ivarPtr(text, 'ECShadowTextLayer', '_textShadowHidden').readU8(),
      cachedHeight: ivarPtr(text, 'ECShadowTextLayer', '_cachedHeight').readDouble(),
    });
  }
  writeLine(rec);
}

function animations(sb, where) {
  const text = ivarPtr(sb, 'Springboard', '_loadingLayer').readPointer();
  const list = [];
  if (!text.isNull()) {
    const keys = msgP(text, sel('animationKeys'));
    const n = keys.isNull() ? 0 : msgU(keys, sel('count'));
    for (let i = 0; i < n; i++) {
      const key = msgPU(keys, sel('objectAtIndex:'), i);
      const a = msgPP(text, sel('animationForKey:'), key);
      const tf = msgP(a, sel('timingFunction'));
      let points = null;
      if (!tf.isNull()) {
        points = [];
        const pt = Memory.alloc(8);
        for (let k = 0; k < 4; k++) {
          msgVUP(tf, sel('getControlPointAtIndex:values:'), k, pt);
          points.push([pt.readFloat(), pt.add(4).readFloat()]);
        }
      }
      const responds = name => !!msgBP(a, sel('respondsToSelector:'), sel(name));
      list.push({
        key: str(key), class: className(a),
        keyPath: responds('keyPath') ? str(msgP(a, sel('keyPath'))) : null,
        beginTime: msgD(a, sel('beginTime')), duration: msgD(a, sel('duration')),
        timing: points,
        fromValue: responds('fromValue') ? cfDescription(msgP(a, sel('fromValue'))) : null,
        toValue: responds('toValue') ? cfDescription(msgP(a, sel('toValue'))) : null,
      });
    }
  }
  writeLine({ type: 'anim', where, animations: list });
}

function springboardState(sb) {
  return {
    deferLayout: ivarPtr(sb, 'Springboard', '_deferLayout').readU8(),
    startTime: ivarPtr(sb, 'Springboard', '_startTime').readDouble(),
  };
}

function guarded(fn) {
  return function (...a) {
    try {
      return fn.apply(this, a);
    } catch (e) {
      writeLine({ type: 'error', message: String(e), stack: e.stack });
    }
  };
}

function hookMethod(c, name, opts = {}) {
  const m = class_getInstanceMethod(c, sel(name));
  if (m.isNull()) {
    writeLine({ type: 'note', message: 'method not found: ' + name });
    return;
  }
  const label = className(c) + '.' + name;
  Interceptor.attach(method_getImplementation(m).strip(), {
    onEnter: guarded(function (args) {
      this.self = args[0];
      const rec = { type: 'call', ph: 'enter', fn: label, main: pthread_main_np() === 1 };
      if (opts.args) rec.args = opts.args(args);
      if (opts.springboard) Object.assign(rec, springboardState(args[0]));
      writeLine(rec);
      if (opts.loadingEnter) loadingState(args[0], label + ' enter');
    }),
    onLeave: guarded(function () {
      const rec = { type: 'call', ph: 'leave', fn: label };
      if (opts.springboard) Object.assign(rec, springboardState(this.self));
      writeLine(rec);
      if (opts.loadingLeave) loadingState(this.self, label + ' leave');
      if (opts.animLeave) animations(this.self, label + ' leave');
    }),
  });
}

let springboard = null;
function hookBlock(fileAddress, name, withLoading) {
  const p = dock.base.add(ptr(fileAddress).sub(ptr('0x100000000')));
  Interceptor.attach(p, {
    onEnter: guarded(function () {
      writeLine({ type: 'call', ph: 'enter', fn: name, main: pthread_main_np() === 1 });
      if (withLoading && springboard !== null) loadingState(springboard, name + ' enter');
    }),
    onLeave: guarded(function () {
      writeLine({ type: 'call', ph: 'leave', fn: name });
      if (withLoading && springboard !== null) loadingState(springboard, name + ' leave');
    }),
  });
}

const bool = i => args => ({ value: args[i].toUInt32() & 0xff });
const sb = { springboard: true };
Interceptor.attach(method_getImplementation(class_getInstanceMethod(C.Springboard, sel('activate'))).strip(), {
  onEnter: guarded(function (args) {
    springboard = args[0];
  }),
});
hookMethod(C.Springboard, 'init');
hookMethod(C.Springboard, 'activate', sb);
hookMethod(C.LPSpringboard, 'activate', sb);
hookMethod(C.Springboard, 'start', sb);
hookMethod(C.Springboard, '_setupApplicationSources:', Object.assign({ args: bool(2) }, sb));
hookMethod(C.Springboard, '_displayLoadingLayer', Object.assign({ loadingLeave: true }, sb));
hookMethod(C.Springboard, '_removeLoadingLayer', Object.assign({ loadingEnter: true, animLeave: true }, sb));
hookMethod(C.Springboard, '_handleInitialSourceScanCompletion', sb);
hookMethod(C.Springboard, 'observeValueForKeyPath:ofObject:change:context:', sb);
hookMethod(C.Springboard, 'layout', Object.assign({ loadingLeave: true }, sb));
hookMethod(C.Springboard, 'setVisible:reason:', Object.assign({ args: bool(2) }, sb));
hookMethod(C.LPSpringboard, 'initialSetupComplete', sb);
hookMethod(C.ECSBSpringboard, 'invalidate');
hookMethod(C.ECSBSpringboard, 'layout');
hookMethod(C.ECSBSpringboard, 'makePageForPager:atIndex:', { args: args => ({ index: args[3].toString() }) });
hookMethod(C.ECPager, 'invalidate');
hookMethod(C.ECSBLayer, 'layout');
hookBlock('0x100014010', 'block _setupApplicationSources: roots', false);
hookBlock('0x100025648', 'block _removeLoadingLayer completion', true);
