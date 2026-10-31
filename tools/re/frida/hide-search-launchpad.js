// Hide the search field of this project's background process (LaunchPadAgent, macOS 26 comparison
// VM), once, so that its takes of the grid and paging scenes show the grid without it, as the
// reference takes prepared with hide-search-pager.js's search-field-only mode do (grid and paging
// specs). Frida 17 core API only, as hide-search-pager.js.
//
// Load it through REA into the agent started with frida-gadget listening, while the overlay is open
// (or, for grid-animation-first-open, after the agent's restart without opening it). On load, on the
// main queue: finds the field with -[ECSBLayer searchTextInputLayer] on the main grid's layer (the
// application delegate's springboard, its ECSBSpringboard's layer), sets `hidden` YES on it with
// implicit actions disabled, and reads it back. Sends {type: "done", searchHidden, gridHidden,
// visible}; unload and detach right after it, so that no session is attached while recording.
// Restarting the background process shows the field again.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
const sel_registerName = new NativeFunction(libobjc.getExportByName('sel_registerName'), 'pointer', ['pointer']);
const objc_getClass = new NativeFunction(libobjc.getExportByName('objc_getClass'), 'pointer', ['pointer']);
const object_getClass = new NativeFunction(libobjc.getExportByName('object_getClass'), 'pointer', ['pointer']);
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
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
// Swift stored properties appear as ivars named like the property.
function ivar(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}

const callback = new NativeCallback(() => {
  try {
    const app = msgP(cls('NSApplication'), sel('sharedApplication'));
    const controller = ivar(msgP(app, sel('delegate')), 'springboard');
    if (controller.isNull()) throw new Error('no controller yet');
    const grid = msgP(ivar(controller, 'springboard'), sel('layer'));
    const search = msgP(grid, sel('searchTextInputLayer'));
    if (search.isNull()) throw new Error('no search field');
    const transaction = cls('CATransaction');
    msgV(transaction, sel('begin'));
    msgVB(transaction, sel('setDisableActions:'), 1);
    msgVB(search, sel('setHidden:'), 1);
    msgV(transaction, sel('commit'));
    send({
      type: 'done',
      searchHidden: !!msgB(search, sel('isHidden')),
      gridHidden: !!msgB(grid, sel('isHidden')),
      visible: !!msgB(controller, sel('visible')),
    });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, callback);
