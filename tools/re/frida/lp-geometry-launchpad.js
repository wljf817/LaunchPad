// Record the grid geometry of this project's background process (LaunchPadAgent, macOS 26
// comparison VM) each time -[Springboard layout] runs, in the same shape as the "layout" lines of
// lp-geometry.js, so the two can be compared.
// Frida 17 core API only (no Objective-C bridge), as lp-geometry.js.
//
// Load it with frida-gadget when the agent starts: put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-geometry-launchpad.js"}}
// in frida-gadget.config next to the gadget and start the agent with DYLD_INSERT_LIBRARIES set to the
// gadget (the agent keeps the get-task-allow entitlement and has no hardened runtime).
//
// File: $HOME/frida-gadget/lp-geometry-launchpad-<UTC load time>.jsonl in the target process,
// created exclusively, every line flushed as written.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header  frida, pid, utc
//   layout  at the leave of Springboard.layout() (the Swift method): springboard (deferLayout, iconSize, miniIconSize,
//           layer frame, totalScreenBounds, getZoomFactorFromPrefs), dock (the rectangle and
//           orientation the window server reports, read in this process), pager (pager layer frame, bounds,
//           margins, adjusted margins, zoomFactor, zoomStyle, layoutRTL, scroll layer frame and
//           bounds), pages (grid layer frame, clip and items layer frames, rows, columns, rowHeight,
//           columnWidth, numberOfItems, every item layer's position, bounds and hidden)
//
// Nothing is written to the process's objects.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const RECT = ['double', 'double', 'double', 'double'];
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgI = new NativeFunction(msgSendPtr, 'int64', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, RECT, ['pointer', 'pointer']);
const msgPoint = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);

const sky = Process.getModuleByName('SkyLight');
const SLSMainConnectionID = nf(sky, 'SLSMainConnectionID', 'int', []);
const SLSGetDockRectWithOrientation = nf(sky, 'SLSGetDockRectWithOrientation', 'int', ['int', 'pointer', 'pointer', 'pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
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
function className(p) {
  return p.isNull() ? null : object_getClassName(p).readUtf8String();
}
// Swift stored properties appear as ivars named like the property.
function ivarPtr(obj, clsName, name) {
  const iv = class_getInstanceVariable(cls(clsName), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + clsName + '.' + name);
  return obj.add(ivar_getOffset(iv));
}
function rect(obj, name) {
  return msgRect(obj, sel(name));
}
function count(array) {
  return array.isNull() ? 0 : msgU(array, sel('count')).toNumber();
}
function at(array, i) {
  return msgPU(array, sel('objectAtIndex:'), i);
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');
const file = new File(`${home}/frida-gadget/lp-geometry-launchpad-${utc}.jsonl`, 'wx');
function writeLine(rec) {
  rec.t = CACurrentMediaTime();
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}
writeLine({ type: 'header', frida: Frida.version, pid: Process.id, utc });

function dockState() {
  const r = Memory.alloc(32);
  const reason = Memory.alloc(4);
  const o = Memory.alloc(4);
  SLSGetDockRectWithOrientation(SLSMainConnectionID(), r, reason, o);
  return { rect: [0, 1, 2, 3].map(i => r.add(8 * i).readDouble()), orientation: o.readS32() };
}

function gridState(grid) {
  const itemLayers = msgP(grid, sel('itemLayers'));
  const layers = [];
  for (let i = 0; i < count(itemLayers); i++) {
    const l = at(itemLayers, i);
    layers.push({ class: className(l), position: msgPoint(l, sel('position')), bounds: rect(l, 'bounds'), hidden: !!msgB(l, sel('isHidden')) });
  }
  return {
    class: className(grid),
    frame: rect(grid, 'frame'),
    clipFrame: rect(msgP(grid, sel('clipLayer')), 'frame'),
    itemsFrame: rect(msgP(grid, sel('itemsLayer')), 'frame'),
    rows: ivarPtr(grid, 'ECGridLayer', 'rows').readS64().toNumber(),
    columns: ivarPtr(grid, 'ECGridLayer', 'columns').readS64().toNumber(),
    rowHeight: msgU(grid, sel('rowHeight')).toNumber(),
    columnWidth: msgU(grid, sel('columnWidth')).toNumber(),
    numberOfItems: ivarPtr(grid, 'ECGridLayer', 'numberOfItems').readU64().toNumber(),
    itemLayers: layers,
  };
}

function layoutRecord(sb) {
  const component = ivarPtr(sb, 'Springboard', 'springboard').readPointer();
  const pager = msgP(component, sel('pager'));
  const pagerLayer = msgP(pager, sel('layer'));
  const pages = msgP(pager, sel('pages'));
  const pageStates = [];
  for (let i = 0; i < count(pages); i++) {
    const grid = msgP(at(pages, i), sel('layer'));
    pageStates.push(grid.isNull() ? null : gridState(grid));
  }
  const scroll = msgP(pagerLayer, sel('scrollLayer'));
  return {
    type: 'layout',
    springboard: {
      class: className(sb),
      deferLayout: !!msgB(sb, sel('deferLayout')),
      iconSize: ivarPtr(sb, 'Springboard', 'iconSize').readU64().toNumber(),
      miniIconSize: ivarPtr(sb, 'Springboard', 'miniIconSize').readU64().toNumber(),
      layerFrame: rect(msgP(sb, sel('layer')), 'frame'),
      totalScreenBounds: rect(sb, 'totalScreenBounds'),
      zoomFactorFromPrefs: msgD(sb, sel('getZoomFactorFromPrefs')),
    },
    dock: dockState(),
    pager: {
      frame: rect(pagerLayer, 'frame'),
      bounds: rect(pagerLayer, 'bounds'),
      margins: ['leftMargin', 'rightMargin', 'topMargin', 'bottomMargin'].map(n => msgD(pagerLayer, sel(n))),
      adjusted: ['adjustedLeftMargin', 'adjustedRightMargin', 'adjustedTopMargin', 'adjustedBottomMargin'].map(n => msgD(pagerLayer, sel(n))),
      zoomFactor: msgD(pagerLayer, sel('zoomFactor')),
      zoomStyle: msgI(pagerLayer, sel('zoomStyle')).toNumber(),
      scroll: { frame: rect(scroll, 'frame'), bounds: rect(scroll, 'bounds') },
    },
    pages: pageStates,
  };
}

// The Swift method, not its Objective-C entry: the controller calls it from Swift directly. Its
// self is in x20 (Swift's self register).
const swiftLayoutName = '$s9LaunchPad11SpringboardC6layoutyyF';
const main = Process.mainModule;
const springboardLayout = main.findExportByName(swiftLayoutName) ?? main.findSymbolByName(swiftLayoutName);
if (springboardLayout === null) throw new Error('not found: ' + swiftLayoutName);
Interceptor.attach(springboardLayout, {
  onEnter() {
    this.sb = this.context.x20;
  },
  onLeave() {
    try {
      writeLine(layoutRecord(this.sb));
    } catch (e) {
      writeLine({ type: 'error', where: 'layout', message: e.message });
    }
  },
});
