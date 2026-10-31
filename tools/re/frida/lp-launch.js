// Trace the macOS 15 Launchpad in Dock (reference VM) from a press on an item
// to the app being opened: the item's event handler, the darkening, the grid
// action, the launch, the zoom of the icon, the close, the refresh of the
// item and the LaunchServices call that opens the app.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge
// (REF-ENV-003), so Objective-C is driven through the runtime's C functions and
// objc_msgSend, as in lp-events.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-launch.js" }.
// Post the input with lp-input.js in the same session. Fetch the file with
// tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-launch-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written. Every line is
// also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main
// (whether the call runs on the main thread):
//   header  frida, pid, utc, mainDisplay (CGMainDisplayID())
//   call    ph "enter" | "leave", fn (Class.selector or function), args, ret;
//           -setDarkened: also records whether implicit actions are disabled
//           when it is entered, and when it returns the image layer's and the
//           status layer's filters (type, inputColor components) and the
//           progress layers' opacity; LSOpenFromURLSpec records the spec
//           (appURL, itemURLs, launchFlags, the pass-through record's type,
//           asyncRefCon); the record's entry shows in the NSAppleEventDescriptor
//           calls just before it; the refresh of notFound records the begin
//           times of the zoomed icon's and the overlay container's animations
//   note    hooks not installed
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
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const CGMainDisplayID = gf('CGMainDisplayID', 'uint32', []);
const CGColorGetNumberOfComponents = gf('CGColorGetNumberOfComponents', 'ulong', ['pointer']);
const CGColorGetComponents = gf('CGColorGetComponents', 'pointer', ['pointer']);
const CFArrayGetCount = gf('CFArrayGetCount', 'long', ['pointer']);
const CFArrayGetValueAtIndex = gf('CFArrayGetValueAtIndex', 'pointer', ['pointer', 'long']);
const CFURLGetString = gf('CFURLGetString', 'pointer', ['pointer']);
const pthread_main_np = gf('pthread_main_np', 'int', []);
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
function nsstr(s) {
  return msgPP(cls('NSString'), sel('stringWithUTF8String:'), Memory.allocUtf8String(s));
}
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}
function ivar(obj, className_, name) {
  const off = ivar_getOffset(class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name))).toNumber();
  return obj.add(off).readPointer();
}
function fourCC(n) {
  return String.fromCharCode((n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
}
function rect(ctx, first) {
  return [ctx['d' + first], ctx['d' + (first + 1)], ctx['d' + (first + 2)], ctx['d' + (first + 3)]];
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-launch-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

write({ type: 'header', frida: Frida.version, pid: Process.id, utc, mainDisplay: CGMainDisplayID() });

// --- values ---------------------------------------------------------------

function ecEvent(e) {
  if (e.isNull()) return null;
  const hit = msgP(e, sel('hitLayer'));
  return { type: Number(msgU(e, sel('type'))), hitLayer: className(hit), hitLayerAddress: hit.toString() };
}

function filters(layer) {
  if (layer.isNull()) return null;
  const array = msgP(layer, sel('filters'));
  if (array.isNull()) return [];
  const out = [];
  const n = Number(msgU(array, sel('count')));
  for (let i = 0; i < n; i++) {
    const f = msgPU(array, sel('objectAtIndex:'), i);
    const entry = { class: className(f), type: str(msgP(f, sel('type'))) };
    const color = msgPP(f, sel('valueForKey:'), nsstr('inputColor'));
    if (!color.isNull()) {
      const count = Number(CGColorGetNumberOfComponents(color));
      const components = CGColorGetComponents(color);
      entry.inputColor = [];
      for (let k = 0; k < count; k++) entry.inputColor.push(components.add(8 * k).readDouble());
    }
    out.push(entry);
  }
  return out;
}

function opacity(layer) {
  return layer.isNull() ? null : msgF(layer, sel('opacity'));
}

function darkenedState(itemLayer) {
  return {
    imageLayer: filters(msgP(itemLayer, sel('imageLayer'))),
    statusLayer: filters(ivar(itemLayer, 'ECSBItemLayer', '_statusLayer')),
    progressLayerOpacity: opacity(ivar(itemLayer, 'ECSBItemLayer', '_progressLayer')),
    progressLabelLayerOpacity: opacity(ivar(itemLayer, 'ECSBItemLayer', '_progressLabelLayer')),
  };
}

function itemTitle(item) {
  if (item.isNull()) return null;
  return { class: className(item), title: str(msgP(item, sel('title'))) };
}

// The begin times of the animations the launch committed: those on the last sublayer of the
// window's root layer (the zoomed icon) and the overlay container's opacity. Read when the item's
// notFound is refreshed, which runs on the main queue after the event's transaction was committed.
function beginTimes(springboard) {
  const anims = (layer, keys) => {
    const out = {};
    for (const k of keys) {
      const anim = msgPP(layer, sel('animationForKey:'), nsstr(k));
      out[k] = anim.isNull() ? null : msgD(anim, sel('beginTime'));
    }
    return out;
  };
  const root = msgP(msgP(springboard, sel('containerWindow')), sel('layer'));
  const zoomed = msgP(msgP(root, sel('sublayers')), sel('lastObject'));
  return {
    zoomed: { address: zoomed.toString(), class: className(zoomed), ...anims(zoomed, ['transform', 'opacity']) },
    overlay: anims(ivar(springboard, 'Springboard', '_layer'), ['opacity']),
  };
}

function urlString(url) {
  return url.isNull() ? null : str(msgP(url, sel('absoluteString')));
}

// --- Objective-C methods ---------------------------------------------------

const disableActions = () => !!msgB(cls('CATransaction'), sel('disableActions'));

// [class, selector, args on enter (args, context), ret on leave (retval, self), class method]
const HOOKS = [
  ['ECSBEventHandler', 'leftMouseDown:inLayer:ofPage:', a => [ecEvent(a[2]), className(a[3]), a[3].toString()], r => r.toUInt32() & 1],
  ['ECSBEventHandler', 'leftMouseDragged:inLayer:ofPage:', a => [ecEvent(a[2]), className(a[3])], r => r.toUInt32() & 1],
  ['ECSBEventHandler', 'leftMouseUp:inLayer:ofPage:', a => [ecEvent(a[2]), className(a[3])], r => r.toUInt32() & 1],
  ['ECSBItemLayer', 'setDarkened:', a => [a[2].toUInt32() & 1, a[0].toString(), { disableActions: disableActions() }],
    (r, self) => darkenedState(self)],
  ['ECSBItemLayer', 'setDisableLayout:', a => [a[2].toUInt32() & 1, a[0].toString()], null],
  ['ECSBPager', 'setEditing:', a => [a[2].toUInt32() & 1], null],
  ['ECSBPager', 'removeEmptyPages', null, null],
  ['ECModalEventController', 'addCompletionBlockOnMouseUp:', null, null],
  ['ECModalEventControllerHandler', 'performMouseUpBlocksWithEvent:', null, null],
  ['ECSBDragCapture', 'initWithItemLayer:fromPage:usingEventHandler:', null, null],
  ['ECSBSpringboard', 'performGridActionAtIndex:withEvent:sender:', a => [a[2].toUInt32(), className(a[4])], null],
  ['Springboard', 'performActionForItem:withEvent:sender:', a => [itemTitle(a[2]), className(a[4])], null],
  ['LPSpringboard', '_launchRunnable:withImageRect:withEvent:', (a, c) => [itemTitle(a[2]), rect(c, 0)], null],
  ['Springboard', 'performOpenAnimationForRunnable:withImage:atFrame:toFrame:',
    (a, c) => [itemTitle(a[2]), className(a[3]), rect(c, 0), rect(c, 4), { disableActions: disableActions() }], null],
  ['Springboard', 'setVisible:reason:', a => [a[2].toUInt32() & 1, str(a[3])], null],
  ['Springboard', '_refreshItem:property:',
    a => [itemTitle(a[2]), str(a[3]), str(a[3]) === 'notFound' ? beginTimes(a[0]) : null], null],
  ['LPRunnable', 'resolveURLFromBookMark:url:', a => [itemTitle(a[0]), a[2].toUInt32() & 1], null],
  ['LPSpringboard', 'handleRunnableOpen:atURL:fromFrame:toFrame:', (a, c) => [itemTitle(a[2]), urlString(a[3]), rect(c, 0)],
    r => r.toUInt32() & 1],
  ['DisplayDescriptor', 'identifier', null, r => r.toUInt32()],
  // The open function's pass-through record: the display identifier and the keyword it goes under.
  ['NSAppleEventDescriptor', 'descriptorWithInt32:', a => [a[2].toInt32()], null, true],
  ['NSAppleEventDescriptor', 'setDescriptor:forKeyword:',
    a => [fourCC(a[3].toUInt32()), fourCC(Number(msgU(a[2], sel('descriptorType')))), Number(msgU(a[2], sel('int32Value'))) | 0], null],
];

for (const [c, s, args, ret, isClass] of HOOKS) {
  const k = cls(c);
  const m = k.isNull() ? ptr(0) : (isClass ? class_getClassMethod : class_getInstanceMethod)(k, sel(s));
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
      write({ type: 'call', ph: 'enter', fn, args: args === null ? [] : args(a, this.context) });
    },
    onLeave(r) {
      if (ret !== null) write({ type: 'call', ph: 'leave', fn, ret: ret(r, this.self) });
    },
  });
}

// --- LaunchServices --------------------------------------------------------

Interceptor.attach(Module.getGlobalExportByName('LSOpenFromURLSpec'), {
  onEnter(a) {
    const spec = a[0];
    const items = spec.add(8).readPointer();
    const urls = [];
    if (!items.isNull()) {
      const n = CFArrayGetCount(items);
      for (let i = 0; i < n; i++) urls.push(str(CFURLGetString(CFArrayGetValueAtIndex(items, i))));
    }
    const params = spec.add(0x10).readPointer();
    // The record's contents are recorded where Dock builds it (the NSAppleEventDescriptor hooks).
    const paramsType = params.isNull() ? null : fourCC(params.readU32());
    write({
      type: 'call', ph: 'enter', fn: 'LSOpenFromURLSpec', args: [{
        appURL: spec.readPointer().isNull() ? null : str(CFURLGetString(spec.readPointer())),
        itemURLs: urls,
        passThruParams: params.isNull() ? null : { descriptorType: paramsType },
        launchFlags: '0x' + spec.add(0x18).readU32().toString(16),
        // LSLaunchURLSpec is packed to 2 bytes, so asyncRefCon follows launchFlags directly.
        asyncRefCon: spec.add(0x1c).readPointer().toString(),
        outLaunchedURL: a[1].toString(),
      }],
    });
  },
  onLeave(r) {
    write({ type: 'call', ph: 'leave', fn: 'LSOpenFromURLSpec', ret: r.toInt32() });
  },
});
