// Record the keyboard state of this project's background process (LaunchPadAgent, macOS 26
// comparison VM) in the shape of lp-keyboard.js's lines, so the two can be compared: the selected
// item, the current page, and the selection layer of every item layer that has one. Frida 17 core
// API only (no Objective-C bridge), as lp-keyboard.js.
//
// Load it through REA into the agent started with frida-gadget listening (as lp-paging-launchpad.js).
// It takes a snapshot on load, after every -[Springboard keyDown:] the dispatcher sends, and every
// time a line is written to $HOME/frida-gadget/lp-keyboard-launchpad-cmd.txt (read every 200 ms,
// then emptied; the line is the snapshot's why). Snapshots are taken on the main queue. The
// controller is the Swift global launchpadSpringboard; the rest goes through the same Objective-C
// names as in Dock. Grid methods called from Swift directly (not through objc_msgSend) cannot be
// traced at their Objective-C entry points, so only the entry points that are sent messages are
// hooked: the dispatcher's -keyDown: and -keyUp:, and the pager's -performActionForItem:withEvent:sender:.
//
// File: $HOME/frida-gadget/lp-keyboard-launchpad-<UTC load time>.jsonl in the target process,
// created exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether it runs on
// the main thread):
//   header    frida, pid, utc, kCAFilterPlusD (QuartzCore's exported constant: its class and value)
//   call      ph "enter" | "leave", fn (Class.selector), self (class), args, ret, as in
//             lp-keyboard.js: key methods give the event ({keyData, keyCode, flags, commandKeyDown})
//   snapshot  why, and the state: visible, currentPageIndex, pages (count), selectedItem (class,
//             title of its client item, index on its page and page index, as lp-keyboard.js's
//             "where"), selections (every item layer with a selection layer or the selected flag:
//             its page and index, and lp-keyboard.js's selection state, plus the selection layer's
//             animation keys)
//   note      hooks not installed, failures
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
const msgUP = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgU16 = new NativeFunction(msgSendPtr, 'uint16', ['pointer', 'pointer']);
const msgU64 = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, ['double', 'double', 'double', 'double'], ['pointer', 'pointer']);

const quartzCore = Process.getModuleByName('QuartzCore');
const CACurrentMediaTime = nf(quartzCore, 'CACurrentMediaTime', 'double', []);
const CGColorGetNumberOfComponents = gf('CGColorGetNumberOfComponents', 'ulong', ['pointer']);
const CGColorGetComponents = gf('CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = gf('CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = gf('CGColorSpaceCopyName', 'pointer', ['pointer']);
const CGEventGetIntegerValueField = gf('CGEventGetIntegerValueField', 'int64', ['pointer', 'uint32']);
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
// An ivar looked up from the object's own class up (Swift stored properties are ivars by their names).
function ivar(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className(obj) + '.' + name);
  return obj.add(ivar_getOffset(iv).toNumber()).readPointer();
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
function strings(array) {
  if (array.isNull()) return null;
  const out = [];
  const n = Number(msgU(array, sel('count')));
  for (let i = 0; i < n; i++) out.push(str(msgPU(array, sel('objectAtIndex:'), i)));
  return out;
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-keyboard-launchpad-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

const plusD = quartzCore.findExportByName('kCAFilterPlusD');
write({
  type: 'header', frida: Frida.version, pid: Process.id, utc,
  kCAFilterPlusD: plusD === null ? null : { class: className(plusD.readPointer()), value: str(plusD.readPointer()) },
});

// --- state ----------------------------------------------------------------

const globalName = '$s9LaunchPad20launchpadSpringboardAA0D0CSgvp';
// A local symbol: not an export, and findSymbolByName does not see it, so the symbol table is searched.
const springboardGlobal = (() => {
  const found = Process.mainModule.enumerateSymbols().find(s => s.name === globalName);
  return found === undefined ? null : found.address;
})();

function event(e) {
  if (e.isNull()) return null;
  const cg = msgP(e, sel('event'));
  return {
    keyData: msgU16(e, sel('keyData')),
    keyCode: cg.isNull() ? null : CGEventGetIntegerValueField(cg, 9).toNumber(),
    flags: '0x' + msgU64(e, sel('flags')).toString(16),
    commandKeyDown: !!msgB(e, sel('commandKeyDown')),
  };
}

function selection(itemLayer) {
  const layer = ivar(itemLayer, '_selectionLayer');
  const image = msgP(itemLayer, sel('imageLayer'));
  const label = msgP(itemLayer, sel('labelLayer'));
  const jitter = ivar(itemLayer, 'jitterLayer');
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
    animationKeys: strings(msgP(layer, sel('animationKeys'))),
  };
  return out;
}

function state() {
  if (springboardGlobal === null) throw new Error('not found: ' + globalName);
  const sb = springboardGlobal.readPointer();
  if (sb.isNull()) throw new Error('no controller yet');
  const ecsb = ivar(sb, 'springboard');
  const pager = msgP(ecsb, sel('pager'));
  const selected = msgP(pager, sel('selectedItem'));
  const pages = msgP(pager, sel('pages'));
  const n = Number(msgU(pages, sel('count')));
  let where = null;
  const selections = [];
  for (let i = 0; i < n; i++) {
    const items = msgP(msgP(msgPU(pages, sel('objectAtIndex:'), i), sel('item')), sel('items'));
    const k = Number(msgU(items, sel('count')));
    for (let j = 0; j < k; j++) {
      const item = msgPU(items, sel('objectAtIndex:'), j);
      if (!selected.isNull() && item.equals(selected)) where = { page: i, index: j };
      const itemLayer = msgP(item, sel('itemLayer'));
      if (itemLayer.isNull()) continue;
      if (ivar(itemLayer, '_selectionLayer').isNull() && !msgB(itemLayer, sel('selected'))) continue;
      selections.push({ page: i, index: j, itemLayer: className(itemLayer), state: selection(itemLayer) });
    }
  }
  let selectedItem = null;
  if (!selected.isNull()) {
    const client = msgP(selected, sel('clientItem'));
    selectedItem = { class: className(selected), title: client.isNull() ? null : str(msgP(client, sel('title'))), where };
  }
  return {
    visible: !!msgB(sb, sel('visible')),
    currentPageIndex: Number(msgU(pager, sel('currentPageIndex'))),
    pages: { count: n },
    selectedItem,
    selections,
  };
}

function snapshot(why) {
  try {
    write({ type: 'snapshot', why, state: state() });
  } catch (e) {
    write({ type: 'note', text: 'snapshot failed: ' + e });
  }
}

let why = 'load';
const take = new NativeCallback(() => snapshot(why), 'void', ['pointer']);
dispatch_async_f(mainQueue, NULL, take);

const cmdPath = home + '/frida-gadget/lp-keyboard-launchpad-cmd.txt';
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

// --- Objective-C entry points ------------------------------------------------

const bool = r => r.toUInt32() & 1;
const key = a => [event(a[2])];

const HOOKS = [
  // [class, selector, args, ret, after]
  ['Springboard', 'keyDown:', key, bool, () => snapshot('keyDown returned')],
  ['Springboard', 'keyUp:', key, bool],
  ['Springboard', 'performActionForItem:withEvent:sender:', a => [className(a[2]), event(a[3]), className(a[4])], null],
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
      try {
        write({ type: 'call', ph: 'enter', fn, self: className(a[0]), args: args === null ? [] : args(a) });
      } catch (e) {
        write({ type: 'note', text: fn + ' enter failed: ' + e });
      }
    },
    onLeave(r) {
      try {
        if (ret !== null && ret !== undefined) write({ type: 'call', ph: 'leave', fn, ret: ret(r) });
        if (after !== undefined && after !== null) after();
      } catch (e) {
        write({ type: 'note', text: fn + ' leave failed: ' + e });
      }
    },
  });
}
