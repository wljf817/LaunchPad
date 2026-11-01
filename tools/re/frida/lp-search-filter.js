// Check the filtering of the macOS 15 Launchpad in Dock (reference VM) at runtime: the result of
// -[Springboard _wordFromTitle:matchesTerm:] for given pairs, the results of
// -searchResultsForTerm:, when -searchTextChanged: and -searchTextCleared run after the search
// field's stringValue is set, the animation the "no results" layer gets, and the page the grid is
// on after filtering and clearing (search-filter design, decision 7).
// Frida 17 core API only (REF-ENV-003), helpers as lp-keyboard.js.
//
// Load through REA: start_frida_session { mode: "attach", remote, pid }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/lp-search-filter.js" }.
// Then write commands over SSH to $HOME/frida-gadget/lp-search-filter-cmd.txt in the VM; the
// file is read every 100 ms, run line by line and emptied. Fields are separated by tabs, strings
// are UTF-8. Every command runs on Dock's main queue. Commands:
//   match <title> <term>         -_wordFromTitle:matchesTerm: on the controller
//   results <term>               -searchResultsForTerm: on the controller
//   set <ms> <string> [<ms> <string>...]
//                                set the search field's stringValue to each string, <ms> after
//                                the command is read (dispatch_after on the main queue); an
//                                empty string is written as the field left empty
//   page <index>                 -[ECPager setCurrentPageIndex:] with implicit actions disabled
//   state <label>                write the state
// Fetch the file with tools/re/frida-fetch.sh.
//
// File: $HOME/frida-gadget/lp-search-filter-<UTC load time>.jsonl in the target process, created
// exclusively, every line flushed as written. Every line is also sent as a message.
//
// Lines ("type"), every one with t = CACurrentMediaTime() in seconds and main (whether the call
// runs on the main thread):
//   header    frida, pid, utc, the current locale's identifier and the preferred languages
//   match     title, term, value (the return value; "NSNotFound" when it is), matched
//   results   term, items (class, title, file name as the controller reads it)
//   set       the string set, right before -setStringValue: is sent
//   call      enter and leave of -[ECSBLayer observeValueForKeyPath:ofObject:change:context:]
//             (key path), -[Springboard searchTextChanged:] (term), -searchTextCleared,
//             -[ECSBSpringboard filterUsingItems:] (count), -clearFilteredItems,
//             -[ECSBLayer cancelTimers]; filterUsingItems: and clearFilteredItems also write the
//             state at leave
//   anim      -[CALayer addAnimation:forKey:] on the grid layer's "no results" layer: key, the
//             animation (class, key path, duration, begin time, timing function, from, to,
//             fill mode, removedOnCompletion) and the current transaction's animationDuration,
//             animationTimingFunction and disableActions
//   state     label, and: visible, searching, the controller's search page count, the pager's
//             filtering flag, currentPageIndex, page count and each page's item count, the
//             selected item's title, the field's stringValue, the "no results" layer's opacity
//             and animations (as anim). Written also 50 ms and 1 s after every filterUsingItems:
//             and clearFilteredItems leave
//   note      failures
//
// Only the commands write to Dock's objects (stringValue, the current page).

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  return new NativeFunction(Module.getGlobalExportByName(name), ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getInstanceVariable = nf(libobjc, 'class_getInstanceVariable', 'pointer', ['pointer', 'pointer']);
const ivar_getOffset = nf(libobjc, 'ivar_getOffset', 'long', ['pointer']);

const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'ulong']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer', 'pointer']);
const msgLPP = new NativeFunction(msgSendPtr, 'int64', ['pointer', 'pointer', 'pointer', 'pointer']);
const msgV = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer']);
const msgVP = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer']);
const msgVU = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'ulong']);
const msgVB = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'bool']);
const msgU = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer']);
const msgUP = new NativeFunction(msgSendPtr, 'ulong', ['pointer', 'pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);

const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const pthread_main_np = gf('pthread_main_np', 'int', []);
const getenv = gf('getenv', 'pointer', ['pointer']);
const libdispatch = Process.getModuleByName('libdispatch.dylib');
const dispatch_after_f = nf(libdispatch, 'dispatch_after_f', 'void', ['uint64', 'pointer', 'pointer', 'pointer']);
const dispatch_async_f = nf(libdispatch, 'dispatch_async_f', 'void', ['pointer', 'pointer', 'pointer']);
const dispatch_time = nf(libdispatch, 'dispatch_time', 'uint64', ['uint64', 'int64']);
const mainQueue = libdispatch.getExportByName('_dispatch_main_q');

const NSNotFound = '9223372036854775807';

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
  return objc_getClass(Memory.allocUtf8String(name));
}
function str(nsString) {
  return nsString.isNull() ? null : msgP(nsString, sel('UTF8String')).readUtf8String();
}
function className(obj) {
  return obj.isNull() ? null : object_getClassName(obj).readUtf8String();
}
function ivar(obj, className_, name) {
  const iv = class_getInstanceVariable(cls(className_), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + className_ + '.' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}
function description(obj) {
  return obj.isNull() ? null : str(msgP(obj, sel('description')));
}
function count(array) {
  return array.isNull() ? null : Number(msgU(array, sel('count')));
}
// A new NSString the caller releases.
function nsString(s) {
  return msgPP(msgP(cls('NSString'), sel('alloc')), sel('initWithUTF8String:'), Memory.allocUtf8String(s));
}
function release(obj) {
  msgV(obj, sel('release'));
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-search-filter-' + utc + '.jsonl';
const file = new File(path, 'wx');

function write(obj) {
  obj.t = CACurrentMediaTime();
  obj.main = pthread_main_np() === 1;
  const line = JSON.stringify(obj);
  file.write(line + '\n');
  file.flush();
  send(line);
}

// --- objects --------------------------------------------------------------

const dock = Process.mainModule;
// The LPSpringboard instance's global in Dock 15.6.1 (24G90), paper section 2 (as lp-paging.js).
const springboardGlobal = ptr('0x100448168').add(dock.base.sub(ptr('0x100000000')));

function controller() {
  return springboardGlobal.readPointer();
}
function springboard() {
  return controller().add(0x28).readPointer(); // Springboard._springboard
}
function pager() {
  return msgP(springboard(), sel('pager'));
}
function grid() {
  return msgP(pager(), sel('layer'));
}
function field() {
  return ivar(grid(), 'ECSBLayer', '_searchTextInputLayer');
}
function noResults() {
  return ivar(grid(), 'ECSBLayer', '_noResultsLayer');
}

function animation(a) {
  const entry = { class: className(a) };
  if (msgUP(a, sel('respondsToSelector:'), sel('keyPath'))) entry.keyPath = str(msgP(a, sel('keyPath')));
  entry.duration = msgD(a, sel('duration'));
  entry.beginTime = msgD(a, sel('beginTime'));
  entry.timingFunction = description(msgP(a, sel('timingFunction')));
  if (msgUP(a, sel('respondsToSelector:'), sel('fromValue'))) {
    entry.from = description(msgP(a, sel('fromValue')));
    entry.to = description(msgP(a, sel('toValue')));
  }
  entry.fillMode = str(msgP(a, sel('fillMode')));
  entry.removedOnCompletion = !!msgB(a, sel('isRemovedOnCompletion'));
  return entry;
}
function animations(layer) {
  const keys = msgP(layer, sel('animationKeys'));
  const out = [];
  const n = keys.isNull() ? 0 : count(keys);
  for (let i = 0; i < n; i++) {
    const key = msgPU(keys, sel('objectAtIndex:'), i);
    out.push(Object.assign({ key: str(key) }, animation(msgPP(layer, sel('animationForKey:'), key))));
  }
  return out;
}

const CATransaction = cls('CATransaction');
function transaction() {
  return {
    animationDuration: msgD(CATransaction, sel('animationDuration')),
    animationTimingFunction: description(msgP(CATransaction, sel('animationTimingFunction'))),
    disableActions: !!msgB(CATransaction, sel('disableActions')),
  };
}

function title(item) {
  if (item.isNull()) return null;
  try {
    return str(msgP(item, sel('title')));
  } catch (e) {
    return className(item);
  }
}

function state(label) {
  try {
    const sb = controller();
    const p = pager();
    const pages = msgP(p, sel('pages'));
    const n = count(pages);
    const pageItems = [];
    for (let i = 0; i < n; i++) {
      pageItems.push(count(msgP(msgP(msgPU(pages, sel('objectAtIndex:'), i), sel('item')), sel('items'))));
    }
    const nr = noResults();
    write({
      type: 'state',
      label,
      visible: !!msgB(sb, sel('visible')),
      searching: !!msgB(sb, sel('searching')),
      searchPages: count(ivar(sb, 'Springboard', '_searchPages')),
      filtering: !!msgB(p, sel('isFiltering')),
      currentPageIndex: Number(msgU(p, sel('currentPageIndex'))),
      pages: n,
      pageItems,
      selectedItem: title(msgP(p, sel('selectedItem'))),
      stringValue: str(msgP(field(), sel('stringValue'))),
      noResults: { opacity: msgF(nr, sel('opacity')), animations: animations(nr) },
    });
  } catch (e) {
    write({ type: 'note', what: 'state failed', label, error: String(e) });
  }
}

// --- main queue -----------------------------------------------------------

const jobs = new Map();
let nextJob = 1;
const runJob = new NativeCallback(ctx => {
  const job = jobs.get(ctx.toInt32());
  jobs.delete(ctx.toInt32());
  try {
    job();
  } catch (e) {
    write({ type: 'note', what: 'job failed', error: String(e), stack: e.stack });
  }
}, 'void', ['pointer']);
function onMain(job, ms) {
  const id = nextJob++;
  jobs.set(id, job);
  if (ms === undefined) dispatch_async_f(mainQueue, ptr(id), runJob);
  else dispatch_after_f(dispatch_time(0, Math.round(ms * 1e6)), mainQueue, ptr(id), runJob);
}

// --- commands -------------------------------------------------------------

function match(t, q) {
  const ts = nsString(t);
  const qs = nsString(q);
  const value = msgLPP(controller(), sel('_wordFromTitle:matchesTerm:'), ts, qs).toString();
  release(ts);
  release(qs);
  write({ type: 'match', title: t, term: q, value: value === NSNotFound ? 'NSNotFound' : value,
    matched: value !== NSNotFound });
}

function results(q) {
  const qs = nsString(q);
  const r = msgPP(controller(), sel('searchResultsForTerm:'), qs);
  release(qs);
  const items = [];
  const n = count(r);
  for (let i = 0; i < n; i++) {
    const item = msgPU(r, sel('objectAtIndex:'), i);
    let fileName = null;
    try {
      const url = msgP(item, sel('lastURL'));
      if (!url.isNull()) {
        fileName = str(msgP(msgP(msgP(url, sel('path')), sel('lastPathComponent')), sel('stringByDeletingPathExtension')));
      }
    } catch (e) {
      fileName = 'error: ' + e;
    }
    items.push({ class: className(item), title: title(item), fileName });
  }
  write({ type: 'results', term: q, count: n, items });
}

function setString(s) {
  const value = nsString(s);
  write({ type: 'set', string: s });
  msgVP(field(), sel('setStringValue:'), value);
  release(value);
}

function page(index) {
  msgV(CATransaction, sel('begin'));
  msgVB(CATransaction, sel('setDisableActions:'), 1);
  msgVU(pager(), sel('setCurrentPageIndex:'), index);
  msgV(CATransaction, sel('commit'));
}

const cmdPath = home + '/frida-gadget/lp-search-filter-cmd.txt';
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
    if (line.trim() === '') continue;
    const w = line.split('\t');
    if (w[0] === 'match') onMain(() => match(w[1], w[2]));
    else if (w[0] === 'results') onMain(() => results(w[1]));
    else if (w[0] === 'set') {
      for (let i = 1; i < w.length; i += 2) {
        const s = w[i + 1] === undefined ? '' : w[i + 1];
        onMain(() => setString(s), Number(w[i]));
      }
    } else if (w[0] === 'page') onMain(() => page(Number(w[1])));
    else if (w[0] === 'state') onMain(() => state(w[1]));
    else write({ type: 'note', what: 'unknown command', line });
  }
}, 100);

// --- hooks ----------------------------------------------------------------

function hookInstance(className_, selector, onEnter, onLeave) {
  const m = class_getInstanceMethod(cls(className_), sel(selector));
  if (m.isNull()) {
    write({ type: 'note', what: 'no method', fn: className_ + '.' + selector });
    return;
  }
  const callbacks = {};
  if (onEnter) callbacks.onEnter = onEnter;
  if (onLeave) callbacks.onLeave = onLeave;
  Interceptor.attach(method_getImplementation(m), callbacks);
}

function later(label) {
  onMain(() => state('50 ms after ' + label), 50);
  onMain(() => state('1 s after ' + label), 1000);
}

const calls = [
  ['ECSBLayer', 'observeValueForKeyPath:ofObject:change:context:', c => str(c.x2), null],
  ['Springboard', 'searchTextChanged:', c => str(c.x2), null],
  ['Springboard', 'searchTextCleared', null, null],
  ['ECSBSpringboard', 'filterUsingItems:', c => count(c.x2), 'filterUsingItems:'],
  ['ECSBSpringboard', 'clearFilteredItems', null, 'clearFilteredItems'],
  ['ECSBLayer', 'cancelTimers', null, null],
];
for (const [className_, selector, arg, leaveState] of calls) {
  hookInstance(className_, selector,
    function () {
      write({ type: 'call', ph: 'enter', fn: className_ + ' ' + selector, arg: arg === null ? null : arg(this.context) });
    },
    function () {
      write({ type: 'call', ph: 'leave', fn: className_ + ' ' + selector });
      if (leaveState !== null) {
        state('leave ' + leaveState);
        later(leaveState);
      }
    });
}

let noResultsLayer = ptr(0);
hookInstance('CALayer', 'addAnimation:forKey:',
  function () {
    if (!this.context.x0.equals(noResultsLayer)) return;
    write({ type: 'anim', key: str(this.context.x3), animation: animation(this.context.x2), transaction: transaction() });
  },
  null);

onMain(() => {
  noResultsLayer = noResults();
  const locale = msgP(cls('NSLocale'), sel('currentLocale'));
  const languages = msgP(cls('NSLocale'), sel('preferredLanguages'));
  write({ type: 'header', frida: Frida.version, pid: Process.id, utc,
    locale: str(msgP(locale, sel('localeIdentifier'))), languages: description(languages) });
  state('load');
});
