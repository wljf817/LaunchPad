// Post mouse, keyboard and scroll wheel events in the macOS 15 reference VM from inside Dock,
// for scenes that need real input while another script traces Dock.
// Processes started over SSH may not post events (CGPreflightPostEventAccess is
// false for them); Dock may. Events are posted to the HID event tap, so the
// window server routes them as it routes hardware input.
// Frida 17 core API only (REF-ENV-003).
//
// Load through REA into the Dock session, then write commands over SSH to
// $HOME/frida-gadget/lp-input-cmd.txt in the VM; the file is read every 100 ms,
// run line by line and emptied. Commands:
//   click <x> <y>               move there, press and release the left button
//   rclick <x> <y>              the same with the right button
//   down <x> <y>                move there and press the left button only
//   up <x> <y>                  release the left button there
//   dragmove <x> <y>            move there with the left button held (one left-dragged event)
//   drag <x1> <y1> <x2> <y2> [<steps> <interval-ms> [<hold-ms>]]
//                               press at (x1, y1), wait 80 ms, move to (x2, y2) in <steps>
//                               equal steps (10), waiting <interval-ms> (16) after each, wait
//                               <hold-ms> (0) more and release there
//   key <keycode> [mods...]     press and release a key; mods: cmd shift opt ctrl
//   wheel <x> <y> <dy> [<dx> [<count> <interval-ms>]] [shift]
//                               move there, wait 150 ms and post <count> (1) scroll wheel
//                               events of <dy> lines vertically and <dx> (0) horizontally,
//                               <interval-ms> (16) apart; with shift, Shift is held around them
//   scroll <x> <y> <dy> [<dx> [<momentum-phase>]]
//                               one scroll wheel event of <dy> and <dx> lines there, without
//                               moving the pointer first; integer field 123 set to <momentum-phase>
//   gesture <x> <y> <gesture-type> <phase> [<direction> [<flip>]]
//                               one gesture event (type 29) there with integer fields 110, 132,
//                               115 and 136 set to the values given (REF-OVERLAY-009)
//   sleep <ms>
// Each finished command is sent as a message.
//
// Nothing is written to Dock's objects.

'use strict';

function gf(name, ret, args) {
  return new NativeFunction(Module.getGlobalExportByName(name), ret, args);
}

const CGEventCreateMouseEvent = gf('CGEventCreateMouseEvent', 'pointer', ['pointer', 'uint32', ['double', 'double'], 'uint32']);
const CGEventCreateKeyboardEvent = gf('CGEventCreateKeyboardEvent', 'pointer', ['pointer', 'uint16', 'bool']);
const CGEventSetFlags = gf('CGEventSetFlags', 'void', ['pointer', 'uint64']);
const CGEventCreateScrollWheelEvent2 = gf('CGEventCreateScrollWheelEvent2', 'pointer',
  ['pointer', 'uint32', 'uint32', 'int32', 'int32', 'int32']);
const CGEventSetLocation = gf('CGEventSetLocation', 'void', ['pointer', ['double', 'double']]);
const CGEventCreate = gf('CGEventCreate', 'pointer', ['pointer']);
const CGEventSetType = gf('CGEventSetType', 'void', ['pointer', 'uint32']);
const CGEventSetIntegerValueField = gf('CGEventSetIntegerValueField', 'void', ['pointer', 'uint32', 'int64']);
const CGEventPost = gf('CGEventPost', 'void', ['uint32', 'pointer']);
const CFRelease = gf('CFRelease', 'void', ['pointer']);
const getenv = gf('getenv', 'pointer', ['pointer']);

const MODS = { cmd: 0x100000, shift: 0x20000, opt: 0x80000, ctrl: 0x40000 };

function post(e) {
  CGEventPost(0, e);
  CFRelease(e);
}

// Steps run from timers, never by sleeping: a sleeping script thread would hold
// the JavaScript lock that the tracing script's hooks on Dock's main thread need.
const queue = [];
let running = false;

function run() {
  if (queue.length === 0) {
    running = false;
    return;
  }
  running = true;
  const [delay, step] = queue.shift();
  step();
  setTimeout(run, delay);
}

function enqueue(steps) {
  queue.push(...steps);
  if (!running) run();
}

// Event types: left down 1, up 2; right down 3, up 4; mouse moved 5; left dragged 6.
function click(x, y, down, up, button) {
  return [
    [150, () => post(CGEventCreateMouseEvent(ptr(0), 5, [x, y], 0))],
    [80, () => post(CGEventCreateMouseEvent(ptr(0), down, [x, y], button))],
    [0, () => post(CGEventCreateMouseEvent(ptr(0), up, [x, y], button))],
  ];
}

function down(x, y) {
  return [
    [150, () => post(CGEventCreateMouseEvent(ptr(0), 5, [x, y], 0))],
    [0, () => post(CGEventCreateMouseEvent(ptr(0), 1, [x, y], 0))],
  ];
}

function up(x, y) {
  return [[0, () => post(CGEventCreateMouseEvent(ptr(0), 2, [x, y], 0))]];
}

function dragmove(x, y) {
  return [[0, () => post(CGEventCreateMouseEvent(ptr(0), 6, [x, y], 0))]];
}

// The same steps and timing as vm-input's drag.
function drag(x1, y1, x2, y2, n, interval, hold) {
  const steps = [
    [150, () => post(CGEventCreateMouseEvent(ptr(0), 5, [x1, y1], 0))],
    [80, () => post(CGEventCreateMouseEvent(ptr(0), 1, [x1, y1], 0))],
  ];
  for (let i = 1; i <= n; i++) {
    const x = x1 + (x2 - x1) * i / n;
    const y = y1 + (y2 - y1) * i / n;
    steps.push([i === n ? interval + hold : interval, () => post(CGEventCreateMouseEvent(ptr(0), 6, [x, y], 0))]);
  }
  steps.push([0, () => post(CGEventCreateMouseEvent(ptr(0), 2, [x2, y2], 0))]);
  return steps;
}

// Modifier keys are pressed before the key and released after it, as on a
// keyboard, so that the window server sees the same modifier state.
const MOD_KEYS = { cmd: 55, shift: 56, opt: 58, ctrl: 59 };

function keyStep(code, down, flags) {
  return [60, () => {
    const e = CGEventCreateKeyboardEvent(ptr(0), code, down ? 1 : 0);
    CGEventSetFlags(e, flags);
    post(e);
  }];
}

function key(code, mods) {
  const steps = [];
  let flags = 0;
  for (const m of mods) {
    flags |= MODS[m];
    steps.push(keyStep(MOD_KEYS[m], true, flags));
  }
  steps.push(keyStep(code, true, flags), keyStep(code, false, flags));
  for (const m of mods.slice().reverse()) {
    flags &= ~MODS[m];
    steps.push(keyStep(MOD_KEYS[m], false, flags));
  }
  return steps;
}

// The same steps and timing as vm-input's wheel: line units (1), two wheels.
function wheel(x, y, dy, dx, n, interval, shift) {
  const flags = shift ? MODS.shift : 0;
  const steps = [[150, () => post(CGEventCreateMouseEvent(ptr(0), 5, [x, y], 0))]];
  if (shift) steps.push(keyStep(MOD_KEYS.shift, true, MODS.shift));
  for (let i = 1; i <= n; i++) {
    steps.push([i === n ? (shift ? 60 : 0) : interval, () => {
      const e = CGEventCreateScrollWheelEvent2(ptr(0), 1, 2, dy, dx, 0);
      CGEventSetLocation(e, [x, y]);
      CGEventSetFlags(e, flags);
      post(e);
    }]);
  }
  if (shift) steps.push(keyStep(MOD_KEYS.shift, false, 0));
  return steps;
}

function scroll(x, y, dy, dx, momentum) {
  return [[0, () => {
    const e = CGEventCreateScrollWheelEvent2(ptr(0), 1, 2, dy, dx, 0);
    CGEventSetLocation(e, [x, y]);
    CGEventSetIntegerValueField(e, 123, momentum);
    post(e);
  }]];
}

function gesture(x, y, type, phase, direction, flip) {
  return [[0, () => {
    const e = CGEventCreate(ptr(0));
    CGEventSetType(e, 29);
    CGEventSetLocation(e, [x, y]);
    CGEventSetIntegerValueField(e, 110, type);
    CGEventSetIntegerValueField(e, 132, phase);
    CGEventSetIntegerValueField(e, 115, direction);
    CGEventSetIntegerValueField(e, 136, flip);
    post(e);
  }]];
}

const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const cmdPath = home + '/frida-gadget/lp-input-cmd.txt';

setInterval(() => {
  let text;
  try {
    text = File.readAllText(cmdPath);
  } catch (e) {
    return;
  }
  if (text.trim() === '') return;
  new File(cmdPath, 'w').close();
  for (const line of text.split('\n')) {
    const w = line.trim().split(/\s+/);
    let steps;
    if (w[0] === 'click') steps = click(Number(w[1]), Number(w[2]), 1, 2, 0);
    else if (w[0] === 'rclick') steps = click(Number(w[1]), Number(w[2]), 3, 4, 1);
    else if (w[0] === 'down') steps = down(Number(w[1]), Number(w[2]));
    else if (w[0] === 'up') steps = up(Number(w[1]), Number(w[2]));
    else if (w[0] === 'dragmove') steps = dragmove(Number(w[1]), Number(w[2]));
    else if (w[0] === 'drag') steps = drag(Number(w[1]), Number(w[2]), Number(w[3]), Number(w[4]),
      w.length > 5 ? Number(w[5]) : 10, w.length > 6 ? Number(w[6]) : 16, w.length > 7 ? Number(w[7]) : 0);
    else if (w[0] === 'key') steps = key(Number(w[1]), w.slice(2));
    else if (w[0] === 'wheel') {
      const shift = w[w.length - 1] === 'shift';
      const v = (shift ? w.slice(0, -1) : w).slice(1).map(Number);
      steps = wheel(v[0], v[1], v[2], v.length > 3 ? v[3] : 0, v.length > 4 ? v[4] : 1, v.length > 5 ? v[5] : 16, shift);
    }
    else if (w[0] === 'scroll') steps = scroll(Number(w[1]), Number(w[2]), Number(w[3]),
      w.length > 4 ? Number(w[4]) : 0, w.length > 5 ? Number(w[5]) : 0);
    else if (w[0] === 'gesture') steps = gesture(Number(w[1]), Number(w[2]), Number(w[3]), Number(w[4]),
      w.length > 5 ? Number(w[5]) : 0, w.length > 6 ? Number(w[6]) : 0);
    else if (w[0] === 'sleep') steps = [[Number(w[1]), () => {}]];
    else continue;
    steps.push([0, () => send(line.trim())]);
    enqueue(steps);
  }
}, 100);
