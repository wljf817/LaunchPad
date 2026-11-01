// The version of lp-search-filter.js for this project's background process (LaunchPadAgent, macOS 26
// comparison VM), with the same commands and the same lines, so that the two can be compared
// (search-filter task 5.1). The controller is the Swift global launchpadSpringboard (as
// lp-keyboard-launchpad.js); the rest goes through the same Objective-C names as in Dock. Swift
// stored properties appear as ivars named like the property. Methods called from Swift directly (not
// through objc_msgSend) cannot be traced at their Objective-C entry points, so the call lines of
// lp-search-filter.js are not written; the anim lines are.
// Frida 17 core API only (REF-ENV-003).
//
// Load it through REA into the agent started with frida-gadget listening (as lp-keyboard-launchpad.js).
// Commands go to $HOME/frida-gadget/lp-search-filter-cmd.txt, as for lp-search-filter.js: match,
// results, set, state (page is not supported). File:
// $HOME/frida-gadget/lp-search-filter-launchpad-<UTC load time>.jsonl. The selected item's title in
// state lines is its client item's title.
//
// Only the commands write to the process's objects (stringValue).

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
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
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
const path = home + '/frida-gadget/lp-search-filter-launchpad-' + utc + '.jsonl';
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

const globalName = '$s9LaunchPad20launchpadSpringboardAA0D0CSgvp';
// A local symbol: not an export, and findSymbolByName does not see it, so the symbol table is searched.
const springboardGlobal = (() => {
  const found = Process.mainModule.enumerateSymbols().find(s => s.name === globalName);
  return found === undefined ? null : found.address;
})();

function swiftIvar(obj, name) {
  const iv = class_getInstanceVariable(object_getClass(obj), Memory.allocUtf8String(name));
  if (iv.isNull()) throw new Error('ivar not found: ' + name);
  return obj.add(ivar_getOffset(iv)).readPointer();
}
function controller() {
  if (springboardGlobal === null) throw new Error('not found: ' + globalName);
  const sb = springboardGlobal.readPointer();
  if (sb.isNull()) throw new Error('no controller yet');
  return sb;
}
function springboard() {
  return swiftIvar(controller(), 'springboard');
}
function pager() {
  return msgP(springboard(), sel('pager'));
}
function grid() {
  return msgP(pager(), sel('layer'));
}
function field() {
  return msgP(grid(), sel('searchTextInputLayer'));
}
function noResults() {
  return swiftIvar(grid(), '_noResultsLayer');
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

function selectedTitle(item) {
  if (item.isNull()) return null;
  const client = msgP(item, sel('clientItem'));
  return client.isNull() ? className(item) : title(client);
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
      searchPages: count(swiftIvar(sb, '_searchPages')),
      filtering: !!msgB(p, sel('isFiltering')),
      currentPageIndex: Number(msgU(p, sel('currentPageIndex'))),
      pages: n,
      pageItems,
      selectedItem: selectedTitle(msgP(p, sel('selectedItem'))),
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
    } else if (w[0] === 'state') onMain(() => state(w[1]));
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
