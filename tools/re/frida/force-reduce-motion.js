// Make the process see Reduce Motion as on, without changing the system setting, for checking
// LaunchPad's open and close with Reduce Motion (REF-OVERLAY-008), as lp-force.js forces
// -[DockGlobals axReduceMotion] in Dock. LaunchPad's DockGlobals reads the setting from Swift
// through the C function, so the function itself is replaced: _AXInterfaceGetReduceMotionEnabled
// (HIServices) returns 1 while the script is loaded and the original again once it is unloaded.
// Frida 17 core API only.
//
// Load through REA into this project's background process (frida-gadget in listen mode), next to
// ca-anim.js; unload with unload_frida_script.

'use strict';

const target = Module.getGlobalExportByName('_AXInterfaceGetReduceMotionEnabled');
Interceptor.replace(target, new NativeCallback(() => 1, 'uchar', []));
send({ type: 'forced', function: '_AXInterfaceGetReduceMotionEnabled', value: 1 });
