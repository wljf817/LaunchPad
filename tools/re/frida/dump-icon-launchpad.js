// Save the icon an app's item layer shows in this project's background process (LaunchPadAgent,
// macOS 26 comparison VM), to compare it with the image the same IconServices calls give in that
// system (grid spec, "宿主系统的图标"; REF-GRID-012, REF-DEV-021). Frida 17 core API only.
//
// Load it with frida-gadget when the agent starts, in script mode (frida-gadget.config next to the
// gadget, as lp-geometry-launchpad.js), then open Launchpad. As the Swift method
// Springboard.setVisible(_:slow:forGaming:reason:) returns from an open (on the main thread), the
// script walks every loaded page's item layers and writes the icon layer's contents of each app
// whose title is in TITLES as $HOME/frida-gadget/dump-icon-<title>-<width>.png, and the list of
// titles and contents classes it saw as $HOME/frida-gadget/dump-icon-<UTC load time>.json. Only the
// first open is dumped. Nothing is written to the process's objects.

'use strict';

const TITLES = ['计算器', 'Calculator'];

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGImageGetTypeID = nf(cg, 'CGImageGetTypeID', 'ulong', []);
const CGImageGetWidth = nf(cg, 'CGImageGetWidth', 'ulong', ['pointer']);
const io = Process.getModuleByName('ImageIO');
const CGImageDestinationCreateWithURL = nf(io, 'CGImageDestinationCreateWithURL', 'pointer', ['pointer', 'pointer', 'ulong', 'pointer']);
const CGImageDestinationAddImage = nf(io, 'CGImageDestinationAddImage', 'void', ['pointer', 'pointer', 'pointer']);
const CGImageDestinationFinalize = nf(io, 'CGImageDestinationFinalize', 'bool', ['pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);
const cgImageType = CGImageGetTypeID().toString();

function sel(name) {
  return sel_registerName(Memory.allocUtf8String(name));
}
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
function nsString(text) {
  return msgPP(cls('NSString'), sel('stringWithUTF8String:'), Memory.allocUtf8String(text));
}
function str(ns) {
  return ns.isNull() ? null : msgP(ns, sel('UTF8String')).readUtf8String();
}
function className(p) {
  return p.isNull() ? null : object_getClassName(p).readUtf8String();
}
function each(array, f) {
  if (array.isNull()) return;
  const n = msgU(array, sel('count')).toNumber();
  for (let i = 0; i < n; i++) f(msgPU(array, sel('objectAtIndex:'), i));
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');

function writePNG(image, path) {
  const url = msgPP(cls('NSURL'), sel('fileURLWithPath:'), nsString(path));
  const dest = CGImageDestinationCreateWithURL(url, nsString('public.png'), 1, NULL);
  if (dest.isNull()) return false;
  CGImageDestinationAddImage(dest, image, NULL);
  const ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  return ok;
}

function dump(sb) {
  const iv = class_getInstanceVariable(cls('Springboard'), Memory.allocUtf8String('springboard'));
  const component = sb.add(ivar_getOffset(iv)).readPointer();
  const seen = [];
  each(msgP(msgP(component, sel('pager')), sel('pages')), page => {
    const grid = msgP(page, sel('layer'));
    if (grid.isNull()) return;
    each(msgP(grid, sel('itemLayers')), itemLayer => {
      const title = str(msgP(itemLayer, sel('title')));
      const icon = msgP(itemLayer, sel('icon'));
      const isImage = !icon.isNull() && CFGetTypeID(icon).toString() === cgImageType;
      const rec = { class: className(itemLayer), title, contents: icon.isNull() ? null : (isImage ? 'CGImage' : className(icon)) };
      if (isImage) rec.width = CGImageGetWidth(icon).toNumber();
      if (isImage && TITLES.includes(title)) {
        rec.file = `${home}/frida-gadget/dump-icon-${title}-${rec.width}.png`;
        rec.written = writePNG(icon, rec.file);
      }
      seen.push(rec);
    });
  });
  const f = new File(`${home}/frida-gadget/dump-icon-${utc}.json`, 'wx');
  f.write(JSON.stringify(seen, null, 1));
  f.close();
}

const name = '$s9LaunchPad11SpringboardC10setVisible_4slow9forGaming6reasonySb_S2bSSSgtF';
const main = Process.mainModule;
const target = main.findExportByName(name) ?? main.findSymbolByName(name);
if (target === null) throw new Error('not found: ' + name);
let done = false;
Interceptor.attach(target, {
  onEnter(args) {
    this.sb = this.context.x20;
    this.visible = (args[0].toUInt32() & 1) === 1;
  },
  onLeave() {
    if (done || !this.visible) return;
    done = true;
    dump(this.sb);
  },
});
