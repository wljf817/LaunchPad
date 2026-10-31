// Force the return values that select the macOS 15 Launchpad's animation
// variants in Dock (reference VM), instead of changing system settings or
// posting input: Shift slow motion and Reduce Motion. Frida 17 core API only
// (no Objective-C bridge through REA, REF-ENV-003).
//
// Configuration: $HOME/frida-gadget/lp-force.json in the target process, an
// object with any of these keys set to true or false:
//   slowMotionAllowed  -[DockGlobals slowMotionAllowed]
//   shiftKeyDown       +[ECModalEventController shiftKeyDown]
//   axReduceMotion     -[DockGlobals axReduceMotion]
// Each key present replaces that method's implementation with one returning
// the given value, for as long as the script is loaded; unloading the script
// restores the original implementations. Keys not present are left alone.
// Sends {type: "forced", values} after installing.

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
function nf(name, ret, args) {
  return new NativeFunction(libobjc.getExportByName(name), ret, args);
}
const objc_getClass = nf('objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf('sel_registerName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf('class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const class_getClassMethod = nf('class_getClassMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf('method_getImplementation', 'pointer', ['pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);

const TARGETS = {
  slowMotionAllowed: ['DockGlobals', 'slowMotionAllowed', false],
  shiftKeyDown: ['ECModalEventController', 'shiftKeyDown', true],
  axReduceMotion: ['DockGlobals', 'axReduceMotion', false],
};

const path = getenv(Memory.allocUtf8String('HOME')).readUtf8String() + '/frida-gadget/lp-force.json';
const config = JSON.parse(File.readAllText(path));
const callbacks = [];
const values = {};

for (const key of Object.keys(TARGETS)) {
  if (typeof config[key] !== 'boolean') continue;
  const [className, selName, isClassMethod] = TARGETS[key];
  const c = objc_getClass(Memory.allocUtf8String(className));
  const s = sel_registerName(Memory.allocUtf8String(selName));
  const m = isClassMethod ? class_getClassMethod(c, s) : class_getInstanceMethod(c, s);
  if (m.isNull()) throw new Error('method not found: ' + className + ' ' + selName);
  const imp = method_getImplementation(m).strip();
  const result = config[key] ? 1 : 0;
  const cb = new NativeCallback(() => result, 'bool', ['pointer', 'pointer']);
  callbacks.push(cb);
  Interceptor.replace(imp, cb);
  values[key] = config[key];
}

send({ type: 'forced', values });
