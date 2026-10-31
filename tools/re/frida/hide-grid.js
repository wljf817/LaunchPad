// Hide the main grid of the macOS 15 Launchpad in Dock (reference VM), once, so that reference
// takes of the overlay alone (springboard-shell's overlay-shell-* scenes) show the window and the
// background without the grid, the search field and the page indicator. Frida 17 core API only (no
// Objective-C bridge through REA, REF-ENV-003).
//
// On load, on Dock's main queue: sets `hidden` YES on the main grid's layer (-[ECSBSpringboard
// layer], the pager's ECSBLayer, REF-ARCH-007), with implicit actions disabled, and reads it back.
// Sends {type: "done", hidden, visible, groupShown}; unload and detach right after it, so that no
// session is attached while recording. Restarting Dock (killall Dock) shows the grid again.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
const sel_registerName = new NativeFunction(libobjc.getExportByName('sel_registerName'), 'pointer', ['pointer']);
const objc_getClass = new NativeFunction(libobjc.getExportByName('objc_getClass'), 'pointer', ['pointer']);
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

const dock = Process.mainModule;
// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2.
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

const callback = new NativeCallback(() => {
  try {
    const sb = springboardGlobal.readPointer();
    const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
    const grid = msgP(ecsb, sel('layer'));
    const transaction = objc_getClass(Memory.allocUtf8String('CATransaction'));
    msgV(transaction, sel('begin'));
    msgVB(transaction, sel('setDisableActions:'), 1);
    msgVB(grid, sel('setHidden:'), 1);
    msgV(transaction, sel('commit'));
    send({
      type: 'done',
      hidden: !!msgB(grid, sel('isHidden')),
      visible: !!msgB(sb, sel('visible')),
      groupShown: !!msgB(sb, sel('groupShown')),
    });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, callback);
