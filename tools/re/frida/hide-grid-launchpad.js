// Hide the main grid of this project's background process (LaunchPadAgent, macOS 26 comparison VM),
// once, so that its overlay-shell-* takes show the window and the background without the grid, as
// the reference takes prepared with hide-grid.js do (overlay spec, "逐帧对比的场景"). Frida 17 core
// API only, like hide-grid.js.
//
// Load it with frida-gadget when the agent starts, in script mode (frida-gadget.config next to the
// gadget: {"interaction": {"type": "script", "path": "<VM home>/frida-gadget/hide-grid-launchpad.js"}};
// the agent started with DYLD_INSERT_LIBRARIES set to the gadget, see REF-ENV-007's source). The
// script waits until the controller exists, then on the main queue sets `hidden` YES on the main
// grid's layer (the ECSBSpringboard's pager layer) with implicit actions disabled, and writes
// {hidden} to $HOME/frida-gadget/hide-grid-launchpad-<UTC>.json. It then does nothing more.
// Restarting the background process shows the grid again.

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
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);

function sel(name) {
  return sel_registerName(Memory.allocUtf8String(name));
}
function cls(name) {
  return objc_getClass(Memory.allocUtf8String(name));
}
// Swift stored properties appear as ivars named like the property.
function ivar(obj, className, name) {
  const iv = class_getInstanceVariable(cls(className), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className + '.' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d+)Z$/, '.$1Z');

let done = false;
const callback = new NativeCallback(() => {
  if (done) return;
  try {
    const app = msgP(cls('NSApplication'), sel('sharedApplication'));
    const delegate = msgP(app, sel('delegate'));
    if (delegate.isNull()) return;
    const controller = ivar(delegate, 'LaunchPadAppDelegate', 'springboard');
    if (controller.isNull()) return;
    const grid = msgP(ivar(controller, 'Springboard', 'springboard'), sel('layer'));
    const transaction = cls('CATransaction');
    msgV(transaction, sel('begin'));
    msgVB(transaction, sel('setDisableActions:'), 1);
    msgVB(grid, sel('setHidden:'), 1);
    msgV(transaction, sel('commit'));
    done = true;
    const file = new File(`${home}/frida-gadget/hide-grid-launchpad-${utc}.json`, 'wx');
    file.write(JSON.stringify({ hidden: !!msgB(grid, sel('isHidden')) }) + '\n');
    file.close();
  } catch (e) {
    // The controller is not there yet; the timer tries again.
  }
}, 'void', ['pointer']);

const timer = setInterval(() => {
  if (done) {
    clearInterval(timer);
    return;
  }
  dispatch_async_f(mainQueue, NULL, callback);
}, 200);
