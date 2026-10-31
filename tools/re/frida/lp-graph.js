// Snapshot the object graph and layer tree of the macOS 15 Launchpad in Dock
// (reference VM) each time Launchpad is shown or hidden, to record the
// original's class relationships and layer structure.
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge
// (REF-ENV-003), so Objective-C is driven through the runtime's C functions and
// objc_msgSend, as in ca-anim.js.
//
// Triggers: hooks -[LPSpringboard setVisible:slow:forGaming:reason:] and
// -[Springboard setVisible:reason:] (by implementation; an implementation shared
// by both is hooked once). Only the outermost hooked call on a thread counts.
// When the first argument (visible) is true the snapshot is taken as the call
// returns ("show", "after"); when false, as the call is entered ("hide",
// "before"), which is the settled, fully open state. A third hook,
// -[Springboard _cleanupAfterExitAnimation:openCount:], takes a snapshot as it
// returns ("closed", "after"): the state once the close animation has ended
// and the overlay container has left the window. A snapshot is taken
// synchronously inside the call, on the thread Dock calls it on, so the state
// read is consistent. Nothing is written to Dock's objects.
//
// In this project's background process (LaunchPadAgent, macOS 26 comparison VM) the controller
// opens and closes through the Swift method LPSpringboard.setVisible(_:slow:forGaming:reason:), not
// its Objective-C entry, so that method is hooked as well, with the same triggers ("show" after,
// "hide" before; reason null). Load it there with frida-gadget in script mode, as
// lp-geometry-launchpad.js.
//
// Load through REA: start_frida_session { mode: "attach", pid, remote }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-graph.js" }.
// Toggle Launchpad in the VM (open -a Launchpad, twice). Unload with
// unload_frida_script; fetch the files with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-graph-<UTC load time>.jsonl in the target process,
// created exclusively (never overwritten), every line flushed as written. REA
// messages carry only the file path and script errors.
//
// Lines ("type"):
//   header   frida, pid, mediaTime (CACurrentMediaTime), utc, dockImage
//   snapshot id, trigger {method, visible, phase, slow, forGaming, reason}
//            (the cleanup trigger: {method, phase, openCount}),
//            mediaTime, thread {id, isMain}, springboard (address)
//   window   snapshot, class, address, wid, frame, layer (its root layer)
//   object   snapshot, address, class (the real class; isaClass when key-value
//            observing has swapped the isa), superclasses, image ("dock" or
//            "framework"), and one of:
//              ivars: [{class, name, type, offset, value}] for objects whose
//                class or superclasses are defined in Dock (ivars of framework
//                superclasses are not listed). value: address string or null
//                for objects; number for scalars; {doubles} for structs of
//                doubles; {bytes} hex otherwise; {byte} for bitfields (the
//                byte holding the field); null with "untyped" for ivars
//                without a type encoding (Swift); "invalid" marks an object
//                pointer that is not in a malloc zone or readable file-backed
//                memory (not followed).
//              elements: [address] (NSArray, NSSet, NSOrderedSet), entries:
//                [[key, value]] (NSDictionary), count only (NSMapTable,
//                NSHashTable, whose keys may not be objects)
//              value: for NSString, NSNumber, NSValue, CGColor
//              unexpanded: true for other framework objects
//            Layers (CALayer subclasses) appear here too, with layer: true.
//   layer    snapshot, address, class, name, superlayer, sublayers [address in
//            order], mask, delegate {class, address}, eventDelegate {class,
//            address}, frame, bounds, position, anchorPoint, zPosition,
//            transform, geometryFlipped, sublayerTransform, opacity, hidden, masksToBounds,
//            contentsScale, cornerRadius, speed, timeOffset, beginTime,
//            backgroundColor, contents {class} (never the image itself),
//            filters / backgroundFilters / compositingFilter [{class, name, type}],
//            cornerCurve, contentsGravity, contentsCenter, allowsGroupBlending,
//            allowsHitTesting; contents also {address, width, height} (pixel size
//            of a CGImage, or -width/-height of an object that answers them);
//            text layers (CATextLayer) also text {string, fontName, fontSize,
//            foregroundColor, alignmentMode, truncationMode, wrapped} and, when
//            the layer has them, textShadow {color, offset, blur, hidden}
//            Every layer under the topmost superlayer of the Springboard's root
//            layer, depth first, sublayers in order.
//   end      snapshot, objects, layers, truncated (object cap reached)
// Value encoding of NSValue, NSNumber and CGColor as in ca-anim.js.

'use strict';

const OBJECT_CAP = 50000;

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const sel_getName = nf(libobjc, 'sel_getName', 'pointer', ['pointer']);
const class_getMethodImplementation = nf(libobjc, 'class_getMethodImplementation', 'pointer', ['pointer', 'pointer']);
const class_getName = nf(libobjc, 'class_getName', 'pointer', ['pointer']);
const class_getSuperclass = nf(libobjc, 'class_getSuperclass', 'pointer', ['pointer']);
const class_getImageName = nf(libobjc, 'class_getImageName', 'pointer', ['pointer']);
const class_copyIvarList = nf(libobjc, 'class_copyIvarList', 'pointer', ['pointer', 'pointer']);
const ivar_getName = nf(libobjc, 'ivar_getName', 'pointer', ['pointer']);
const ivar_getTypeEncoding = nf(libobjc, 'ivar_getTypeEncoding', 'pointer', ['pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);
const object_getIvar = nf(libobjc, 'object_getIvar', 'pointer', ['pointer', 'pointer']);
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);

const libsystem = Process.getModuleByName('libsystem_malloc.dylib');
const malloc_zone_from_ptr = nf(libsystem, 'malloc_zone_from_ptr', 'pointer', ['pointer']);
const free = nf(libsystem, 'free', 'void', ['pointer']);
const pthread_main_np = new NativeFunction(Module.getGlobalExportByName('pthread_main_np'), 'int', []);

// arm64 has no _stret/_fpret variants: one entry point, one signature per use.
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgVPU = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'uint64']);

const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGColorGetTypeID = nf(cg, 'CGColorGetTypeID', 'ulong', []);
const CGColorGetNumberOfComponents = nf(cg, 'CGColorGetNumberOfComponents', 'size_t', ['pointer']);
const CGColorGetComponents = nf(cg, 'CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = nf(cg, 'CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = nf(cg, 'CGColorSpaceCopyName', 'pointer', ['pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const NSGetSizeAndAlignment = nf(Process.getModuleByName('Foundation'), 'NSGetSizeAndAlignment', 'pointer', ['pointer', 'pointer', 'pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);

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

const C = {
  CALayer: cls('CALayer'),
  NSString: cls('NSString'),
  NSNumber: cls('NSNumber'),
  NSValue: cls('NSValue'),
  NSArray: cls('NSArray'),
  NSSet: cls('NSSet'),
  NSOrderedSet: cls('NSOrderedSet'),
  NSDictionary: cls('NSDictionary'),
  NSMapTable: cls('NSMapTable'),
  NSHashTable: cls('NSHashTable'),
  LPSpringboard: cls('LPSpringboard'),
  Springboard: cls('Springboard'),
  CATextLayer: cls('CATextLayer'),
};
const cgColorTypeID = CGColorGetTypeID().toString();
const dockImage = Process.mainModule.path;

function num(x) {
  if (Number.isFinite(x)) return x;
  if (Number.isNaN(x)) return 'nan';
  return x > 0 ? 'inf' : '-inf';
}

// Exact shortest decimal for doubles (the script runtime's own conversion is
// not exact); same as ca-anim.js.
const NUMBER_MARK = '\u0001';
const NUMBER_TEXT = /"\\u0001([^"]*)"/g;
const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);

function pow10(n) {
  return 10n ** BigInt(n);
}

function exactNumber(x) {
  if (x === 0) return '0';
  f64[0] = x;
  const bits = u64[0];
  const neg = (bits >> 63n) === 1n;
  const biased = (bits >> 52n) & 0x7ffn;
  const frac = bits & ((1n << 52n) - 1n);
  const m = biased === 0n ? frac : frac | (1n << 52n);
  const e = Number(biased === 0n ? -1074n : biased - 1075n);
  const twoUp = e - 2 >= 0 ? 1n << BigInt(e - 2) : 1n;
  const twoDown = e - 2 < 0 ? 1n << BigInt(2 - e) : 1n;
  const lowGap = frac === 0n && biased > 1n ? 1n : 2n;
  const even = (m & 1n) === 0n;
  const p = Math.floor(Math.log10(Math.abs(x)));
  for (let n = 1; n <= 17; n++) {
    const k = p - n + 1;
    const up10 = k > 0 ? pow10(k) : 1n;
    const down10 = k < 0 ? pow10(-k) : 1n;
    const value = 4n * m * twoUp * down10;
    const unit = up10 * twoDown;
    let d = value / unit;
    const rest = value - d * unit;
    if (2n * rest > unit || (2n * rest === unit && (d & 1n) === 1n)) d += 1n;
    const diff = d * unit - value;
    const gap = (diff >= 0n ? 2n : lowGap) * twoUp * down10;
    const dist = diff >= 0n ? diff : -diff;
    if (dist < gap || (dist === gap && even)) return (neg ? '-' : '') + decimal(d.toString(), k);
  }
  throw new Error('exactNumber failed for ' + x);
}

function decimal(digits, k) {
  digits = digits.replace(/0+$/, z => { k += z.length; return ''; });
  if (digits === '') return '0';
  const point = digits.length + k;
  if (k >= 0 && point <= 21) return digits + '0'.repeat(k);
  if (point > 0 && point <= 21) return digits.slice(0, point) + '.' + digits.slice(point);
  if (point <= 0 && point > -6) return '0.' + '0'.repeat(-point) + digits;
  return digits[0] + (digits.length > 1 ? '.' + digits.slice(1) : '') + 'e' + (point - 1);
}

function cstr(p) {
  return p.isNull() ? null : p.readUtf8String();
}

function isKind(obj, c) {
  return !!msgBP(obj, sel('isKindOfClass:'), c);
}

function responds(obj, name) {
  return !!msgBP(obj, sel('respondsToSelector:'), sel(name));
}

function str(nsString) {
  if (nsString.isNull()) return null;
  return msgP(nsString, sel('UTF8String')).readUtf8String();
}

function addr(p) {
  return p.isNull() ? null : p.toString();
}

// Tagged pointers have the top bit set on arm64. Other pointers are messaged
// only when they lie in a malloc zone or in a loaded image (constant strings,
// class objects); anything else is recorded as invalid and not followed.
function isTagged(p) {
  return !p.and(ptr('0x8000000000000000')).isNull();
}

function isValidObject(p) {
  if (p.isNull()) return false;
  if (isTagged(p)) return true;
  if (!malloc_zone_from_ptr(p).isNull()) return true;
  if (Process.findModuleByAddress(p) !== null) return true;
  // Constant objects (for example literal strings) in an image's data segment
  // or in the shared cache: file-backed, readable memory.
  const range = Process.findRangeByAddress(p);
  return range !== null && range.file !== undefined && range.protection[0] === 'r';
}

function doubleStruct(type) {
  const m = /^\{([^=}]*)=/.exec(type);
  if (m === null) return null;
  const members = type.replace(/"[^"]*"/g, '').replace(/\{[^=}]*=/g, '').replace(/[{}]/g, '');
  return members.length > 0 && /^d+$/.test(members) ? m[1] : null;
}

function nsValue(obj) {
  const typePtr = msgP(obj, sel('objCType'));
  const type = typePtr.readUtf8String();
  const sizeBuf = Memory.alloc(16);
  NSGetSizeAndAlignment(typePtr, sizeBuf, sizeBuf.add(8));
  const size = sizeBuf.readU64().toNumber();
  const buf = Memory.alloc(Math.max(size, 1));
  msgVPU(obj, sel('getValue:size:'), buf, size);
  const name = doubleStruct(type);
  if (name !== null) {
    const doubles = [];
    for (let i = 0; i < size / 8; i++) doubles.push(num(buf.add(i * 8).readDouble()));
    return { objCType: type, struct: name, doubles };
  }
  return { objCType: type, bytes: hex(buf, size) };
}

function hex(p, size) {
  const bytes = new Uint8Array(p.readByteArray(size));
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

function color(obj) {
  const n = CGColorGetNumberOfComponents(obj).toNumber();
  const p = CGColorGetComponents(obj);
  const components = [];
  for (let i = 0; i < n; i++) components.push(num(p.add(i * 8).readDouble()));
  const space = CGColorGetColorSpace(obj);
  let colorSpace = null;
  if (!space.isNull()) {
    const name = CGColorSpaceCopyName(space);
    if (!name.isNull()) {
      colorSpace = str(name);
      CFRelease(name);
    }
  }
  return { colorSpace, components };
}

// Simple values only: never calls description or anything with side effects.
function simpleValue(obj) {
  if (obj.isNull()) return null;
  if (CFGetTypeID(obj).toString() === cgColorTypeID) return color(obj);
  if (isKind(obj, C.NSString)) return str(obj);
  if (isKind(obj, C.NSNumber)) {
    return { objCType: msgP(obj, sel('objCType')).readUtf8String(), number: num(msgD(obj, sel('doubleValue'))) };
  }
  if (isKind(obj, C.NSValue)) return nsValue(obj);
  return undefined;
}

function className(c) {
  return cstr(class_getName(c));
}

function isDockClass(c) {
  return cstr(class_getImageName(c)) === dockImage;
}

function superclasses(c) {
  const out = [];
  for (let s = class_getSuperclass(c); !s.isNull(); s = class_getSuperclass(s)) out.push(className(s));
  return out;
}

const SCALAR = {
  c: p => p.readS8(), C: p => p.readU8(), s: p => p.readS16(), S: p => p.readU16(),
  i: p => p.readS32(), I: p => p.readU32(), l: p => p.readS32(), L: p => p.readU32(),
  q: p => p.readS64().toNumber(), Q: p => p.readU64().toNumber(),
  f: p => num(p.readFloat()), d: p => num(p.readDouble()), B: p => p.readU8(),
};

function scalar(obj, type, offset) {
  const p = obj.add(offset);
  const t = type.replace(/^[rnNoORV]+/, '');
  if (SCALAR[t] !== undefined) return SCALAR[t](p);
  if (/^A[a-zA-Z]$/.test(t) && SCALAR[t[1]] !== undefined) return SCALAR[t[1]](p);
  if (/^b\d+$/.test(t)) return { byte: p.readU8() };
  if (t === ':') { const s = p.readPointer(); return s.isNull() ? null : cstr(sel_getName(s)); }
  if (t === '#') { const c = p.readPointer(); return c.isNull() ? null : className(c); }
  if (t.startsWith('^') || t === '*') return { pointer: p.readPointer().toString() };
  const sizeBuf = Memory.alloc(16);
  NSGetSizeAndAlignment(Memory.allocUtf8String(t), sizeBuf, sizeBuf.add(8));
  const size = sizeBuf.readU64().toNumber();
  const name = doubleStruct(t);
  if (name !== null) {
    const doubles = [];
    for (let i = 0; i < size / 8; i++) doubles.push(num(p.add(i * 8).readDouble()));
    return { struct: name, doubles };
  }
  return { bytes: hex(p, size) };
}

function utcStamp(d) {
  return d.toISOString().replace(/[-:]/g, '');
}

const loadDate = new Date();
const path = getenv(Memory.allocUtf8String('HOME')).readUtf8String() +
  '/frida-gadget/lp-graph-' + utcStamp(loadDate) + '.jsonl';
const file = new File(path, 'wx');

function writeLine(obj) {
  const text = JSON.stringify(obj, (k, v) => typeof v === 'number' ? NUMBER_MARK + exactNumber(v) : v);
  file.write(text.replace(NUMBER_TEXT, '$1') + '\n');
  file.flush();
}

writeLine({
  type: 'header',
  frida: Frida.version,
  pid: Process.id,
  mediaTime: CACurrentMediaTime(),
  utc: loadDate.toISOString(),
  dockImage,
});

// --- object graph ---------------------------------------------------------

function ivarRecords(obj, c, enqueue) {
  const out = [];
  const chain = [];
  for (let k = c; !k.isNull(); k = class_getSuperclass(k)) if (isDockClass(k)) chain.unshift(k);
  const countBuf = Memory.alloc(4);
  for (const k of chain) {
    const list = class_copyIvarList(k, countBuf);
    const n = countBuf.readU32();
    for (let i = 0; i < n; i++) {
      const ivar = list.add(i * Process.pointerSize).readPointer();
      const name = cstr(ivar_getName(ivar));
      const type = cstr(ivar_getTypeEncoding(ivar)) || '';
      const offset = ivar_getOffset(ivar).toNumber();
      const rec = { class: className(k), name, type, offset };
      if (type === '') {
        rec.value = null;
        rec.untyped = true;
      } else if (type.startsWith('@?')) {
        rec.value = addr(obj.add(offset).readPointer());
      } else if (type.startsWith('@')) {
        const v = object_getIvar(obj, ivar);
        rec.value = addr(v);
        if (!v.isNull()) {
          if (isValidObject(v)) enqueue(v); else rec.invalid = true;
        }
      } else {
        rec.value = scalar(obj, type, offset);
      }
      out.push(rec);
    }
    if (!list.isNull()) free(list);
  }
  return out;
}

function collectionRecord(obj, rec, enqueue) {
  const add = v => {
    if (v.isNull()) return null;
    if (!isValidObject(v)) return { invalid: addr(v) };
    enqueue(v);
    return addr(v);
  };
  if (isKind(obj, C.NSArray) || isKind(obj, C.NSOrderedSet)) {
    const n = msgU(obj, sel('count')).toNumber();
    rec.elements = [];
    for (let i = 0; i < n; i++) rec.elements.push(add(msgPU(obj, sel('objectAtIndex:'), i)));
    return true;
  }
  if (isKind(obj, C.NSSet)) {
    const all = msgP(obj, sel('allObjects'));
    const n = msgU(all, sel('count')).toNumber();
    rec.elements = [];
    for (let i = 0; i < n; i++) rec.elements.push(add(msgPU(all, sel('objectAtIndex:'), i)));
    return true;
  }
  if (isKind(obj, C.NSDictionary)) {
    const keys = msgP(obj, sel('allKeys'));
    const n = msgU(keys, sel('count')).toNumber();
    rec.entries = [];
    for (let i = 0; i < n; i++) {
      const key = msgPU(keys, sel('objectAtIndex:'), i);
      rec.entries.push([add(key), add(msgPP(obj, sel('objectForKey:'), key))]);
    }
    return true;
  }
  if (isKind(obj, C.NSMapTable) || isKind(obj, C.NSHashTable)) {
    rec.count = msgU(obj, sel('count')).toNumber();
    return true;
  }
  return false;
}

function dumpGraph(snapshot, root) {
  const seen = new Set();
  const queue = [root];
  const enqueue = p => { if (!seen.has(p.toString())) queue.push(p); };
  let objects = 0;
  let truncated = false;
  while (queue.length > 0) {
    const obj = queue.shift();
    const key = obj.toString();
    if (seen.has(key)) continue;
    if (objects >= OBJECT_CAP) { truncated = true; break; }
    seen.add(key);
    objects++;
    let c = object_getClass(obj);
    const rec = { type: 'object', snapshot, address: key };
    // Key-value observing swaps the isa for an NSKVONotifying_ subclass; -class
    // still returns the real class, which is what is recorded.
    if (!isTagged(obj) && className(c).startsWith('NSKVONotifying_')) {
      rec.isaClass = className(c);
      c = msgP(obj, sel('class'));
    }
    rec.class = className(c);
    rec.superclasses = superclasses(c);
    let dock = false;
    for (let k = c; !k.isNull(); k = class_getSuperclass(k)) if (isDockClass(k)) { dock = true; break; }
    rec.image = dock ? 'dock' : 'framework';
    if (!isTagged(obj) && isKind(obj, C.CALayer)) rec.layer = true;
    if (dock) {
      rec.ivars = ivarRecords(obj, c, enqueue);
    } else if (!collectionRecord(obj, rec, enqueue)) {
      const v = simpleValue(obj);
      if (v !== undefined) rec.value = v; else rec.unexpanded = true;
    }
    writeLine(rec);
  }
  return { objects, truncated };
}

// --- layer tree -----------------------------------------------------------

const LAYER_KEYS = ['frame', 'bounds', 'position', 'anchorPoint', 'zPosition', 'transform', 'geometryFlipped',
  'sublayerTransform', 'opacity', 'hidden', 'masksToBounds', 'contentsScale', 'cornerRadius',
  'speed', 'timeOffset', 'beginTime'];

function kvc(obj, key) {
  return msgPP(obj, sel('valueForKey:'), nsString(key));
}

const nsStrings = new Map();
function nsString(text) {
  let s = nsStrings.get(text);
  if (s === undefined) {
    s = msgPP(C.NSString, sel('stringWithUTF8String:'), Memory.allocUtf8String(text));
    msgP(s, sel('retain'));
    nsStrings.set(text, s);
  }
  return s;
}

function realClassName(p) {
  const name = className(object_getClass(p));
  return name.startsWith('NSKVONotifying_') ? className(msgP(p, sel('class'))) : name;
}

function ref(p) {
  if (p.isNull()) return null;
  return { class: realClassName(p), address: p.toString() };
}

function filters(arr) {
  if (arr.isNull()) return null;
  const list = isKind(arr, C.NSArray) ? arr : null;
  const items = [];
  const one = f => {
    const out = { class: className(object_getClass(f)) };
    if (responds(f, 'name')) out.name = str(msgP(f, sel('name')));
    if (responds(f, 'type')) out.type = str(msgP(f, sel('type')));
    return out;
  };
  if (list === null) return [one(arr)];
  const n = msgU(list, sel('count')).toNumber();
  for (let i = 0; i < n; i++) items.push(one(msgPU(list, sel('objectAtIndex:'), i)));
  return items;
}

const LAYER_EXTRA_KEYS = ['cornerCurve', 'contentsGravity', 'contentsCenter', 'allowsGroupBlending', 'allowsHitTesting'];

const coreGraphics = Process.getModuleByName('CoreGraphics');
const coreText = Process.getModuleByName('CoreText');
const CGImageGetTypeID = nf(coreGraphics, 'CGImageGetTypeID', 'ulong', []);
const CGImageGetWidth = nf(coreGraphics, 'CGImageGetWidth', 'ulong', ['pointer']);
const CGImageGetHeight = nf(coreGraphics, 'CGImageGetHeight', 'ulong', ['pointer']);
const CTFontGetTypeID = nf(coreText, 'CTFontGetTypeID', 'ulong', []);
const CTFontCopyPostScriptName = nf(coreText, 'CTFontCopyPostScriptName', 'pointer', ['pointer']);
const CTFontGetSize = nf(coreText, 'CTFontGetSize', 'double', ['pointer']);
const cgImageTypeID = CGImageGetTypeID().toString();
const ctFontTypeID = CTFontGetTypeID().toString();

function contentsRecord(contents) {
  const out = { class: className(object_getClass(contents)), address: contents.toString() };
  if (CFGetTypeID(contents).toString() === cgImageTypeID) {
    out.width = CGImageGetWidth(contents).toNumber();
    out.height = CGImageGetHeight(contents).toNumber();
  } else if (responds(contents, 'width') && responds(contents, 'height')) {
    out.width = msgU32(contents, sel('width'));
    out.height = msgU32(contents, sel('height'));
  }
  return out;
}

function textRecord(l) {
  const font = msgP(l, sel('font'));
  let fontName = null;
  if (!font.isNull()) {
    if (CFGetTypeID(font).toString() === ctFontTypeID) {
      const name = CTFontCopyPostScriptName(font);
      fontName = { postScriptName: str(name), size: num(CTFontGetSize(font)) };
      CFRelease(name);
    } else {
      fontName = simpleValue(font) ?? { class: className(object_getClass(font)) };
    }
  }
  const foreground = msgP(l, sel('foregroundColor'));
  const string = msgP(l, sel('string'));
  return {
    string: string.isNull() ? null : (isKind(string, C.NSString) ? str(string) : { class: className(object_getClass(string)) }),
    fontName, fontSize: simpleValue(kvc(l, 'fontSize')) ?? null,
    foregroundColor: foreground.isNull() ? null : color(foreground),
    alignmentMode: str(msgP(l, sel('alignmentMode'))),
    truncationMode: str(msgP(l, sel('truncationMode'))),
    wrapped: simpleValue(kvc(l, 'wrapped')) ?? null,
  };
}

function dumpLayers(snapshot, rootLayer) {
  let top = rootLayer;
  for (let s = msgP(top, sel('superlayer')); !s.isNull(); s = msgP(s, sel('superlayer'))) top = s;
  let layers = 0;
  const visit = l => {
    layers++;
    const rec = {
      type: 'layer', snapshot, address: l.toString(), class: realClassName(l),
      name: str(msgP(l, sel('name'))), superlayer: addr(msgP(l, sel('superlayer'))),
    };
    const subs = msgP(l, sel('sublayers'));
    const children = [];
    if (!subs.isNull()) {
      const n = msgU(subs, sel('count')).toNumber();
      for (let i = 0; i < n; i++) children.push(msgPU(subs, sel('objectAtIndex:'), i));
    }
    rec.sublayers = children.map(addr);
    rec.mask = addr(msgP(l, sel('mask')));
    rec.delegate = ref(msgP(l, sel('delegate')));
    rec.eventDelegate = responds(l, 'eventDelegate') ? ref(msgP(l, sel('eventDelegate'))) : null;
    for (const key of LAYER_KEYS) rec[key] = simpleValue(kvc(l, key)) ?? null;
    const bg = msgP(l, sel('backgroundColor'));
    rec.backgroundColor = bg.isNull() ? null : color(bg);
    for (const key of LAYER_EXTRA_KEYS) rec[key] = simpleValue(kvc(l, key)) ?? null;
    const contents = msgP(l, sel('contents'));
    rec.contents = contents.isNull() ? null : contentsRecord(contents);
    if (isKind(l, C.CATextLayer)) rec.text = textRecord(l);
    if (responds(l, 'textShadowBlur')) {
      const shadowColor = msgP(l, sel('textShadowColor'));
      rec.textShadow = {
        color: shadowColor.isNull() ? null : color(shadowColor),
        offset: simpleValue(kvc(l, 'textShadowOffset')) ?? null,
        blur: simpleValue(kvc(l, 'textShadowBlur')) ?? null,
        hidden: simpleValue(kvc(l, 'textShadowHidden')) ?? null,
      };
    }
    rec.filters = filters(msgP(l, sel('filters')));
    rec.backgroundFilters = filters(msgP(l, sel('backgroundFilters')));
    rec.compositingFilter = filters(msgP(l, sel('compositingFilter')));
    writeLine(rec);
    children.forEach(visit);
  };
  visit(top);
  return layers;
}

// --- triggers -------------------------------------------------------------

let snapshotCount = 0;
const depth = new Map();

function snapshot(springboard, trigger) {
  const id = ++snapshotCount;
  writeLine({
    type: 'snapshot', id, trigger, mediaTime: CACurrentMediaTime(),
    thread: { id: Process.getCurrentThreadId(), isMain: pthread_main_np() === 1 },
    springboard: springboard.toString(),
  });
  const window = msgP(springboard, sel('containerWindow'));
  writeLine({
    type: 'window', snapshot: id, class: window.isNull() ? null : className(object_getClass(window)),
    address: addr(window),
    wid: window.isNull() || !responds(window, 'wid') ? null : msgU32(window, sel('wid')),
    frame: window.isNull() ? null : simpleValue(kvc(window, 'frame')) ?? null,
    layer: window.isNull() || !responds(window, 'layer') ? null : addr(msgP(window, sel('layer'))),
  });
  const graph = dumpGraph(id, springboard);
  const layers = dumpLayers(id, msgP(springboard, sel('layer')));
  writeLine({ type: 'end', snapshot: id, objects: graph.objects, layers, truncated: graph.truncated });
}

function reason(p) {
  if (p.isNull()) return null;
  return isKind(p, C.NSString) ? str(p) : { class: className(object_getClass(p)) };
}

function hook(c, selectorName, describe) {
  const imp = class_getMethodImplementation(c, sel(selectorName)).strip();
  return { imp, selectorName, describe };
}

const hooks = [
  hook(C.LPSpringboard, 'setVisible:slow:forGaming:reason:', args => ({
    visible: !!(args[2].toUInt32() & 0xff), slow: !!(args[3].toUInt32() & 0xff),
    forGaming: !!(args[4].toUInt32() & 0xff), reason: reason(args[5]),
  })),
  hook(C.Springboard, 'setVisible:reason:', args => ({
    visible: !!(args[2].toUInt32() & 0xff), slow: null, forGaming: null,
    reason: reason(args[3]),
  })),
];

const hooked = new Set();
const cleanup = hook(C.Springboard, '_cleanupAfterExitAnimation:openCount:', args => ({
  phase: 'after', openCount: args[3].toUInt32(),
}));
hooked.add(cleanup.imp.toString());
Interceptor.attach(cleanup.imp, {
  onEnter(args) {
    this.self = args[0];
    this.trigger = Object.assign({ method: cleanup.selectorName }, cleanup.describe(args));
  },
  onLeave() {
    try {
      snapshot(this.self, this.trigger);
    } catch (e) {
      send({ type: 'error', message: String(e), stack: e.stack });
    }
  },
});
for (const h of hooks) {
  if (hooked.has(h.imp.toString())) continue;
  hooked.add(h.imp.toString());
  Interceptor.attach(h.imp, {
    onEnter(args) {
      const thread = Process.getCurrentThreadId();
      const d = (depth.get(thread) || 0) + 1;
      depth.set(thread, d);
      this.outer = d === 1;
      if (!this.outer) return;
      try {
        this.self = args[0];
        this.trigger = Object.assign({ method: h.selectorName }, h.describe(args));
        if (!this.trigger.visible) snapshot(this.self, Object.assign({ phase: 'before' }, this.trigger));
      } catch (e) {
        send({ type: 'error', message: String(e), stack: e.stack });
      }
    },
    onLeave() {
      const thread = Process.getCurrentThreadId();
      depth.set(thread, depth.get(thread) - 1);
      if (!this.outer || this.trigger === undefined) return;
      try {
        if (this.trigger.visible) snapshot(this.self, Object.assign({ phase: 'after' }, this.trigger));
      } catch (e) {
        send({ type: 'error', message: String(e), stack: e.stack });
      }
    },
  });
}

if (Process.mainModule.name === 'LaunchPadAgent') {
  // The Swift method: self in x20, the three Booleans in w0 to w2.
  const name = '$s9LaunchPad13LPSpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtF';
  const swiftSetVisible = Process.mainModule.findExportByName(name) ?? Process.mainModule.findSymbolByName(name);
  if (swiftSetVisible === null) throw new Error('not found: ' + name);
  Interceptor.attach(swiftSetVisible, {
    onEnter(args) {
      const thread = Process.getCurrentThreadId();
      const d = (depth.get(thread) || 0) + 1;
      depth.set(thread, d);
      this.outer = d === 1;
      if (!this.outer) return;
      try {
        this.self = this.context.x20;
        this.trigger = {
          method: 'LPSpringboard.setVisible(_:slow:forGaming:reason:)',
          visible: !!(args[0].toUInt32() & 1), slow: !!(args[1].toUInt32() & 1),
          forGaming: !!(args[2].toUInt32() & 1), reason: null,
        };
        if (!this.trigger.visible) snapshot(this.self, Object.assign({ phase: 'before' }, this.trigger));
      } catch (e) {
        send({ type: 'error', message: String(e), stack: e.stack });
      }
    },
    onLeave() {
      const thread = Process.getCurrentThreadId();
      depth.set(thread, depth.get(thread) - 1);
      if (!this.outer || this.trigger === undefined) return;
      try {
        if (this.trigger.visible) snapshot(this.self, Object.assign({ phase: 'after' }, this.trigger));
      } catch (e) {
        send({ type: 'error', message: String(e), stack: e.stack });
      }
    },
  });
}

send({ type: 'file', path });
