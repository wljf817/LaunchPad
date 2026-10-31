// Record how this project's background process (LaunchPadAgent, macOS 26 comparison VM) gets its
// icons and puts them into the item layers, in the same lines as lp-icons.js records the original,
// so the two can be compared (REF-GRID-012, REF-GRID-014). The controller calls these methods from
// Swift, so the Swift methods are hooked, not their Objective-C entries; self is in x20.
// Frida 17 core API only, as lp-icons.js.
//
// Load it with frida-gadget when the agent starts: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-icons-launchpad.js"}}
// in frida-gadget.config next to the gadget and start the agent with DYLD_INSERT_LIBRARIES set to the
// gadget, as lp-geometry-launchpad.js. Nothing is written to the process's objects.
//
// File: $HOME/frida-gadget/lp-icons-launchpad-<UTC load time>.jsonl, created exclusively, flushed per
// line. Every line has t (CACurrentMediaTime) and main (on the main thread). Lines ("type") as in
// lp-icons.js, except that there is no readAll, kvo or setModelIcon's nil width distinction, and:
//   animation     Springboard._enterExitAnimation(_:slow:): enter

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
const class_getName = nf(libobjc, 'class_getName', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGImageGetTypeID = nf(cg, 'CGImageGetTypeID', 'ulong', []);
const CGImageGetWidth = nf(cg, 'CGImageGetWidth', 'ulong', ['pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const pthread_main_np = new NativeFunction(Module.getGlobalExportByName('pthread_main_np'), 'int', []);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);
const cgImageType = CGImageGetTypeID().toString();

function sel(name) {
  return sel_registerName(Memory.allocUtf8String(name));
}
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
function className(obj) {
  return obj.isNull() ? null : class_getName(object_getClass(obj)).readUtf8String();
}
function str(ns) {
  return ns.isNull() ? null : msgP(ns, sel('UTF8String')).readUtf8String();
}
function title(item) {
  if (item.isNull()) return null;
  if (!msgBP(item, sel('respondsToSelector:'), sel('title'))) return null;
  return str(msgP(item, sel('title')));
}
function imageWidth(obj) {
  if (obj.isNull()) return null;
  if (CFGetTypeID(obj).toString() === cgImageType) return CGImageGetWidth(obj).toNumber();
  if (msgBP(obj, sel('respondsToSelector:'), sel('width'))) return msgU32(obj, sel('width'));
  return null;
}
// A Swift String passed in two registers; only small (inline) strings are decoded, which is enough
// for the property names and keys.
function swiftString(lo, hi) {
  const top = hi.shr(56).toUInt32();
  if ((top & 0xf0) !== 0xe0) return '<large>';
  const count = top & 0x0f;
  const bytes = [];
  for (let i = 0; i < count; i++) {
    const word = i < 8 ? lo : hi;
    bytes.push(word.shr(8 * (i % 8)).and(0xff).toUInt32());
  }
  return String.fromCharCode(...bytes);
}
const visibleOffset = ivar_getOffset(class_getInstanceVariable(cls('Springboard'), Memory.allocUtf8String('_visible')));

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');
const file = new File(`${home}/frida-gadget/lp-icons-launchpad-${utc}.jsonl`, 'wx');
function write(rec) {
  rec.t = CACurrentMediaTime();
  rec.main = pthread_main_np() === 1;
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}
write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

const main = Process.mainModule;
function swift(name) {
  const p = main.findExportByName(name) ?? main.findSymbolByName(name);
  if (p === null) throw new Error('not found: ' + name);
  return p;
}
function on(name, onEnter, onLeave) {
  Interceptor.attach(swift(name), { onEnter, onLeave });
}

on('$s9LaunchPad11SpringboardC21processPendingUpdatesyyF',
  () => write({ type: 'pending', phase: 'enter' }), () => write({ type: 'pending', phase: 'leave' }));
on('$s9LaunchPad11SpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtF',
  args => write({ type: 'setVisible', phase: 'enter', visible: args[0].toUInt32() & 1 }),
  () => write({ type: 'setVisible', phase: 'leave' }));
on('$s9LaunchPad11SpringboardC25_requestImagesForRunnableyyAA10LPRunnableCF',
  args => write({ type: 'request', title: title(args[0]) }));
on('$s9LaunchPad11SpringboardC25registerObservationOfItemySbAA6LPItemCF',
  args => write({ type: 'register', class: className(args[0]), title: title(args[0]) }));
on('$s9LaunchPad10LPRunnableC25_retrieveImageOfLargeSize_07andMiniH05forceySu_SuSbtF', function (args) {
  write({ type: 'retrieve', title: title(this.context.x20), large: args[0].toUInt32(), mini: args[1].toUInt32(), force: args[2].toUInt32() & 1 });
});
Interceptor.attach(Process.getModuleByName('LaunchServices').getExportByName('_LSBindingCreateWithURL'), {
  onEnter(args) { write({ type: 'binding', path: args[1].isNull() ? null : str(msgP(args[1], sel('path'))) }); },
});
Interceptor.attach(Process.getModuleByName('IconServices').getExportByName('ISCreateCGImageFromBindingWithSizeScaleAndOptions'), {
  onEnter(args) {
    write({ type: 'is', width: this.context.d0, height: this.context.d1, scale: args[1].toUInt32(), options: args[2].isNull() ? null : 'set' });
  },
});
on('$s9LaunchPad9LPStorageC10_loadImage_7fromApp9withBlockySb_AA6LPItemCySu_yXlSgtXBtF',
  args => write({ type: 'loadImage', large: args[0].toUInt32() & 1, title: title(args[1]) }));
on('$s9LaunchPad9LPStorageC26_updateImageStorageForItemyyAA6LPItemCF',
  args => write({ type: 'storeImage', title: title(args[0]) }));
for (const [name, which] of [['$s9LaunchPad10LPRunnableC4iconyXlSgvs', 'icon'], ['$s9LaunchPad10LPRunnableC8miniIconyXlSgvs', 'miniIcon']]) {
  on(name, function (args) {
    write({ type: 'setModelIcon', which, title: title(this.context.x20), width: imageWidth(args[0]) });
  });
}
on('$s9LaunchPad21ECSizedIconImageCacheC5entry04withD07forSize14andScaleFactorAA0cdeF5EntryCSgyXlSg_s5Int32VSftFZ',
  function (args) {
    this.rec = { type: 'entry', iconNil: args[0].isNull(), size: args[1].toInt32(), scale: this.context.s0 };
  },
  function (ret) {
    this.rec.result = ret.isNull() ? null : { class: className(ret), width: imageWidth(ret) };
    write(this.rec);
  });
on('$s9LaunchPad11SpringboardC12_refreshItem_8propertyyAA6LPItemC_SStF', function (args) {
  write({ type: 'refresh', property: swiftString(args[1], args[2]), title: title(args[0]), visible: this.context.x20.add(visibleOffset).readU8() & 1 });
});
on('$s9LaunchPad15ECSBSpringboardC18reloadItemContentsyySbF',
  args => write({ type: 'reload', exceptCurrent: args[0].toUInt32() & 1 }));
on('$s9LaunchPad11SpringboardC6layoutyyF', () => write({ type: 'layout' }));
on('$s9LaunchPad11SpringboardC19_enterExitAnimation_4slowySb_SbtF',
  args => write({ type: 'animation', enter: args[0].toUInt32() & 1 }));
on('$s9LaunchPad13ECSBItemLayerC4iconyXlSgvs',
  args => write({ type: 'setIcon', class: className(args[0]), width: imageWidth(args[0]) }));
on('$s9LaunchPad15ECSBSpringboardC8setValue_6forKey6ofItemyyXlSg_SSAGtF',
  args => write({ type: 'setValue', key: swiftString(args[1], args[2]), title: title(args[3]) }));
