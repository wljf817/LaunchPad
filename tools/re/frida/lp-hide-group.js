// Close the folder shown in the macOS 15 Launchpad in Dock (reference VM) with
// the original's own method, so that measurements start with no folder shown.
// Frida 17 core API only (no Objective-C bridge through REA, REF-ENV-003).
//
// On load, on Dock's main queue: reads -[Springboard groupShown]; when it is
// YES, sends -hideGroup to the main pager (-[ECSBSpringboard pager]), the
// method the pager uses to close a shown folder, then reads groupShown again.
// Meant to be loaded while Launchpad is open, as a click outside the folder
// would be. Sends {type: "done", before, after, visible}; unload after it.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
const sel_registerName = new NativeFunction(libobjc.getExportByName('sel_registerName'), 'pointer', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgV = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_async_f = new NativeFunction(libdispatch.getExportByName('dispatch_async_f'), 'void', ['pointer', 'pointer', 'pointer']);
const mainQueue = libdispatch.getExportByName('_dispatch_main_q');

function sel(name) {
  return sel_registerName(Memory.allocUtf8String(name));
}

const dock = Process.mainModule;
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

const callback = new NativeCallback(() => {
  try {
    const sb = springboardGlobal.readPointer();
    const visible = !!msgB(sb, sel('visible'));
    const before = !!msgB(sb, sel('groupShown'));
    if (before) {
      const ecsb = sb.add(0x28).readPointer(); // Springboard._springboard
      msgV(msgP(ecsb, sel('pager')), sel('hideGroup'));
    }
    send({ type: 'done', visible, before, after: !!msgB(sb, sel('groupShown')) });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, callback);
