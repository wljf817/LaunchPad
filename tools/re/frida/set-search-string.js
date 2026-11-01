// Schedule the main grid's search field to get given strings at given times, in Dock of the macOS 15
// reference VM or in this project's background process (LaunchPadAgent, macOS 26 comparison VM), so
// that the filtering scenes of the search spec ("过滤的逐帧对比") are recorded with no session
// attached (search-filter design, decision 8). Frida 17 core API only, as hide-search-pager.js.
//
// Load it through REA as source with a line in front of it that gives the strings, each with its
// delay in seconds from loading:
//   globalThis.searchStrings = [[2, 'Pro'], [5, '']];
// On load, on the main queue: finds the field as hide-search-pager.js does in Dock (the process whose
// main module is Dock; this project has a class LPSpringboard too) and as hide-search-launchpad.js
// does in this project, and sends it
// -performSelector:withObject:afterDelay: with -setStringValue: and each string. The run loop then
// sets them; nothing of the script runs at that time. Sends {type: "scheduled", process, now (the
// CACurrentMediaTime() of scheduling), strings, stringValue}; unload and detach right after it.
// Also writes $HOME/frida-gadget/set-search-string.txt, one line per string: the wall-clock time it is
// due (milliseconds since 1970, from the scheduling time plus its delay), a tab and the string, so that
// a shell in the VM can wait for it (search-filter task 7.1).

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');
const sel_registerName = new NativeFunction(libobjc.getExportByName('sel_registerName'), 'pointer', ['pointer']);
const objc_getClass = new NativeFunction(libobjc.getExportByName('objc_getClass'), 'pointer', ['pointer']);
const object_getClass = new NativeFunction(libobjc.getExportByName('object_getClass'), 'pointer', ['pointer']);
const class_getInstanceVariable = new NativeFunction(libobjc.getExportByName('class_getInstanceVariable'), 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = new NativeFunction(libobjc.getExportByName('ivar_getOffset'), 'long', ['pointer']);
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgV = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer']);
const msgVPPD = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'double']);
const CACurrentMediaTime = new NativeFunction(Process.getModuleByName('QuartzCore').getExportByName('CACurrentMediaTime'), 'double', []);
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
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function ivar(obj, className, name) {
  const c = className === null ? object_getClass(obj) : cls(className);
  const iv = class_getInstanceVariable(c, Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}

// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2 (as hide-search-pager.js).
function dockField() {
  const springboardGlobal = ptr('0x100448168').add(Process.mainModule.base.sub(ptr('0x100000000')));
  const ecsb = springboardGlobal.readPointer().add(0x28).readPointer(); // Springboard._springboard
  return ivar(msgP(ecsb, sel('layer')), 'ECSBLayer', '_searchTextInputLayer');
}
// Swift stored properties appear as ivars named like the property (as hide-search-launchpad.js).
function launchPadField() {
  const app = msgP(cls('NSApplication'), sel('sharedApplication'));
  const controller = ivar(msgP(app, sel('delegate')), null, 'springboard');
  if (controller.isNull()) throw new Error('no controller yet');
  return msgP(msgP(ivar(controller, null, 'springboard'), sel('layer')), sel('searchTextInputLayer'));
}

const strings = globalThis.searchStrings;

const callback = new NativeCallback(() => {
  try {
    if (!Array.isArray(strings)) throw new Error('globalThis.searchStrings is not set');
    const dock = Process.mainModule.name === 'Dock';
    const field = dock ? dockField() : launchPadField();
    if (field.isNull()) throw new Error('no search field');
    const NSString = cls('NSString');
    const scheduled = Date.now();
    const times = new File(getenv(Memory.allocUtf8String('HOME')).readUtf8String() + '/frida-gadget/set-search-string.txt', 'w');
    for (const [delay, s] of strings) times.write(Math.round(scheduled + delay * 1000) + '\t' + s + '\n');
    times.close();
    for (const [delay, s] of strings) {
      const value = msgPP(msgP(NSString, sel('alloc')), sel('initWithUTF8String:'), Memory.allocUtf8String(s));
      msgVPPD(field, sel('performSelector:withObject:afterDelay:'), sel('setStringValue:'), value, delay);
      msgV(value, sel('release'));
    }
    send({
      type: 'scheduled',
      process: dock ? 'Dock' : 'LaunchPad',
      now: CACurrentMediaTime(),
      strings,
      stringValue: str(msgP(field, sel('stringValue'))),
    });
  } catch (e) {
    send({ type: 'error', message: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);

dispatch_async_f(mainQueue, NULL, callback);
