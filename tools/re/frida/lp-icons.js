// Record how the macOS 15 Launchpad in Dock (reference VM) gets its icons and puts them into the
// item layers (REF-GRID-012, REF-GRID-014): icon requests and generations, database reads and
// writes, the placeholder cache, property refreshes, the open path's reload and pending updates.
// Frida 17 core API only (no Objective-C bridge through REA, REF-ENV-003).
//
// Load it with frida-gadget at Dock's start to see the startup too: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-icons.js"}}
// in frida-gadget.config, restart Dock with the gadget (open
// ~/frida-gadget/restart-dock-with-gadget.command in the VM), and restore the listening config
// afterwards. Nothing is written to Dock's objects.
//
// File: $HOME/frida-gadget/lp-icons-<UTC load time>.jsonl, created exclusively, flushed per line.
// Every line has t (CACurrentMediaTime) and main (on the main thread). Lines ("type"):
//   header        frida, pid, utc
//   readAll       phase enter/leave of -[LPStorage _readAllItemObjects]
//   request       -[Springboard _requestImagesForRunnable:]: title
//   register      -[Springboard registerObservationOfItem:]: class, title
//   retrieve      -[LPRunnable _retrieveImageOfLargeSize:andMiniSize:force:]: title, large, mini, force
//   binding       _LSBindingCreateWithURL: path
//   is            ISCreateCGImageFromBindingWithSizeScaleAndOptions: width, height, scale, options (null or not)
//   loadImage     -[LPStorage _loadImage:fromApp:withBlock:]: large, title
//   storeImage    -[LPStorage _updateImageStorageForItem:]: title
//   setModelIcon  -[LPRunnable setIcon:] / setMiniIcon:: which, title, width (null for nil)
//   entry         +[ECSizedIconImageCache entryWithIcon:forSize:andScaleFactor:]: iconNil, size, scale, result
//   kvo           -[Springboard observeValueForKeyPath:ofObject:change:context:]: keyPath, title
//   refresh       -[Springboard _refreshItem:property:]: property, title, visible
//   pending       phase enter/leave of -[Springboard processPendingUpdates]
//   reload        -[ECSBSpringboard reloadItemContents:]: exceptCurrent
//   layout        -[Springboard layout]
//   setVisible    phase enter/leave of -[Springboard setVisible:slow:forGaming:reason:]: visible
//   setIcon       -[ECSBItemLayer setIcon:]: class of the contents, width (CGImage pixels or entry width)
//   setValue      -[ECSBSpringboard setValue:forKey:ofItem:]: key, title

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

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');
const file = new File(`${home}/frida-gadget/lp-icons-${utc}.jsonl`, 'wx');
function write(rec) {
  rec.t = CACurrentMediaTime();
  rec.main = pthread_main_np() === 1;
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}
write({ type: 'header', frida: Frida.version, pid: Process.id, utc });

function method(className, selector, isClass) {
  const c = cls(className);
  const target = isClass ? object_getClass(c) : c;
  return class_getMethodImplementation(target, sel(selector)).strip();
}

function phases(impl, type, enterExtra) {
  Interceptor.attach(impl, {
    onEnter(args) {
      const rec = { type, phase: 'enter' };
      if (enterExtra) Object.assign(rec, enterExtra(args, this));
      write(rec);
    },
    onLeave() {
      write({ type, phase: 'leave' });
    },
  });
}

phases(method('LPStorage', '_readAllItemObjects'), 'readAll');
phases(method('Springboard', 'processPendingUpdates'), 'pending');
phases(method('Springboard', 'setVisible:slow:forGaming:reason:'), 'setVisible', args => ({ visible: args[2].toInt32() & 1 }));

Interceptor.attach(method('Springboard', '_requestImagesForRunnable:'), {
  onEnter(args) { write({ type: 'request', title: title(args[2]) }); },
});
Interceptor.attach(method('Springboard', 'registerObservationOfItem:'), {
  onEnter(args) { write({ type: 'register', class: className(args[2]), title: title(args[2]) }); },
});
Interceptor.attach(method('LPRunnable', '_retrieveImageOfLargeSize:andMiniSize:force:'), {
  onEnter(args) {
    write({ type: 'retrieve', title: title(args[0]), large: args[2].toUInt32(), mini: args[3].toUInt32(), force: args[4].toInt32() & 1 });
  },
});
Interceptor.attach(Process.getModuleByName('LaunchServices').getExportByName('_LSBindingCreateWithURL'), {
  onEnter(args) { write({ type: 'binding', path: args[1].isNull() ? null : str(msgP(args[1], sel('path'))) }); },
});
Interceptor.attach(Process.getModuleByName('IconServices').getExportByName('ISCreateCGImageFromBindingWithSizeScaleAndOptions'), {
  onEnter(args) {
    write({ type: 'is', width: this.context.d0, height: this.context.d1, scale: args[1].toUInt32(), options: args[2].isNull() ? null : 'set' });
  },
});
Interceptor.attach(method('LPStorage', '_loadImage:fromApp:withBlock:'), {
  onEnter(args) { write({ type: 'loadImage', large: args[2].toInt32() & 1, title: title(args[3]) }); },
});
Interceptor.attach(method('LPStorage', '_updateImageStorageForItem:'), {
  onEnter(args) { write({ type: 'storeImage', title: title(args[2]) }); },
});
for (const [selector, which] of [['setIcon:', 'icon'], ['setMiniIcon:', 'miniIcon']]) {
  Interceptor.attach(method('LPRunnable', selector), {
    onEnter(args) { write({ type: 'setModelIcon', which, title: title(args[0]), width: imageWidth(args[2]) }); },
  });
}
Interceptor.attach(method('ECSizedIconImageCache', 'entryWithIcon:forSize:andScaleFactor:', true), {
  onEnter(args) {
    this.rec = { type: 'entry', iconNil: args[2].isNull(), size: args[3].toInt32(), scale: this.context.s0 };
  },
  onLeave(ret) {
    this.rec.result = ret.isNull() ? null : { class: className(ret), width: imageWidth(ret) };
    write(this.rec);
  },
});
Interceptor.attach(method('Springboard', 'observeValueForKeyPath:ofObject:change:context:'), {
  onEnter(args) { write({ type: 'kvo', keyPath: str(args[2]), title: title(args[3]) }); },
});
Interceptor.attach(method('Springboard', '_refreshItem:property:'), {
  onEnter(args) {
    write({ type: 'refresh', property: str(args[3]), title: title(args[2]), visible: args[0].add(0x134).readU8() & 1 });
  },
});
Interceptor.attach(method('ECSBSpringboard', 'reloadItemContents:'), {
  onEnter(args) { write({ type: 'reload', exceptCurrent: args[2].toInt32() & 1 }); },
});
Interceptor.attach(method('Springboard', 'layout'), {
  onEnter() { write({ type: 'layout' }); },
});
Interceptor.attach(method('ECSBItemLayer', 'setIcon:'), {
  onEnter(args) { write({ type: 'setIcon', class: className(args[2]), width: imageWidth(args[2]) }); },
});
Interceptor.attach(method('ECSBSpringboard', 'setValue:forKey:ofItem:'), {
  onEnter(args) { write({ type: 'setValue', key: str(args[3]), title: title(args[4]) }); },
});
