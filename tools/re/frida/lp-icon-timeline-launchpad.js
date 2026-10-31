// Record when this project's background process (LaunchPadAgent, macOS 26 comparison VM) caches,
// purges and sets icon contents around opening and closing, in the same lines as lp-icon-timeline.js
// records the original, so the two can be compared (REF-GRID-015, REF-GRID-016). The controller
// and the grid call these methods from Swift, so the Swift methods are hooked, not their
// Objective-C entries; self is in x20. Frida 17 core API only, as lp-icon-timeline.js.
//
// Load it with frida-gadget when the agent starts: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-icon-timeline-launchpad.js"}}
// in frida-gadget.config next to the gadget and start the agent with DYLD_INSERT_LIBRARIES set to
// the gadget (~/frida-gadget/restart-agent-with-gadget.command), as lp-icons-launchpad.js. Nothing is
// written to the process's objects.
//
// File: $HOME/frida-gadget/lp-icon-timeline-launchpad-<UTC load time>.jsonl, created exclusively,
// flushed per line. Lines as in lp-icon-timeline.js, except that kvo has no title and the caller of
// loadImage is not recorded. Every line has t (CACurrentMediaTime) and main (on the main thread). Lines ("type"):
//   header         frida, pid, utc
//   setVisible     phase enter/leave of -[Springboard setVisible:slow:forGaming:reason:]: visible
//   cacheIcons     phase enter/leave of -[LPRoot setShouldCacheIcons:]: value; on leave, runnables:
//                  how many -[LPRunnable setShouldCacheIcons:] calls it made
//   purgeLater     -[Springboard purgeItemContentsLater]
//   purgeTimer     phase enter/leave of the purge timer's block: visible, visibility
//   purge          -[ECSBSpringboard purgeItemContents:] / -[ECSBPager purgeItemContents:]: class, arg;
//                  on the springboard's leave, counts of the page, grid, item layer, folder item
//                  layer and folder purges it made
//   sbVisible      -[ECSBSpringboard setVisible:] / -[ECSBPager setVisible:]: class, arg; on the
//                  springboard's leave, itemLayers: how many -[ECSBItemLayer setVisible:] calls
//   pending        phase enter/leave of -[Springboard processPendingUpdates]
//   kvo            -[Springboard observeValueForKeyPath:ofObject:change:context:]: keyPath, title
//   refresh        -[Springboard _refreshItem:property:]: property, title, visible
//   reload         -[ECSBSpringboard reloadItemContents:]: exceptCurrent
//   setIcon        -[ECSBItemLayer setIcon:]: class, width (CGImage pixels or entry width), old
//                  (width of the image layer's contents before, null for none)
//   setMini        -[ECSBGroupItemLayer setValue:forKey:ofItem:]: key, title, and for the mini icon
//                  layer it set (its contents are the value afterwards): index, old and new width,
//                  same (the old contents were already the same image object)
//   retrieve       -[LPRunnable _retrieveImageOfLargeSize:andMiniSize:force:]: title, large, mini, force
//   is             ISCreateCGImageFromBindingWithSizeScaleAndOptions: width
//   loadImage      -[LPRunnable loadImage:block:]: large, title; for the first 5, caller: return
//                  addresses as offsets into Dock's image (null outside it)
//   setModelIcon   -[LPRunnable setIcon:] / setMiniIcon:: which, title, width, old (the ivar's width)
//   anim           -[CALayer addAnimation:forKey:] for the key "contents": layer class, the
//                  classes of two superlayers, duration and disableActions of the transaction

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
const class_getMethodImplementation = nf(libobjc, 'class_getMethodImplementation', 'pointer', ['pointer', 'pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
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
  return -1;
}
function ivarOffset(className, name) {
  return ivar_getOffset(class_getInstanceVariable(cls(className), Memory.allocUtf8String(name))).toNumber();
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');
const file = new File(`${home}/frida-gadget/lp-icon-timeline-launchpad-${utc}.jsonl`, 'wx');
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

const visibleOffset = ivarOffset('Springboard', '_visible');
const visibilityOffset = ivarOffset('Springboard', '_visibility');
const iconOffset = ivarOffset('LPItem', '_icon');
const miniIconOffset = ivarOffset('LPItem', '_miniIcon');

const counts = {};
function count(name) {
  counts[name] = (counts[name] || 0) + 1;
}
function takeCounts() {
  const c = Object.assign({}, counts);
  for (const k of Object.keys(counts)) delete counts[k];
  return c;
}

on('$s9LaunchPad11SpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtF',
  args => write({ type: 'setVisible', phase: 'enter', visible: args[0].toUInt32() & 1 }),
  () => write({ type: 'setVisible', phase: 'leave' }));
on('$s9LaunchPad6LPRootC19setShouldCacheIconsyySbF',
  args => { takeCounts(); write({ type: 'cacheIcons', phase: 'enter', value: args[0].toUInt32() & 1 }); },
  () => write({ type: 'cacheIcons', phase: 'leave', runnables: takeCounts().runnable || 0 }));
on('$s9LaunchPad10LPRunnableC19setShouldCacheIconsyySbF', () => count('runnable'));
on('$s9LaunchPad11SpringboardC22purgeItemContentsLateryyF', () => write({ type: 'purgeLater' }));
on('$s9LaunchPad11SpringboardC22purgeItemContentsLateryyFyycfU_yyScMYcXEfU_', function () {
  // The block's MainActor closure; the controller is its captured context.
  write({ type: 'purgeTimer', phase: 'enter' });
}, () => write({ type: 'purgeTimer', phase: 'leave' }));
on('$s9LaunchPad15ECSBSpringboardC17purgeItemContentsyySbF',
  args => { takeCounts(); write({ type: 'purge', class: 'ECSBSpringboard', arg: args[0].toUInt32() & 1 }); },
  () => write({ type: 'purge', class: 'ECSBSpringboard', phase: 'leave', counts: takeCounts() }));
on('$s9LaunchPad9ECSBPagerC17purgeItemContentsyySbF',
  args => write({ type: 'purge', class: 'ECSBPager', arg: args[0].toUInt32() & 1 }));
for (const [name, key] of [['$s9LaunchPad8ECSBPageC17purgeItemContentsyyF', 'page'],
  ['$s9LaunchPad13ECSBGridLayerC17purgeItemContentsyyF', 'grid'],
  ['$s9LaunchPad13ECSBItemLayerC17purgeItemContentsyyF', 'itemLayer'],
  ['$s9LaunchPad18ECSBGroupItemLayerC05purgeD8ContentsyyF', 'groupItemLayer'],
  ['$s9LaunchPad9ECSBGroupC17purgeItemContentsyyF', 'group']]) {
  on(name, () => count(key));
}
on('$s9LaunchPad15ECSBSpringboardC10setVisibleyySbF',
  args => { takeCounts(); write({ type: 'sbVisible', class: 'ECSBSpringboard', arg: args[0].toUInt32() & 1 }); },
  () => write({ type: 'sbVisible', class: 'ECSBSpringboard', phase: 'leave', itemLayers: takeCounts().itemVisible || 0 }));
on('$s9LaunchPad9ECSBPagerC10setVisibleyySbF',
  args => write({ type: 'sbVisible', class: 'ECSBPager', arg: args[0].toUInt32() & 1 }));
on('$s9LaunchPad13ECSBItemLayerC10setVisibleyySbF', () => count('itemVisible'));
on('$s9LaunchPad11SpringboardC21processPendingUpdatesyyF',
  () => write({ type: 'pending', phase: 'enter' }), () => write({ type: 'pending', phase: 'leave' }));
on('$s9LaunchPad11SpringboardC12observeValue10forKeyPath2of6change7contextySSSg_ypSgSDySo05NSKeye6ChangeG0aypGSgSvSgtF',
  args => write({ type: 'kvo', keyPath: args[1].isNull() ? null : swiftString(args[0], args[1]) }));
on('$s9LaunchPad11SpringboardC12_refreshItem_8propertyyAA6LPItemC_SStF', function (args) {
  write({ type: 'refresh', property: swiftString(args[1], args[2]), title: title(args[0]), visible: this.context.x20.add(visibleOffset).readU8() & 1 });
});
on('$s9LaunchPad15ECSBSpringboardC18reloadItemContentsyySbF',
  args => write({ type: 'reload', exceptCurrent: args[0].toUInt32() & 1 }));
on('$s9LaunchPad13ECSBItemLayerC4iconyXlSgvs', function (args) {
  const image = msgP(this.context.x20, sel('imageLayer'));
  const old = image.isNull() ? ptr(0) : msgP(image, sel('contents'));
  write({ type: 'setIcon', class: className(args[0]), width: imageWidth(args[0]), old: imageWidth(old) });
});
function miniContents(layer) {
  const grid = msgP(layer, sel('miniGridLayer'));
  const out = [];
  if (grid.isNull()) return out;
  const n = msgU(grid, sel('numberOfItems')).toNumber();
  for (let i = 0; i < n && i < 1000; i++) {
    const l = msgPU(grid, sel('itemLayerAtIndex:'), i);
    out.push(l.isNull() ? ptr(0) : msgP(l, sel('contents')));
  }
  return out;
}
on('$s9LaunchPad18ECSBGroupItemLayerC8setValue_6forKey02ofD0yyXlSg_SSAA8ECSBItemCSgtF', function (args) {
  this.layer = this.context.x20;
  this.value = args[0];
  this.rec = { type: 'setMini', key: swiftString(args[1], args[2]), title: null };
  this.before = miniContents(this.layer);
}, function () {
  const after = miniContents(this.layer);
  this.rec.set = [];
  for (let i = 0; i < after.length; i++) {
    if (this.value.isNull() || !after[i].equals(this.value)) continue;
    const b = i < this.before.length ? this.before[i] : ptr(0);
    this.rec.set.push({ index: i, old: imageWidth(b), new: imageWidth(this.value), same: b.equals(this.value) });
  }
  write(this.rec);
});
on('$s9LaunchPad10LPRunnableC25_retrieveImageOfLargeSize_07andMiniH05forceySu_SuSbtF', function (args) {
  write({ type: 'retrieve', title: title(this.context.x20), large: args[0].toUInt32(), mini: args[1].toUInt32(), force: args[2].toUInt32() & 1 });
});
Interceptor.attach(Process.getModuleByName('IconServices').getExportByName('ISCreateCGImageFromBindingWithSizeScaleAndOptions'), {
  onEnter() { write({ type: 'is', width: this.context.d0 }); },
});
on('$s9LaunchPad10LPRunnableC9loadImage_5blockySb_ySu_yXlSgtXBtF', function (args) {
  write({ type: 'loadImage', large: args[0].toUInt32() & 1, title: title(this.context.x20) });
});
for (const [name, which, offset] of [['$s9LaunchPad10LPRunnableC4iconyXlSgvs', 'icon', iconOffset],
  ['$s9LaunchPad10LPRunnableC8miniIconyXlSgvs', 'miniIcon', miniIconOffset]]) {
  on(name, function (args) {
    write({ type: 'setModelIcon', which, title: title(this.context.x20), width: imageWidth(args[0]), old: imageWidth(this.context.x20.add(offset).readPointer()) });
  });
}
const CATransaction = cls('CATransaction');
const contentsKey = 'contents';
Interceptor.attach(method('CALayer', 'addAnimation:forKey:'), {
  onEnter(args) {
    if (args[3].isNull() || str(args[3]) !== contentsKey) return;
    const s1 = msgP(args[0], sel('superlayer'));
    const s2 = s1.isNull() ? ptr(0) : msgP(s1, sel('superlayer'));
    write({
      type: 'anim', layer: className(args[0]), address: args[0].toString(), super1: className(s1), super2: className(s2),
      duration: msgD(CATransaction, sel('animationDuration')), disableActions: msgB(CATransaction, sel('disableActions')),
    });
  },
});
