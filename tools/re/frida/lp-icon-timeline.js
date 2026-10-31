// Record when the macOS 15 Launchpad in Dock (reference VM) caches, purges and sets icon contents
// around opening and closing (REF-GRID-015, REF-GRID-016): the cache switch, the purge timer and
// its block, the purge chain, the visibility chain, the pending updates and property refreshes,
// icon and mini icon contents, and the implicit `contents` animations they cause.
// Frida 17 core API only (no Objective-C bridge through REA, REF-ENV-003).
//
// Load it with frida-gadget at Dock's start to see the first open after Dock starts: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-icon-timeline.js"}}
// in frida-gadget.config, restart Dock with the gadget (open
// ~/frida-gadget/restart-dock-with-gadget.command in the VM), and restore the listening config
// afterwards. Nothing is written to Dock's objects.
//
// File: $HOME/frida-gadget/lp-icon-timeline-<UTC load time>.jsonl, created exclusively, flushed
// per line. Every line has t (CACurrentMediaTime) and main (on the main thread). Lines ("type"):
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
const file = new File(`${home}/frida-gadget/lp-icon-timeline-${utc}.jsonl`, 'wx');
function write(rec) {
  rec.t = CACurrentMediaTime();
  rec.main = pthread_main_np() === 1;
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}
write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

function method(className, selector) {
  return class_getMethodImplementation(cls(className), sel(selector)).strip();
}

const visibleOffset = ivarOffset('Springboard', '_visible');
const visibilityOffset = ivarOffset('Springboard', '_visibility');
const imageLayerOffset = ivarOffset('ECSBItemLayer', '_imageLayer');
const miniGridOffset = ivarOffset('ECSBGroupItemLayer', '_miniGridLayer');
// The purge timer's block has no symbol; its address is read from the disassembly of
// -[Springboard purgeItemContentsLater] in 15.6.1 (24G90), relative to Dock's image base.
const dock = Process.mainModule;
const purgeTimerBlock = dock.base.add(0x90c0c);

const counts = {};
function count(name) {
  counts[name] = (counts[name] || 0) + 1;
}
function takeCounts() {
  const c = Object.assign({}, counts);
  for (const k of Object.keys(counts)) delete counts[k];
  return c;
}

Interceptor.attach(method('Springboard', 'setVisible:slow:forGaming:reason:'), {
  onEnter(args) { write({ type: 'setVisible', phase: 'enter', visible: args[2].toInt32() & 1 }); },
  onLeave() { write({ type: 'setVisible', phase: 'leave' }); },
});
Interceptor.attach(method('LPRoot', 'setShouldCacheIcons:'), {
  onEnter(args) { takeCounts(); write({ type: 'cacheIcons', phase: 'enter', value: args[2].toInt32() & 1 }); },
  onLeave() { write({ type: 'cacheIcons', phase: 'leave', runnables: takeCounts().runnable || 0 }); },
});
Interceptor.attach(method('LPRunnable', 'setShouldCacheIcons:'), { onEnter() { count('runnable'); } });
Interceptor.attach(method('Springboard', 'purgeItemContentsLater'), {
  onEnter() { write({ type: 'purgeLater' }); },
});
Interceptor.attach(purgeTimerBlock, {
  onEnter(args) {
    const sb = args[0].add(0x20).readPointer();
    write({ type: 'purgeTimer', phase: 'enter', visible: sb.add(visibleOffset).readU8() & 1, visibility: sb.add(visibilityOffset).readFloat() });
  },
  onLeave() { write({ type: 'purgeTimer', phase: 'leave' }); },
});
for (const c of ['ECSBSpringboard', 'ECSBPager']) {
  Interceptor.attach(method(c, 'purgeItemContents:'), {
    onEnter(args) {
      if (c === 'ECSBSpringboard') takeCounts();
      write({ type: 'purge', class: c, arg: args[2].toInt32() & 1 });
    },
    onLeave() {
      if (c === 'ECSBSpringboard') write({ type: 'purge', class: c, phase: 'leave', counts: takeCounts() });
    },
  });
}
for (const [c, name] of [['ECSBPage', 'page'], ['ECSBGridLayer', 'grid'], ['ECSBItemLayer', 'itemLayer'],
  ['ECSBGroupItemLayer', 'groupItemLayer'], ['ECSBGroup', 'group']]) {
  Interceptor.attach(method(c, 'purgeItemContents'), { onEnter() { count(name); } });
}
for (const c of ['ECSBSpringboard', 'ECSBPager']) {
  Interceptor.attach(method(c, 'setVisible:'), {
    onEnter(args) {
      if (c === 'ECSBSpringboard') takeCounts();
      write({ type: 'sbVisible', class: c, arg: args[2].toInt32() & 1 });
    },
    onLeave() {
      if (c === 'ECSBSpringboard') write({ type: 'sbVisible', class: c, phase: 'leave', itemLayers: takeCounts().itemVisible || 0 });
    },
  });
}
Interceptor.attach(method('ECSBItemLayer', 'setVisible:'), { onEnter() { count('itemVisible'); } });
Interceptor.attach(method('Springboard', 'processPendingUpdates'), {
  onEnter() { write({ type: 'pending', phase: 'enter' }); },
  onLeave() { write({ type: 'pending', phase: 'leave' }); },
});
Interceptor.attach(method('Springboard', 'observeValueForKeyPath:ofObject:change:context:'), {
  onEnter(args) { write({ type: 'kvo', keyPath: str(args[2]), title: title(args[3]) }); },
});
Interceptor.attach(method('Springboard', '_refreshItem:property:'), {
  onEnter(args) {
    write({ type: 'refresh', property: str(args[3]), title: title(args[2]), visible: args[0].add(visibleOffset).readU8() & 1 });
  },
});
Interceptor.attach(method('ECSBSpringboard', 'reloadItemContents:'), {
  onEnter(args) { write({ type: 'reload', exceptCurrent: args[2].toInt32() & 1 }); },
});
Interceptor.attach(method('ECSBItemLayer', 'setIcon:'), {
  onEnter(args) {
    const image = args[0].add(imageLayerOffset).readPointer();
    const old = image.isNull() ? ptr(0) : msgP(image, sel('contents'));
    write({ type: 'setIcon', class: className(args[2]), width: imageWidth(args[2]), old: imageWidth(old) });
  },
});
function miniContents(layer) {
  const grid = layer.add(miniGridOffset).readPointer();
  const out = [];
  if (grid.isNull()) return out;
  const n = msgU(grid, sel('numberOfItems')).toNumber();
  for (let i = 0; i < n && i < 1000; i++) {
    const l = msgPU(grid, sel('itemLayerAtIndex:'), i);
    out.push(l.isNull() ? ptr(0) : msgP(l, sel('contents')));
  }
  return out;
}
Interceptor.attach(method('ECSBGroupItemLayer', 'setValue:forKey:ofItem:'), {
  onEnter(args) {
    this.layer = args[0];
    this.value = args[2];
    this.rec = { type: 'setMini', key: str(args[3]), title: title(args[4]) };
    this.before = miniContents(args[0]);
  },
  onLeave() {
    const after = miniContents(this.layer);
    this.rec.set = [];
    for (let i = 0; i < after.length; i++) {
      if (this.value.isNull() || !after[i].equals(this.value)) continue;
      const b = i < this.before.length ? this.before[i] : ptr(0);
      this.rec.set.push({ index: i, old: imageWidth(b), new: imageWidth(this.value), same: b.equals(this.value) });
    }
    write(this.rec);
  },
});
Interceptor.attach(method('LPRunnable', '_retrieveImageOfLargeSize:andMiniSize:force:'), {
  onEnter(args) {
    write({ type: 'retrieve', title: title(args[0]), large: args[2].toUInt32(), mini: args[3].toUInt32(), force: args[4].toInt32() & 1 });
  },
});
Interceptor.attach(Process.getModuleByName('IconServices').getExportByName('ISCreateCGImageFromBindingWithSizeScaleAndOptions'), {
  onEnter() { write({ type: 'is', width: this.context.d0 }); },
});
let loadCallers = 0;
function dockOffsets(context) {
  return Thread.backtrace(context, Backtracer.ACCURATE).slice(0, 8).map(a => {
    const s = a.strip();
    return s.compare(dock.base) >= 0 && s.compare(dock.base.add(dock.size)) < 0 ? '0x' + s.sub(dock.base).toString(16) : null;
  });
}
Interceptor.attach(method('LPRunnable', 'loadImage:block:'), {
  onEnter(args) {
    const rec = { type: 'loadImage', large: args[2].toInt32() & 1, title: title(args[0]) };
    if (loadCallers++ < 5) rec.caller = dockOffsets(this.context);
    write(rec);
  },
});
const iconOffset = ivarOffset('LPItem', '_icon');
const miniIconOffset = ivarOffset('LPItem', '_miniIcon');
for (const [selector, which, offset] of [['setIcon:', 'icon', iconOffset], ['setMiniIcon:', 'miniIcon', miniIconOffset]]) {
  Interceptor.attach(method('LPRunnable', selector), {
    onEnter(args) {
      write({ type: 'setModelIcon', which, title: title(args[0]), width: imageWidth(args[2]), old: imageWidth(args[0].add(offset).readPointer()) });
    },
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
