// Record the grid geometry of the macOS 15 Launchpad in Dock (reference VM):
// the values -[Springboard layout] reads and sets each time it runs, and the
// results of the class methods that compute the icon size over tables of
// inputs.
// Frida 17 core API only (no Objective-C bridge), as lp-loading.js.
//
// Load it with frida-gadget at Dock's start to see the layout at -start too:
// put
//   {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/lp-geometry.js"}}
// in frida-gadget.config, restart Dock with the gadget
// (open ~/frida-gadget/restart-dock-with-gadget.command in the VM), and
// restore the listening config afterwards. It can also be loaded through REA
// into a running Dock; then only later layouts are seen.
//
// File: $HOME/frida-gadget/lp-geometry-<UTC load time>.jsonl in the target
// process, created exclusively, every line flushed as written.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds:
//   header    frida, pid, utc, dockBase
//   layout    at the leave of -[Springboard layout], on the main thread:
//             springboard (_deferLayout, _iconSize, _miniIconSize, layer frame,
//             totalScreenBounds, getZoomFactorFromPrefs, showsDock), dock
//             (DockBar tileSize, desiredTileSize, distanceTop, distanceBottom,
//             distanceSides, tileInset, barOrientation, display notchBounds),
//             pager (pager layer frame, bounds, margins, adjusted margins,
//             zoomFactor, zoomStyle, pagerControlVisibility, currentPageIndex,
//             layoutRTL, scroll layer frame and bounds.origin), pages (grid
//             layer frame and bounds, clip and items layer frames, rows,
//             columns, rowHeight, columnWidth, rowSpacing, columnSpacing,
//             numberOfItems, offset, and every item layer's class, position,
//             bounds and hidden)
//   font      once, after the first layout: ECSBEnvironment's labelFontType,
//             labelFontSize and label font (PostScript name, size, ascent,
//             descent, leading)
//   table     once, after the first layout, off the main thread: one line per
//             call of a class method ("fn"), with its inputs ("in") and
//             outputs ("out"); the lines end with {"type": "tableDone"}. Skipped
//             when $HOME/frida-gadget/lp-geometry-no-tables exists.
//
// The class methods compute values only; the script calls them with its own
// inputs and reads Dock's objects without writing to them.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const RECT = ['double', 'double', 'double', 'double'];
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgI = new NativeFunction(msgSendPtr, 'int64', ['pointer', 'pointer']);
const msgRect = new NativeFunction(msgSendPtr, RECT, ['pointer', 'pointer']);
const msgPoint = new NativeFunction(msgSendPtr, ['double', 'double'], ['pointer', 'pointer']);

// Class methods, with the argument types of their Objective-C type encodings.
const calcSpringboard = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer', RECT, 'float',
  'double', 'double', 'double', 'double', 'int64', 'double', 'uint64', 'uint64']);
const calcGrid = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer', RECT, 'float', 'uint64', 'uint64']);
const calcGridFrame = calcGrid;
const calcItem = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer', RECT, 'float']);
const calcItemFrame = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', RECT, 'float']);
const miniIconSize = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer', RECT, 'float']);
const imageGridIconSize = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer', RECT, 'int64', 'int64', 'uint64']);

const ct = Process.getModuleByName('CoreText');
const CTFontGetAscent = nf(ct, 'CTFontGetAscent', 'double', ['pointer']);
const CTFontGetDescent = nf(ct, 'CTFontGetDescent', 'double', ['pointer']);
const CTFontGetLeading = nf(ct, 'CTFontGetLeading', 'double', ['pointer']);
const CTFontGetSize = nf(ct, 'CTFontGetSize', 'double', ['pointer']);
const CTFontCopyPostScriptName = nf(ct, 'CTFontCopyPostScriptName', 'pointer', ['pointer']);
const CFRelease = nf(Process.getModuleByName('CoreFoundation'), 'CFRelease', 'void', ['pointer']);
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
function str(ns) {
  if (ns.isNull()) return null;
  return msgP(ns, sel('UTF8String')).readUtf8String();
}
function className(p) {
  return p.isNull() ? null : object_getClassName(p).readUtf8String();
}
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
const path = `${home}/frida-gadget/lp-geometry-${utc}.jsonl`;
const file = new File(path, 'wx');
function writeLine(rec) {
  rec.t = CACurrentMediaTime();
  file.write(JSON.stringify(rec) + '\n');
  file.flush();
}

const dock = Process.getModuleByName('Dock');
writeLine({ type: 'header', frida: Frida.version, pid: Process.id, utc, dockBase: dock.base.toString() });

// The Dock bar object (Dock's global, the one -[Springboard layout] reads).
const dockBarGlobal = dock.base.add(0x448138);

function dockState() {
  const bar = dockBarGlobal.readPointer();
  if (bar.isNull()) return null;
  const display = msgP(bar, sel('display'));
  return {
    class: className(bar),
    tileSize: msgF(bar, sel('tileSize')),
    desiredTileSize: msgF(bar, sel('desiredTileSize')),
    distanceTop: msgF(bar, sel('distanceTop')),
    distanceBottom: msgF(bar, sel('distanceBottom')),
    distanceSides: msgF(bar, sel('distanceSides')),
    tileInset: msgF(bar, sel('tileInset')),
    barOrientation: msgI(bar, sel('barOrientation')).toNumber(),
    display: display.isNull() ? null : { class: className(display), notchBounds: rect(display, 'notchBounds') },
  };
}

function pagerState(pagerLayer) {
  const scroll = ivarPtr(pagerLayer, 'ECPagerLayer', '_scrollLayer').readPointer();
  return {
    class: className(pagerLayer),
    frame: rect(pagerLayer, 'frame'),
    bounds: rect(pagerLayer, 'bounds'),
    margins: ['_leftMargin', '_rightMargin', '_topMargin', '_bottomMargin'].map(n => ivarPtr(pagerLayer, 'ECPagerLayer', n).readDouble()),
    adjusted: ['adjustedLeftMargin', 'adjustedRightMargin', 'adjustedTopMargin', 'adjustedBottomMargin'].map(n => msgD(pagerLayer, sel(n))),
    zoomFactor: ivarPtr(pagerLayer, 'ECSBLayer', '_zoomFactor').readDouble(),
    zoomStyle: ivarPtr(pagerLayer, 'ECSBLayer', '_zoomStyle').readS64().toNumber(),
    pagerControlVisibility: ivarPtr(pagerLayer, 'ECPagerLayer', '_pagerControlVisibility').readS64().toNumber(),
    currentPageIndex: ivarPtr(pagerLayer, 'ECPagerLayer', '_currentPageIndex').readU64().toNumber(),
    layoutRTL: ivarPtr(pagerLayer, 'ECPagerLayer', '_layoutRTL').readU8() !== 0,
    scroll: scroll.isNull() ? null : { frame: rect(scroll, 'frame'), bounds: rect(scroll, 'bounds') },
  };
}

function gridState(grid) {
  const items = ivarPtr(grid, 'ECGridLayer', '_itemsLayer').readPointer();
  const clip = ivarPtr(grid, 'ECGridLayer', '_clipLayer').readPointer();
  const itemLayers = ivarPtr(grid, 'ECGridLayer', '_itemLayers').readPointer();
  const layers = [];
  for (let i = 0; i < count(itemLayers); i++) {
    const l = at(itemLayers, i);
    layers.push({ class: className(l), position: msgPoint(l, sel('position')), bounds: rect(l, 'bounds'), hidden: !!msgB(l, sel('isHidden')) });
  }
  return {
    class: className(grid),
    frame: rect(grid, 'frame'),
    bounds: rect(grid, 'bounds'),
    clipFrame: clip.isNull() ? null : rect(clip, 'frame'),
    itemsFrame: items.isNull() ? null : rect(items, 'frame'),
    itemsBounds: items.isNull() ? null : rect(items, 'bounds'),
    rows: ivarPtr(grid, 'ECGridLayer', '_rows').readS64().toNumber(),
    columns: ivarPtr(grid, 'ECGridLayer', '_columns').readS64().toNumber(),
    rowHeight: ivarPtr(grid, 'ECGridLayer', '_rowHeight').readU64().toNumber(),
    columnWidth: ivarPtr(grid, 'ECGridLayer', '_columnWidth').readU64().toNumber(),
    rowSpacing: ivarPtr(grid, 'ECGridLayer', '_rowSpacing').readU64().toNumber(),
    columnSpacing: ivarPtr(grid, 'ECGridLayer', '_columnSpacing').readU64().toNumber(),
    numberOfItems: ivarPtr(grid, 'ECGridLayer', '_numberOfItems').readU64().toNumber(),
    autoCalcSizes: ivarPtr(grid, 'ECGridLayer', '_autoCalcSizes').readU8() !== 0,
    offset: className(grid) === 'ECSBGridLayer' ? ivarPtr(grid, 'ECSBGridLayer', '_offset').readDouble() : null,
    itemLayers: layers,
  };
}

function layoutRecord(sb) {
  const component = ivarPtr(sb, 'Springboard', '_springboard').readPointer();
  const pager = msgP(component, sel('pager'));
  const pagerLayer = msgP(pager, sel('layer'));
  const pages = msgP(pager, sel('pages'));
  const pageStates = [];
  for (let i = 0; i < count(pages); i++) {
    const page = at(pages, i);
    const grid = msgP(page, sel('layer'));
    pageStates.push(grid.isNull() ? null : gridState(grid));
  }
  const layer = ivarPtr(sb, 'Springboard', '_layer').readPointer();
  return {
    type: 'layout',
    springboard: {
      class: className(sb),
      deferLayout: ivarPtr(sb, 'Springboard', '_deferLayout').readU8() !== 0,
      iconSize: ivarPtr(sb, 'Springboard', '_iconSize').readU64().toNumber(),
      miniIconSize: ivarPtr(sb, 'Springboard', '_miniIconSize').readU64().toNumber(),
      layerFrame: rect(layer, 'frame'),
      totalScreenBounds: rect(sb, 'totalScreenBounds'),
      zoomFactorFromPrefs: msgD(sb, sel('getZoomFactorFromPrefs')),
      showsDock: !!msgB(sb, sel('showsDock')),
      rows: ivarPtr(sb, 'Springboard', '_numberOfRowsPerPage').readS64().toNumber(),
      columns: ivarPtr(sb, 'Springboard', '_numberOfColumnsPerPage').readS64().toNumber(),
    },
    dock: dockState(),
    pager: pagerState(pagerLayer),
    pages: pageStates,
  };
}

function fontRecord() {
  const env = msgP(cls('ECSBEnvironment'), sel('shared'));
  const font = msgP(env, sel('labelFont'));
  const name = CTFontCopyPostScriptName(font);
  const rec = {
    type: 'font',
    labelFontType: ivarPtr(env, 'ECSBEnvironment', '_labelFontType').readU32(),
    labelFontSize: msgI(env, sel('labelFontSize')).toNumber(),
    postScriptName: str(name),
    size: CTFontGetSize(font),
    ascent: CTFontGetAscent(font),
    descent: CTFontGetDescent(font),
    leading: CTFontGetLeading(font),
  };
  CFRelease(name);
  return rec;
}

// Tables of inputs. Bounds and margins of the top-level call are derived from
// display sizes the way -[Springboard layout] derives them, only to get
// realistic inputs; the outputs are what Dock's methods return.
const displays = [[1024, 768], [1280, 800], [1440, 900], [1512, 982], [1536, 960], [1680, 1050], [1728, 1117],
  [1920, 1080], [1920, 1200], [2048, 1152], [2560, 1440], [2560, 1600], [3008, 1692], [3840, 2160], [5120, 2880]];
const dockCases = [{ o: 0, D: 59 }, { o: 1, D: 59 }, { o: 0, D: 0 }];
const pageSizes = [[5, 7], [4, 6], [6, 8], [2, 2], [3, 10]];
const zoomStyles = [0, 1, 2, 3];
const zoomFactors = [0, 0.1, 0.2, 0.3, 0.5, 0.6];
const scales = [1, 2];

function topInputs() {
  const inputs = [];
  for (const [W, H] of displays) {
    for (const { o, D } of dockCases) {
      for (const [rows, cols] of pageSizes) {
        const gridY = o === 0 ? D + 30 : 30;
        const gridH = H - gridY;
        const A = o === 0 ? W : W - D;
        const u = Math.floor(A / (2 * cols + 1));
        const v = Math.floor(gridH - rows * (u + 40));
        const side = Math.max(Math.floor(u * 0.5), 90);
        const top = Math.max(Math.floor(v * 0.15), 35);
        const bottom = Math.max(Math.floor(v * 0.25), 35);
        for (const zs of zoomStyles) for (const zf of zoomFactors) for (const scale of scales) {
          inputs.push({ display: [W, H], o, D, bounds: [0, gridY, W, gridH], scale, left: side, right: side, top, bottom, zs, zf, rows, cols });
        }
      }
    }
  }
  return inputs;
}

function runTables() {
  const C = {
    ECSBSpringboard: cls('ECSBSpringboard'),
    ECSBLayer: cls('ECSBLayer'),
    ECSBGridLayer: cls('ECSBGridLayer'),
    ECSBItemLayer: cls('ECSBItemLayer'),
    ECSBGroupItemLayer: cls('ECSBGroupItemLayer'),
    ECImageGridLayer: cls('ECImageGridLayer'),
  };
  const a = Memory.alloc(8);
  const b = Memory.alloc(8);
  const r1 = Memory.alloc(32);
  const r2 = Memory.alloc(32);
  const sTop = sel('calculateIconSize:miniIconSize:forBounds:andScaleFactor:usingLeftMargin:rightMargin:topMargin:bottomMargin:zoomStyle:zoomFactor:withNumberOfRows:andColumns:');
  for (const inp of topInputs()) {
    for (const name of ['ECSBSpringboard', 'ECSBLayer']) {
      a.writeU64(128);
      b.writeU64(32);
      calcSpringboard(C[name], sTop, a, b, inp.bounds, inp.scale, inp.left, inp.right, inp.top, inp.bottom, inp.zs, inp.zf, inp.rows, inp.cols);
      writeLine({ type: 'table', fn: `+[${name} calculateIconSize:…]`, in: inp, out: { icon: a.readU64().toNumber(), mini: b.readU64().toNumber() } });
    }
  }
  const sGrid = sel('calculateIconSize:miniIconSize:forBounds:andScaleFactor:withNumberOfRows:andColumns:');
  const sGridFrame = sel('calculateIconFrame:itemBounds:forBounds:andScaleFactor:withNumberOfRows:andColumns:');
  for (let w = 100; w <= 2000; w += 100) for (let h = 100; h <= 1200; h += 100) for (const [rows, cols] of pageSizes) for (const scale of scales) {
    const bounds = [0, 0, w + 0.5, h + 0.5];
    a.writeU64(0);
    b.writeU64(0);
    calcGrid(C.ECSBGridLayer, sGrid, a, b, bounds, scale, rows, cols);
    const sizeOut = { icon: a.readU64().toNumber(), mini: b.readU64().toNumber() };
    for (let i = 0; i < 4; i++) { r1.add(8 * i).writeDouble(-1); r2.add(8 * i).writeDouble(-7); }
    calcGridFrame(C.ECSBGridLayer, sGridFrame, r1, r2, bounds, scale, rows, cols);
    const frame = [0, 1, 2, 3].map(i => r1.add(8 * i).readDouble());
    const itemBounds = [0, 1, 2, 3].map(i => r2.add(8 * i).readDouble());
    writeLine({ type: 'table', fn: '+[ECSBGridLayer calculate…]', in: { bounds, rows, cols, scale }, out: { size: sizeOut, iconFrame: frame, itemBounds } });
  }
  const sItem = sel('calculateIconSize:miniIconSize:forBounds:andScaleFactor:');
  const sItemFrame = sel('calculateIconFrame:forBounds:andScaleFactor:');
  for (let w = 0; w <= 400; w += 5) for (let h = 0; h <= 400; h += 5) for (const scale of scales) {
    const bounds = [0, 0, w, h];
    a.writeU64(0);
    b.writeU64(0);
    calcItem(C.ECSBItemLayer, sItem, a, b, bounds, scale);
    for (let i = 0; i < 4; i++) r1.add(8 * i).writeDouble(-1);
    calcItemFrame(C.ECSBItemLayer, sItemFrame, r1, bounds, scale);
    writeLine({ type: 'table', fn: '+[ECSBItemLayer calculate…]', in: { bounds, scale }, out: { icon: a.readU64().toNumber(), mini: b.readU64().toNumber(), iconFrame: [0, 1, 2, 3].map(i => r1.add(8 * i).readDouble()) } });
  }
  const sMini = sel('miniIconSizeForBounds:andScaleFactor:');
  for (let base = 0; base <= 300; base++) for (const scale of scales) {
    const bounds = [0, 0, base, base];
    writeLine({ type: 'table', fn: '+[ECSBGroupItemLayer miniIconSizeForBounds:andScaleFactor:]', in: { bounds, scale }, out: miniIconSize(C.ECSBGroupItemLayer, sMini, bounds, scale).toNumber() });
  }
  const sImage = sel('iconSizeForBounds:withNumberOfRows:andColumns:withSpacing:');
  for (let h = 0; h <= 300; h++) for (const [rows, cols, spacing] of [[3, 3, 4], [2, 3, 0], [4, 4, 2]]) {
    const bounds = [1, 2, 50, h + 0.75];
    writeLine({ type: 'table', fn: '+[ECImageGridLayer iconSizeForBounds:withNumberOfRows:andColumns:withSpacing:]', in: { bounds, rows, cols, spacing }, out: imageGridIconSize(C.ECImageGridLayer, sImage, bounds, rows, cols, spacing).toNumber() });
  }
  writeLine({ type: 'tableDone' });
}

const access = new NativeFunction(Module.getGlobalExportByName('access'), 'int', ['pointer', 'int']);
const skipTables = access(Memory.allocUtf8String(`${home}/frida-gadget/lp-geometry-no-tables`), 0) === 0;

const springboardLayout = method_getImplementation(class_getInstanceMethod(cls('Springboard'), sel('layout')));
let tablesScheduled = false;
Interceptor.attach(springboardLayout, {
  onEnter(args) {
    this.sb = args[0];
  },
  onLeave() {
    try {
      writeLine(layoutRecord(this.sb));
    } catch (e) {
      writeLine({ type: 'error', where: 'layout', message: e.message });
    }
    if (!tablesScheduled && ivarPtr(this.sb, 'Springboard', '_deferLayout').readU8() === 0) {
      tablesScheduled = true;
      try {
        writeLine(fontRecord());
      } catch (e) {
        writeLine({ type: 'error', where: 'font', message: e.message });
      }
      if (!skipTables) setTimeout(() => {
        try {
          runTables();
        } catch (e) {
          writeLine({ type: 'error', where: 'tables', message: e.message });
        }
      }, 0);
    }
  },
});
