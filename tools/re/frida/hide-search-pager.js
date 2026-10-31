// Hide the search field and the page indicator of the macOS 15 Launchpad in Dock (reference VM),
// once, so that the reference takes of grid-items-still show the grid without them (grid spec,
// "打开后的静止画面"). Load it while the overlay is open: the pager layer's layout sets the page
// indicator's visibility again. Frida 17 core API only (no Objective-C bridge through REA,
// REF-ENV-003).
//
// On load, on Dock's main queue: sets `hidden` YES on the main grid's search field
// (ECSBLayer._searchTextInputLayer) and page indicator (ECPagerLayer._controlLayer, REF-ARCH-007),
// with implicit actions disabled, and reads them back. Sends {type: "done", searchHidden,
// pagerHidden, gridHidden, visible, groupShown}; unload and detach right after it, so that no
// session is attached while recording. Restarting Dock (killall Dock) shows them again.
//
// Search field only (the page-control scenes of the paging spec, which compare the page
// indicator): load the script as source with the line `globalThis.searchOnly = true;` in front of
// it. The page indicator is then left as it is.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
const sel_registerName = new NativeFunction(libobjc.getExportByName('sel_registerName'), 'pointer', ['pointer']);
const objc_getClass = new NativeFunction(libobjc.getExportByName('objc_getClass'), 'pointer', ['pointer']);
const class_getInstanceVariable = new NativeFunction(libobjc.getExportByName('class_getInstanceVariable'), 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = new NativeFunction(libobjc.getExportByName('ivar_getOffset'), 'long', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgV = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer']);
const msgVB = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'bool']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_async_f = new NativeFunction(libdispatch.getExportByName('dispatch_async_f'), 'void', ['pointer', 'pointer', 'pointer']);
const mainQueue = libdispatch.getExportByName('_dispatch_main_q');

function sel(name) {
  return sel_registerName(Memory.allocUtf8String(name));
}
function ivar(obj, className, name) {
  const iv = class_getInstanceVariable(objc_getClass(Memory.allocUtf8String(className)), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className + '.' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}

const dock = Process.mainModule;
// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2 (as hide-grid.js).
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

const searchOnly = globalThis.searchOnly === true;

const callback = new NativeCallback(() => {
  try {
    const sb = springboardGlobal.readPointer();
    const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
    const grid = msgP(ecsb, sel('layer'));
    const search = ivar(grid, 'ECSBLayer', '_searchTextInputLayer');
    const pager = ivar(grid, 'ECPagerLayer', '_controlLayer');
    const transaction = objc_getClass(Memory.allocUtf8String('CATransaction'));
    msgV(transaction, sel('begin'));
    msgVB(transaction, sel('setDisableActions:'), 1);
    msgVB(search, sel('setHidden:'), 1);
    if (!searchOnly) {
      msgVB(pager, sel('setHidden:'), 1);
    }
    msgV(transaction, sel('commit'));
    send({
      type: 'done',
      searchHidden: !!msgB(search, sel('isHidden')),
      pagerHidden: !!msgB(pager, sel('isHidden')),
      gridHidden: !!msgB(grid, sel('isHidden')),
      visible: !!msgB(sb, sel('visible')),
      groupShown: !!msgB(sb, sel('groupShown')),
    });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, callback);
