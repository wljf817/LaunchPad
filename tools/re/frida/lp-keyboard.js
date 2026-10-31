// Trace keyboard handling and the selection in the macOS 15 Launchpad in Dock (reference VM): the
// key methods of Springboard, ECSBSpringboard, ECSBLayer and the pagers, navigation through the
// pagers and pages, the selected item and the selection layer of its item layer, and the search
// field's text input calls that the key path makes.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge (REF-ENV-003), so
// Objective-C is driven through the runtime's C functions and objc_msgSend, as in lp-paging.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-keyboard.js" }, and post
// the keys with lp-input.js in the same session. Fetch the file with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-keyboard-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread):
//   header    frida, pid, utc
//   call      ph "enter" | "leave", fn (Class.selector), self (class), args, ret. Key methods give
//             the event ({keyData, keyCode, flags, commandKeyDown}); navigate methods the
//             navigation type and the event (or null); methods that take an item give its title.
//             ret is the return value (BOOL methods) or, for the selection setters, the state
//             after the call
//   selection the item layer's selection after -[ECSBItemLayer setSelected:]: selected, and the
//             selection layer's class, frame, cornerRadius, cornerCurve, masksToBounds, opacity,
//             backgroundColor (components and color space name), compositingFilter (class and
//             description), superlayer (class, whether it is _jitterLayer, index among its
//             sublayers, geometryFlipped), plus the image and label layers' frames
//   snapshot  why, and the state: visible, currentPageIndex, selectedItem (title, index on its
//             page, page index), the search field (hasFocus, textFieldActive, isMarked,
//             stringValue). Taken when the script loads, when -[Springboard setVisible:reason:]
//             returns and 0.1 s after that, and after every key down handled by Springboard
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
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgUP = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgU16 = new NativeFunction(msgSendPtr, 'uint16', ['pointer', 'pointer']);
const msgU64 = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const CGColorGetNumberOfComponents = gf('CGColorGetNumberOfComponents', 'ulong', ['pointer']);
const CGColorGetComponents = gf('CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = gf('CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = gf('CGColorSpaceCopyName', 'pointer', ['pointer']);
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
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
function ivar(obj, className_, name) {
  const off = ivar_getOffset(class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name))).toNumber();
  return obj.add(off).readPointer();
}
function frame(layer) {
  return layer.isNull() ? null : msgRect(layer, sel('frame'));
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
function description(obj) {
  return obj.isNull() ? null : str(msgP(obj, sel('description')));
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-keyboard-' + utc + '.jsonl';
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

function event(e) {
  if (e.isNull()) return null;
  const cg = e.add(8).readPointer();
  return {
    keyData: msgU16(e, sel('keyData')),
    keyCode: cg.isNull() ? null : CGEventGetIntegerValueField(cg, 9).toNumber(),
    flags: '0x' + msgU64(e, sel('flags')).toString(16),
    commandKeyDown: !!msgB(e, sel('commandKeyDown')),
  };
}
function title(item) {
  if (item.isNull()) return null;
  try {
    return str(msgP(item, sel('title')));
  } catch (e) {
    return className(item);
  }
}

function search() {
  const sb = springboardGlobal.readPointer();
  const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
  const grid = msgP(msgP(ecsb, sel('pager')), sel('layer'));
  const field = ivar(grid, 'ECSBLayer', '_searchTextInputLayer');
  if (field.isNull()) return null;
  return {
    hasFocus: !!msgB(field, sel('hasFocus')),
    textFieldActive: !!msgB(field, sel('textFieldActive')),
    isMarked: !!msgB(field, sel('isMarked')),
    stringValue: str(msgP(field, sel('stringValue'))),
  };
}

function state() {
  const sb = springboardGlobal.readPointer();
  const ecsb = sb.add(0x28).readPointer();
  const pager = msgP(ecsb, sel('pager'));
  const selected = msgP(pager, sel('selectedItem'));
  let where = null;
  if (!selected.isNull()) {
    const pages = msgP(pager, sel('pages'));
    const n = Number(msgU(pages, sel('count')));
    for (let i = 0; i < n; i++) {
      const items = msgP(msgP(msgPU(pages, sel('objectAtIndex:'), i), sel('item')), sel('items'));
      const k = Number(msgUP(items, sel('indexOfObjectIdenticalTo:'), selected));
      if (k < Number(msgU(items, sel('count')))) where = { page: i, index: k };
    }
  }
  return {
    visible: !!msgB(sb, sel('visible')),
    currentPageIndex: Number(msgU(pager, sel('currentPageIndex'))),
    selectedItem: selected.isNull() ? null : { title: title(selected), where },
    search: search(),
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

function snapshotLater(why, seconds) {
  const id = ++pendingId;
  pending.set(id, why);
  dispatch_after_f(dispatch_time(0, Math.round(seconds * 1e9)), mainQueue, ptr(id), fire);
}

function selection(itemLayer) {
  const layer = ivar(itemLayer, 'ECSBItemLayer', '_selectionLayer');
  const image = ivar(itemLayer, 'ECSBItemLayer', '_imageLayer');
  const label = ivar(itemLayer, 'ECSBItemLayer', '_labelLayer');
  const jitter = ivar(itemLayer, 'ECSBItemLayer', '_jitterLayer');
  const out = { selected: !!msgB(itemLayer, sel('selected')), imageFrame: frame(image), labelFrame: frame(label), layer: null };
  if (layer.isNull()) return out;
  const superlayer = msgP(layer, sel('superlayer'));
  const filter = msgP(layer, sel('compositingFilter'));
  out.layer = {
    class: className(layer),
    frame: frame(layer),
    cornerRadius: msgD(layer, sel('cornerRadius')),
    cornerCurve: str(msgP(layer, sel('cornerCurve'))),
    masksToBounds: !!msgB(layer, sel('masksToBounds')),
    opacity: msgF(layer, sel('opacity')),
    backgroundColor: color(msgP(layer, sel('backgroundColor'))),
    compositingFilter: filter.isNull() ? null : { class: className(filter), description: description(filter) },
    superlayer: superlayer.isNull() ? null : {
      class: className(superlayer),
      isJitterLayer: superlayer.equals(jitter),
      index: Number(msgUP(msgP(superlayer, sel('sublayers')), sel('indexOfObjectIdenticalTo:'), layer)),
      geometryFlipped: !!msgB(superlayer, sel('isGeometryFlipped')),
    },
  };
  return out;
}

// --- Objective-C methods ---------------------------------------------------

const disableActions = () => !!msgB(cls('CATransaction'), sel('disableActions'));
const bool = r => r.toUInt32() & 1;
const key = a => [event(a[2])];
const nav = a => [a[2].toInt32(), event(a[3])];

const HOOKS = [
  // [class, selector, args, ret, after]
  ['Springboard', 'keyDown:', key, bool, () => snapshot('keyDown returned')],
  ['Springboard', 'keyUp:', key, bool],
  ['Springboard', 'navigate:', a => [a[2].toInt32()], null],
  ['Springboard', 'performAction', null, null],
  ['Springboard', 'performCancel', null, null],
  ['Springboard', 'performActionForItem:withEvent:sender:', a => [className(a[2]), event(a[3]), className(a[4])], null],
  ['Springboard', 'setVisible:reason:', a => [a[2].toUInt32() & 1, str(a[3])], null,
    () => { snapshot('setVisible returned'); snapshotLater('setVisible + 0.1 s', 0.1); }],
  ['ECSBSpringboard', 'keyDown:', key, bool],
  ['ECSBSpringboard', 'keyUp:', key, bool],
  ['ECSBSpringboard', 'navigate:withEvent:', nav, bool],
  ['ECSBSpringboard', 'handleTextInputKeyEvent:', key, bool],
  ['ECSBLayer', 'keyDown:', key, bool],
  ['ECSBLayer', 'keyUp:', key, bool],
  ['ECSBPager', 'keyDown:', key, bool],
  ['ECSBPager', 'navigate:withEvent:', nav, bool],
  ['ECSBPager', 'performAction:', key, bool],
  ['ECSBPager', 'setSelectedItem:', a => [title(a[2])], null],
  ['ECSBPager', 'willChangeToPageIndex:', a => [a[2].toUInt32()], null],
  ['ECSBGroupPager', 'keyDown:', key, bool],
  ['ECSBGroupPager', 'navigate:withEvent:', nav, bool],
  ['ECSBPage', 'navigate:withEvent:', nav, bool],
  ['ECPager', 'setCurrentPageIndex:', a => [a[2].toUInt32()], null],
  ['ECTextInputLayer', 'handleKeyEvent:', key, bool],
  ['ECTextInputLayer', 'setHasFocus:', a => [a[2].toUInt32() & 1], null],
  ['ECTextInputLayer', 'setTextFieldActive:', a => [a[2].toUInt32() & 1], null],
  ['ECSBItemLayer', 'setSelected:', a => [a[2].toUInt32() & 1, { disableActions: disableActions() }], null,
    self => write({ type: 'selection', state: selection(self) })],
  ['ECSBItemLayer', 'layout', null, null],
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
  // -[ECSBItemLayer layout] runs for every item layer; only the ones with a selection are traced.
  const onlySelected = fn === 'ECSBItemLayer.layout';
  Interceptor.attach(impl, {
    onEnter(a) {
      this.self = a[0];
      this.skip = onlySelected && ivar(a[0], 'ECSBItemLayer', '_selectionLayer').isNull();
      if (this.skip) return;
      try {
        write({ type: 'call', ph: 'enter', fn, self: className(a[0]), args: args === null ? [] : args(a) });
      } catch (e) {
        write({ type: 'note', text: fn + ' enter failed: ' + e });
      }
    },
    onLeave(r) {
      if (this.skip) return;
      try {
        if (ret !== null && ret !== undefined) write({ type: 'call', ph: 'leave', fn, ret: ret(r) });
        if (onlySelected) write({ type: 'selection', state: selection(this.self) });
        if (after !== undefined && after !== null) after(this.self);
      } catch (e) {
        write({ type: 'note', text: fn + ' leave failed: ' + e });
      }
    },
  });
}

const atLoad = new NativeCallback(() => snapshot('load'), 'void', ['pointer']);
dispatch_async_f(mainQueue, NULL, atLoad);
