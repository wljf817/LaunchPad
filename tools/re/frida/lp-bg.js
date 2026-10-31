// Read the state of the macOS 15 Launchpad's window and background in Dock
// (reference VM) once, at load: the controller's state ivars, the background
// container's filters and rasterization, the background image, the window's
// level, tags, alpha and spaces, and Dock's view of the window list. Exports
// the background image, and window-server captures of the Launchpad window
// and of Dock's desktop wallpaper windows, as PNG files.
// Frida 17 core API only (no Objective-C bridge through REA, REF-ENV-003), as
// ca-anim.js and lp-graph.js.
//
// Load through REA (start_frida_session { mode: "attach", remote }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-bg.js" })
// with Launchpad open or closed. The reading runs once on Dock's main queue;
// wait for the message {type: "done"} before unloading. Optional label: the
// first line of $HOME/frida-gadget/lp-bg-label.txt is copied into the header.
//
// Files in $HOME/frida-gadget/ of the target process, created exclusively:
//   lp-bg-<UTC load time>.jsonl     one "header" line and one "state" line
//     (including Dock's view of the window list and, for every window in
//     it, the spaces CGSCopySpacesForWindows reports and the tags
//     CGSGetWindowTags reports)
//   lp-bg-<UTC load time>-<name>.png  "background" (the background image
//     layer's contents, unchanged), "window" (capture of the Launchpad window,
//     only while open), "wallpaper-<wid>" (capture of each of Dock's desktop
//     wallpaper windows: Dock's windows at the desktop level or one below it)
// Captures use CGSHWCaptureWindowList on Dock's connection with the options
// Dock itself uses for the background (0x11944).
//
// Reading only: nothing is written to Dock's objects, no Launchpad method
// with side effects is called.

'use strict';

const CAPTURE_OPTIONS = 0x11944;

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  const p = Module.findGlobalExportByName(name);
  return p === null ? null : new NativeFunction(p, ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgU32 = new NativeFunction(msgSendPtr, 'uint32', ['pointer', 'pointer']);
const msgVPU = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'uint64']);

const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const CFArrayGetCount = nf(cf, 'CFArrayGetCount', 'long', ['pointer']);
const CFArrayGetValueAtIndex = nf(cf, 'CFArrayGetValueAtIndex', 'pointer', ['pointer', 'long']);
const CFDataGetLength = nf(cf, 'CFDataGetLength', 'long', ['pointer']);
const CFStringCreateWithCString = nf(cf, 'CFStringCreateWithCString', 'pointer', ['pointer', 'pointer', 'uint32']);
const CFURLCreateFromFileSystemRepresentation = nf(cf, 'CFURLCreateFromFileSystemRepresentation', 'pointer', ['pointer', 'pointer', 'long', 'bool']);
const CFCopyDescription = nf(cf, 'CFCopyDescription', 'pointer', ['pointer']);

const cg = Process.getModuleByName('CoreGraphics');
const CGImageGetTypeID = nf(cg, 'CGImageGetTypeID', 'ulong', []);
const CGImageGetWidth = nf(cg, 'CGImageGetWidth', 'size_t', ['pointer']);
const CGImageGetHeight = nf(cg, 'CGImageGetHeight', 'size_t', ['pointer']);
const CGImageGetBitsPerComponent = nf(cg, 'CGImageGetBitsPerComponent', 'size_t', ['pointer']);
const CGImageGetBitsPerPixel = nf(cg, 'CGImageGetBitsPerPixel', 'size_t', ['pointer']);
const CGImageGetBytesPerRow = nf(cg, 'CGImageGetBytesPerRow', 'size_t', ['pointer']);
const CGImageGetAlphaInfo = nf(cg, 'CGImageGetAlphaInfo', 'uint32', ['pointer']);
const CGImageGetBitmapInfo = nf(cg, 'CGImageGetBitmapInfo', 'uint32', ['pointer']);
const CGImageGetColorSpace = nf(cg, 'CGImageGetColorSpace', 'pointer', ['pointer']);
const CGImageGetRenderingIntent = nf(cg, 'CGImageGetRenderingIntent', 'int32', ['pointer']);
const CGImageGetShouldInterpolate = nf(cg, 'CGImageGetShouldInterpolate', 'bool', ['pointer']);
const CGImageIsMask = nf(cg, 'CGImageIsMask', 'bool', ['pointer']);
const CGImageGetUTType = gf('CGImageGetUTType', 'pointer', ['pointer']);
const CGColorSpaceCopyName = nf(cg, 'CGColorSpaceCopyName', 'pointer', ['pointer']);
const CGColorSpaceGetModel = nf(cg, 'CGColorSpaceGetModel', 'int32', ['pointer']);
const CGColorSpaceCopyICCData = nf(cg, 'CGColorSpaceCopyICCData', 'pointer', ['pointer']);
const CGWindowLevelForKey = nf(cg, 'CGWindowLevelForKey', 'int32', ['int32']);
const CGWindowListCopyWindowInfo = nf(cg, 'CGWindowListCopyWindowInfo', 'pointer', ['uint32', 'uint32']);
const CGDisplayBounds = nf(cg, 'CGDisplayBounds', ['double', 'double', 'double', 'double'], ['uint32']);

const CGSGetWindowLevel = gf('CGSGetWindowLevel', 'int32', ['int32', 'uint32', 'pointer']);
const CGSGetWindowTags = gf('CGSGetWindowTags', 'int32', ['int32', 'uint32', 'pointer', 'int32']);
const CGSGetWindowAlpha = gf('CGSGetWindowAlpha', 'int32', ['int32', 'uint32', 'pointer']);
const CGSGetWindowBounds = gf('CGSGetWindowBounds', 'int32', ['int32', 'uint32', 'pointer']);
const CGSWindowIsOrderedIn = gf('CGSWindowIsOrderedIn', 'int32', ['int32', 'uint32', 'pointer']);
const CGSCopySpacesForWindows = gf('CGSCopySpacesForWindows', 'pointer', ['int32', 'int32', 'pointer']);
const CGSGetActiveSpace = gf('CGSGetActiveSpace', 'uint64', ['int32']);
const CGSCopyManagedDisplaySpaces = gf('CGSCopyManagedDisplaySpaces', 'pointer', ['int32']);
const CGSHWCaptureWindowList = gf('CGSHWCaptureWindowList', 'pointer', ['int32', 'pointer', 'uint32', 'uint32']);

const imageIO = Process.findModuleByName('ImageIO') ||
  Module.load('/System/Library/Frameworks/ImageIO.framework/Versions/A/ImageIO');
const CGImageDestinationCreateWithURL = nf(imageIO, 'CGImageDestinationCreateWithURL', 'pointer', ['pointer', 'pointer', 'size_t', 'pointer']);
const CGImageDestinationAddImage = nf(imageIO, 'CGImageDestinationAddImage', 'void', ['pointer', 'pointer', 'pointer']);
const CGImageDestinationFinalize = nf(imageIO, 'CGImageDestinationFinalize', 'bool', ['pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const NSGetSizeAndAlignment = nf(Process.getModuleByName('Foundation'), 'NSGetSizeAndAlignment', 'pointer', ['pointer', 'pointer', 'pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);
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
  const c = objc_getClass(Memory.allocUtf8String(name));
  if (c.isNull()) throw new Error('class not found: ' + name);
  return c;
}

const C = {
  NSString: cls('NSString'),
  NSNumber: cls('NSNumber'),
  NSValue: cls('NSValue'),
  NSArray: cls('NSArray'),
  NSDictionary: cls('NSDictionary'),
};
const cgImageTypeID = CGImageGetTypeID().toString();

// --- numbers (exact shortest decimal, as in ca-anim.js) -------------------

function num(x) {
  if (Number.isFinite(x)) return x;
  if (Number.isNaN(x)) return 'nan';
  return x > 0 ? 'inf' : '-inf';
}

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

// --- values ---------------------------------------------------------------

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

function cfString(p) {
  if (p.isNull()) return null;
  const s = str(p);
  CFRelease(p);
  return s;
}

function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}

function nsString(text) {
  return msgPP(C.NSString, sel('stringWithUTF8String:'), Memory.allocUtf8String(text));
}

function hex(p, size) {
  const bytes = new Uint8Array(p.readByteArray(size));
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

function nsValue(obj) {
  const typePtr = msgP(obj, sel('objCType'));
  const type = typePtr.readUtf8String();
  const sizeBuf = Memory.alloc(16);
  NSGetSizeAndAlignment(typePtr, sizeBuf, sizeBuf.add(8));
  const size = sizeBuf.readU64().toNumber();
  const buf = Memory.alloc(Math.max(size, 1));
  msgVPU(obj, sel('getValue:size:'), buf, size);
  const out = { objCType: type, size, bytes: hex(buf, size) };
  const members = type.replace(/^\{[^=]*=/, '').replace(/\}$/, '');
  if (/^f+$/.test(members)) {
    out.floats = [];
    for (let i = 0; i < members.length; i++) out.floats.push(num(buf.add(i * 4).readFloat()));
  } else if (/^d+$/.test(members.replace(/\{[^=}]*=/g, '').replace(/[{}]/g, ''))) {
    out.doubles = [];
    for (let i = 0; i < size / 8; i++) out.doubles.push(num(buf.add(i * 8).readDouble()));
  }
  return out;
}

// Plain values: NSString, NSNumber (with its objCType), NSValue, NSArray,
// NSDictionary; other objects as {class}.
function plain(obj, depthLeft) {
  if (obj.isNull()) return null;
  if (CFGetTypeID(obj).toString() === cgImageTypeID) return { class: 'CGImage' };
  if (isKind(obj, C.NSString)) return str(obj);
  if (isKind(obj, C.NSNumber)) {
    return { objCType: msgP(obj, sel('objCType')).readUtf8String(), number: num(msgD(obj, sel('doubleValue'))) };
  }
  if (isKind(obj, C.NSValue)) return nsValue(obj);
  if (depthLeft > 0 && isKind(obj, C.NSArray)) {
    const n = msgU(obj, sel('count')).toNumber();
    const out = [];
    for (let i = 0; i < n; i++) out.push(plain(msgPU(obj, sel('objectAtIndex:'), i), depthLeft - 1));
    return out;
  }
  if (depthLeft > 0 && isKind(obj, C.NSDictionary)) {
    const keys = msgP(obj, sel('allKeys'));
    const n = msgU(keys, sel('count')).toNumber();
    const out = {};
    for (let i = 0; i < n; i++) {
      const k = msgPU(keys, sel('objectAtIndex:'), i);
      const v = plain(msgPP(obj, sel('objectForKey:'), k), depthLeft - 1);
      out[isKind(k, C.NSString) ? str(k) : String(plain(k, 0))] = v;
    }
    return out;
  }
  return { class: className(obj) };
}

// --- Dock -----------------------------------------------------------------

const dock = Process.mainModule;
const slide = dock.base.sub(ptr('0x100000000'));
function dockAddr(fileAddr) {
  return ptr(fileAddr).add(slide);
}

const springboardGlobal = dockAddr('0x100448168');
const dockBarGlobal = dockAddr('0x100448138');
const spacesGlobal = dockAddr('0x100448178');
const dockGlobalsGlobal = dockAddr('0x100448200');

// --- output ---------------------------------------------------------------

function utcStamp(d) {
  return d.toISOString().replace(/[-:]/g, '');
}

const loadDate = new Date();
const dir = getenv(Memory.allocUtf8String('HOME')).readUtf8String() + '/frida-gadget/';
const base = 'lp-bg-' + utcStamp(loadDate);
const path = dir + base + '.jsonl';
const file = new File(path, 'wx');

function writeLine(obj) {
  const text = JSON.stringify(obj, (k, v) => typeof v === 'number' ? NUMBER_MARK + exactNumber(v) : v);
  file.write(text.replace(NUMBER_TEXT, '$1') + '\n');
  file.flush();
}

let label = null;
try {
  label = File.readAllText(dir + 'lp-bg-label.txt').split('\n')[0];
} catch (e) {
  label = null;
}

writeLine({ type: 'header', frida: Frida.version, pid: Process.id, mediaTime: CACurrentMediaTime(), utc: loadDate.toISOString(), label });

// --- reading --------------------------------------------------------------

function imageInfo(img) {
  const space = CGImageGetColorSpace(img);
  const out = {
    width: CGImageGetWidth(img).toNumber(),
    height: CGImageGetHeight(img).toNumber(),
    bitsPerComponent: CGImageGetBitsPerComponent(img).toNumber(),
    bitsPerPixel: CGImageGetBitsPerPixel(img).toNumber(),
    bytesPerRow: CGImageGetBytesPerRow(img).toNumber(),
    alphaInfo: CGImageGetAlphaInfo(img),
    bitmapInfo: '0x' + CGImageGetBitmapInfo(img).toString(16),
    renderingIntent: CGImageGetRenderingIntent(img),
    shouldInterpolate: !!CGImageGetShouldInterpolate(img),
    isMask: !!CGImageIsMask(img),
    utType: CGImageGetUTType === null ? undefined : str(CGImageGetUTType(img)),
    colorSpace: null,
  };
  if (!space.isNull()) {
    const icc = CGColorSpaceCopyICCData(space);
    out.colorSpace = {
      name: cfString(CGColorSpaceCopyName(space)),
      model: CGColorSpaceGetModel(space),
      iccBytes: icc.isNull() ? null : CFDataGetLength(icc).toNumber(),
      description: cfString(CFCopyDescription(space)),
    };
    if (!icc.isNull()) CFRelease(icc);
  }
  return out;
}

function exportPNG(img, name) {
  const p = dir + base + '-' + name + '.png';
  const bytes = Memory.allocUtf8String(p);
  const url = CFURLCreateFromFileSystemRepresentation(NULL, bytes, p.length, 0);
  const type = CFStringCreateWithCString(NULL, Memory.allocUtf8String('public.png'), 0x08000100);
  const dest = CGImageDestinationCreateWithURL(url, type, 1, NULL);
  let ok = false;
  if (!dest.isNull()) {
    CGImageDestinationAddImage(dest, img, NULL);
    ok = !!CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CFRelease(type);
  CFRelease(url);
  return { path: p, ok };
}

function capture(cid, wid, name) {
  if (CGSHWCaptureWindowList === null) return { error: 'CGSHWCaptureWindowList not found' };
  const list = Memory.alloc(4);
  list.writeU32(wid);
  const t0 = CACurrentMediaTime();
  const arr = CGSHWCaptureWindowList(cid, list, 1, CAPTURE_OPTIONS);
  const t1 = CACurrentMediaTime();
  if (arr.isNull()) return { wid, error: 'null result', seconds: t1 - t0 };
  const n = CFArrayGetCount(arr).toNumber();
  const out = { wid, options: '0x' + CAPTURE_OPTIONS.toString(16), seconds: t1 - t0, count: n };
  if (n > 0) {
    const img = CFArrayGetValueAtIndex(arr, 0);
    if (CFGetTypeID(img).toString() === cgImageTypeID) {
      out.image = imageInfo(img);
      out.export = exportPNG(img, name);
    }
  }
  return out;
}

function windowServerState(cid, wid) {
  const out = { wid };
  const buf = Memory.alloc(64);
  if (CGSGetWindowLevel !== null) {
    buf.writeS32(0);
    out.levelError = CGSGetWindowLevel(cid, wid, buf);
    out.level = buf.readS32();
  }
  if (CGSGetWindowTags !== null) {
    buf.writeU64(0);
    buf.add(8).writeU64(0);
    out.tagsError = CGSGetWindowTags(cid, wid, buf, 0x40);
    out.tags = '0x' + buf.readU64().toString(16);
  }
  if (CGSGetWindowAlpha !== null) {
    buf.writeFloat(-1);
    out.alphaError = CGSGetWindowAlpha(cid, wid, buf);
    out.alpha = num(buf.readFloat());
  }
  if (CGSGetWindowBounds !== null) {
    out.boundsError = CGSGetWindowBounds(cid, wid, buf);
    out.bounds = [0, 1, 2, 3].map(i => num(buf.add(i * 8).readDouble()));
  }
  if (CGSWindowIsOrderedIn !== null) {
    buf.writeU8(0xff);
    out.orderedInError = CGSWindowIsOrderedIn(cid, wid, buf);
    out.orderedIn = buf.readU8();
  }
  if (CGSCopySpacesForWindows !== null) {
    const n = msgPU(cls('NSNumber'), sel('numberWithUnsignedInt:'), wid);
    const a = msgPP(C.NSArray, sel('arrayWithObject:'), n);
    const spaces = CGSCopySpacesForWindows(cid, 7, a);
    out.spaces = spaces.isNull() ? null : plain(spaces, 2);
    if (!spaces.isNull()) CFRelease(spaces);
  }
  return out;
}

function filterRecord(f) {
  const out = { class: className(f), address: f.toString() };
  if (responds(f, 'name')) out.name = str(msgP(f, sel('name')));
  if (responds(f, 'type')) out.type = str(msgP(f, sel('type')));
  if (responds(f, 'isEnabled')) out.enabled = !!msgB(f, sel('isEnabled'));
  if (responds(f, 'cachesInputImage')) out.cachesInputImage = !!msgB(f, sel('cachesInputImage'));
  out.values = {};
  for (const k of ['inputRadius', 'inputHardEdges', 'inputAmount', 'inputColorMatrix']) {
    out.values[k] = plain(msgPP(f, sel('valueForKey:'), nsString(k)), 1);
  }
  out.description = str(msgP(f, sel('description')));
  return out;
}

function layerRecord(l) {
  if (l.isNull()) return null;
  const rect = name => plain(msgPP(l, sel('valueForKey:'), nsString(name)), 0);
  const out = {
    class: className(l), address: l.toString(),
    frame: rect('frame'), bounds: rect('bounds'), position: rect('position'),
    opacity: num(msgF(l, sel('opacity'))),
    hidden: !!msgB(l, sel('isHidden')),
    shouldRasterize: !!msgB(l, sel('shouldRasterize')),
    rasterizationScale: num(msgD(l, sel('rasterizationScale'))),
    contentsScale: num(msgD(l, sel('contentsScale'))),
    contentsGravity: str(msgP(l, sel('contentsGravity'))),
    minificationFilter: str(msgP(l, sel('minificationFilter'))),
    magnificationFilter: str(msgP(l, sel('magnificationFilter'))),
    sublayers: 0,
  };
  const subs = msgP(l, sel('sublayers'));
  out.sublayers = subs.isNull() ? 0 : msgU(subs, sel('count')).toNumber();
  const filters = msgP(l, sel('filters'));
  out.filters = filters.isNull() ? null : [];
  if (!filters.isNull()) {
    const n = msgU(filters, sel('count')).toNumber();
    for (let i = 0; i < n; i++) out.filters.push(filterRecord(msgPU(filters, sel('objectAtIndex:'), i)));
  }
  const bf = msgP(l, sel('backgroundFilters'));
  out.backgroundFilters = bf.isNull() ? null : msgU(bf, sel('count')).toNumber();
  const contents = msgP(l, sel('contents'));
  if (contents.isNull()) {
    out.contents = null;
  } else if (CFGetTypeID(contents).toString() === cgImageTypeID) {
    out.contents = imageInfo(contents);
  } else {
    out.contents = { class: className(contents) };
  }
  return out;
}

function read() {
  const sb = springboardGlobal.readPointer();
  const dockGlobals = dockGlobalsGlobal.readPointer();
  const cid = msgU32(dockGlobals, sel('dockConnection'));
  const flags = [sb.add(0x134).readU8(), sb.add(0x135).readU8(), sb.add(0x136).readU8()];
  const win = sb.add(0x8).readPointer();
  const wid = msgU32(win, sel('wid'));
  const dockBar = dockBarGlobal.readPointer();
  const dockWin = msgP(dockBar, sel('window'));
  const dockWid = dockWin.isNull() ? null : msgU32(dockWin, sel('wid'));
  const display = msgU32(sb, sel('display'));
  const spaces = spacesGlobal.readPointer();
  const space = msgPU(spaces, sel('currentSpaceForDisplay:'), display);
  const C_ = sb.add(0xe0).readPointer();
  const D = sb.add(0xe8).readPointer();
  const filtersIvar = sb.add(0xf0).readPointer();

  const state = {
    type: 'state', mediaTime: CACurrentMediaTime(),
    springboard: sb.toString(),
    visible: flags[0] & 1,
    groupShown: !!msgB(sb, sel('groupShown')),
    flagBytes: flags.map(b => '0x' + b.toString(16)),
    desktopStale: (flags[1] >> 3) & 1,
    forcedDockHidden: (flags[1] >> 7) & 1,
    windowIsOrderedOn: flags[2] & 1,
    openCount: sb.add(0x100).readU32(),
    currentFilter: sb.add(0xf8).readS64().toNumber(),
    visibility: num(sb.add(0x120).readFloat()),
    desktopLastUUID: str(sb.add(0x118).readPointer()),
    display,
    displayBounds: CGDisplayBounds(display).map(num),
    currentSpace: space.isNull() ? null : {
      class: className(space),
      uuid: responds(space, 'uuid') ? str(msgP(space, sel('uuid'))) : null,
      spid: responds(space, 'spid') ? msgU(space, sel('spid')).toNumber() : null,
    },
    activeSpace: CGSGetActiveSpace === null ? null : CGSGetActiveSpace(cid).toNumber(),
    dockConnection: cid,
    window: windowServerState(cid, wid),
    dockBarWindow: dockWid === null ? null : windowServerState(cid, dockWid),
    desktopLevel: CGWindowLevelForKey(2),
    desktopContainer: layerRecord(C_),
    desktopLayer: layerRecord(D),
    desktopFiltersIvar: filtersIvar.isNull() ? null : [],
  };
  // Window of the root layer: is the overlay container attached?
  const L = sb.add(0x10).readPointer();
  state.overlayAttached = !msgP(L, sel('superlayer')).isNull();
  state.overlayOpacity = num(msgF(L, sel('opacity')));
  if (!filtersIvar.isNull()) {
    const n = msgU(filtersIvar, sel('count')).toNumber();
    for (let i = 0; i < n; i++) state.desktopFiltersIvar.push(msgPU(filtersIvar, sel('objectAtIndex:'), i).toString());
  }
  if (CGSCopyManagedDisplaySpaces !== null) {
    const m = CGSCopyManagedDisplaySpaces(cid);
    state.managedDisplaySpaces = m.isNull() ? null : plain(m, 6);
    if (!m.isNull()) CFRelease(m);
  }
  // Dock's view of the window list (all windows).
  const list = CGWindowListCopyWindowInfo(0, 0);
  state.windowList = list.isNull() ? null : plain(list, 3);
  if (!list.isNull()) CFRelease(list);

  // Spaces of every window in the list, one CGSCopySpacesForWindows call per
  // window (mask 7), to compare the Launchpad window with other windows.
  if (state.windowList !== null && CGSCopySpacesForWindows !== null) {
    state.spacesByWindow = {};
    for (const w of state.windowList) {
      if (w === null || typeof w !== 'object' || !w.kCGWindowNumber) continue;
      const wid = w.kCGWindowNumber.number;
      const n = msgPU(C.NSNumber, sel('numberWithUnsignedInt:'), wid);
      const a = msgPP(C.NSArray, sel('arrayWithObject:'), n);
      const spaces = CGSCopySpacesForWindows(cid, 7, a);
      state.spacesByWindow[wid] = spaces.isNull() ? null : plain(spaces, 2);
      if (!spaces.isNull()) CFRelease(spaces);
    }
  }
  // Tags of every window in the list, as CGSGetWindowTags reports them on
  // Dock's connection.
  if (state.windowList !== null && CGSGetWindowTags !== null) {
    state.tagsByWindow = {};
    const buf = Memory.alloc(16);
    for (const w of state.windowList) {
      if (w === null || typeof w !== 'object' || !w.kCGWindowNumber) continue;
      const wid = w.kCGWindowNumber.number;
      buf.writeU64(0);
      buf.add(8).writeU64(0);
      const err = CGSGetWindowTags(cid, wid, buf, 0x40);
      state.tagsByWindow[wid] = err === 0 ? '0x' + buf.readU64().toString(16) : { error: err };
    }
  }

  // Exports.
  state.exports = {};
  if (!D.isNull()) {
    const contents = msgP(D, sel('contents'));
    if (!contents.isNull() && CFGetTypeID(contents).toString() === cgImageTypeID) {
      state.exports.background = exportPNG(contents, 'background');
    }
  }
  if (state.visible) state.exports.window = capture(cid, wid, 'window');
  const wallpapers = [];
  if (state.windowList !== null) {
    for (const w of state.windowList) {
      if (w === null || typeof w !== 'object') continue;
      const owner = w.kCGWindowOwnerPID;
      const layer = w.kCGWindowLayer;
      // The wallpaper windows sit at the desktop level with sublevel -1.
      if (owner && owner.number === Process.id && layer &&
          (layer.number === state.desktopLevel || layer.number === state.desktopLevel - 1)) {
        wallpapers.push(w.kCGWindowNumber.number);
      }
    }
  }
  state.exports.wallpapers = wallpapers.map(w => capture(cid, w, 'wallpaper-' + w));
  writeLine(state);
}

const readCallback = new NativeCallback(() => {
  try {
    read();
    send({ type: 'done', path });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
    send({ type: 'done', path, failed: true });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, readCallback);
send({ type: 'file', path });
