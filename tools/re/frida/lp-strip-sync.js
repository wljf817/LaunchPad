// Profile the strip copy's sync in this project's background process (LaunchPadAgent, comparison
// VM): for every WALayerKitWindow.syncCopy(), how long it takes and where the time goes, with the
// timing done in C (CModule) so that the hooks add well under a microsecond per call.
// Frida 17 core API only (no Objective-C bridge), as lp-key-latency.js.
//
// Load with frida-gadget in script mode (frida-gadget.config) into LaunchPadAgent, as
// lp-key-latency.js.
//
// File: $HOME/frida-gadget/lp-strip-sync-<UTC load time>.jsonl in the target process, created
// exclusively. The C side fills a ring of records in memory the script allocates (a CModule's own
// globals are not writable on arm64 macOS: the process died of SIGBUS); a timer writes them out
// every 200 ms, so no line is written while a sync runs.
//
// Lines ("k"), each with t = CACurrentMediaTime() in seconds when written:
//   header  frida, pid, mach timebase (numer, denom), t and mach_absolute_time() at load, hooks
//   sync    one syncCopy(): t0, t1 (mach, as CACurrentMediaTime seconds), ms (its duration) and per
//           part n (calls) and ms (inclusive time of the outermost call):
//             sync     sync(_:into:band:reach:visited:), n = layers synced (masks included)
//             copy     copy(of:), n = calls (new and existing copies)
//             observe  observe(_:), n = new copies
//             reach    animatedReach(of:) (builds before the strip-sync change; later builds inline its successor)
//             place    placeRootCopy(_:)
//             anim     -[CALayer addAnimation:forKey:] on the copies
//             kvoAdd   -[NSObject addObserver:forKeyPath:options:context:]
//             kvoRm    -[NSObject removeObserver:forKeyPath:context:] and removeObserver:forKeyPath:
//           tail: ms from the end of the outermost sync(...) to the end of syncCopy (the second
//           placeRootCopy and the dropping of copies no longer reached);
//           visited: class name -> count of the layers synced; added: the same for the new copies;
//           dropped = kvoRm.n / 21 (21 observations per copy; nested KVO calls count once)
//   commit  +[CATransaction commit] / +[CATransaction flush] on the main thread that contained a
//           syncCopy: fn, t0, t1, ms, syncs (how many)
//   note    hooks not installed, ring overruns

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}
function gf(name, ret, args) {
  return new NativeFunction(Module.getGlobalExportByName(name), ret, args);
}
const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const object_getClass = nf(libobjc, 'object_getClass', 'pointer', ['pointer']);
const class_getInstanceMethod = nf(libobjc, 'class_getInstanceMethod', 'pointer', ['pointer', 'pointer']);
const method_getImplementation = nf(libobjc, 'method_getImplementation', 'pointer', ['pointer']);
const class_getName = nf(libobjc, 'class_getName', 'pointer', ['pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const mach_absolute_time = gf('mach_absolute_time', 'uint64', []);
const mach_timebase_info = gf('mach_timebase_info', 'int', ['pointer']);
const getenv = gf('getenv', 'pointer', ['pointer']);

function imp(className_, selector, classMethod) {
  const c = objc_getClass(Memory.allocUtf8String(className_));
  if (c.isNull()) return null;
  const m = class_getInstanceMethod(classMethod ? object_getClass(c) : c,
    sel_registerName(Memory.allocUtf8String(selector)));
  return m.isNull() ? null : method_getImplementation(m).strip();
}

// --- output ---------------------------------------------------------------

const utc = new Date().toISOString().replace(/[-:]/g, '');
const home = getenv(Memory.allocUtf8String('HOME')).readUtf8String();
const path = home + '/frida-gadget/lp-strip-sync-' + utc + '.jsonl';
const file = new File(path, 'wx');
function write(obj) {
  obj.t = CACurrentMediaTime();
  file.write(JSON.stringify(obj) + '\n');
  file.flush();
}

const timebase = Memory.alloc(8);
mach_timebase_info(timebase);
const numer = timebase.readU32();
const denom = timebase.add(4).readU32();
// mach ticks to CACurrentMediaTime seconds (the same clock).
const toSec = ticks => Number(ticks) * numer / denom / 1e9;

// --- C side ---------------------------------------------------------------

// Parts, by the listener data each hook gets.
const SYNCCOPY = 0, SYNC = 1, COPY = 2, OBSERVE = 3, REACH = 4, PLACE = 5, ANIM = 6, KVOADD = 7, KVORM = 8,
  COMMIT = 9, FLUSH = 10;
const PARTS = ['syncCopy', 'sync', 'copy', 'observe', 'reach', 'place', 'anim', 'kvoAdd', 'kvoRm'];
const NPARTS = 9;
const MAXL = 1024;  // layers recorded per sync (visited and added each)
const RING = 64;

const source = `
#include <gum/guminterceptor.h>

extern guint64 mach_absolute_time (void);
extern void * object_getClass (void * obj);
extern int pthread_main_np (void);
extern void * memset (void * s, int c, gsize n);
extern void * memcpy (void * d, const void * s, gsize n);

#define NPARTS ${NPARTS}
#define MAXL ${MAXL}
#define RING ${RING}

typedef struct {
  guint64 t0, t1, sync_end;
  guint32 n[NPARTS];
  guint64 ticks[NPARTS];
  guint32 nvisited, nadded;
  void * visited[MAXL];
  void * added[MAXL];
} Rec;

typedef struct {
  guint64 t0, t1;
  guint32 fn, syncs;
} CommitRec;

/* All state lives in memory the script allocates (shared), not in the module's own data. The
   script reads written, commits_written, commits and ring at these offsets. */
typedef struct {
  guint32 written, commits_written;
  CommitRec commits[RING];
  Rec ring[RING];
  Rec cur;
  int in_sync_copy;
  int depth[NPARTS];
  guint64 start[NPARTS];
  int commit_depth;
  guint32 commit_fn, commit_syncs;
  guint64 commit_t0;
} Shared;

extern Shared shared;
#define S (&shared)

void
onEnter (GumInvocationContext * ic)
{
  gsize part = GUM_IC_GET_FUNC_DATA (ic, gsize);
  if (!pthread_main_np ())
    return;
  if (part == ${COMMIT} || part == ${FLUSH})
  {
    if (S->commit_depth++ == 0)
    {
      S->commit_t0 = mach_absolute_time ();
      S->commit_fn = (guint32) part;
      S->commit_syncs = 0;
    }
    return;
  }
  if (part == ${SYNCCOPY})
  {
    memset (&S->cur, 0, sizeof (S->cur));
    S->in_sync_copy = 1;
    memset (S->depth, 0, sizeof (S->depth));
    S->cur.t0 = mach_absolute_time ();
    return;
  }
  if (!S->in_sync_copy)
    return;
  /* A KVO call nested in another (one removeObserver variant calling the other) counts once. */
  if ((part == ${KVOADD} || part == ${KVORM}) && S->depth[part] > 0)
  {
    S->depth[part]++;
    return;
  }
  S->cur.n[part]++;
  if (part == ${SYNC} && S->cur.nvisited < MAXL)
    S->cur.visited[S->cur.nvisited++] = object_getClass (gum_invocation_context_get_nth_argument (ic, 0));
  if (part == ${OBSERVE} && S->cur.nadded < MAXL)
    S->cur.added[S->cur.nadded++] = object_getClass (gum_invocation_context_get_nth_argument (ic, 0));
  if (S->depth[part]++ == 0)
    S->start[part] = mach_absolute_time ();
}

void
onLeave (GumInvocationContext * ic)
{
  gsize part = GUM_IC_GET_FUNC_DATA (ic, gsize);
  guint64 now;
  if (!pthread_main_np ())
    return;
  now = mach_absolute_time ();
  if (part == ${COMMIT} || part == ${FLUSH})
  {
    if (S->commit_depth > 0 && --S->commit_depth == 0 && S->commit_syncs > 0)
    {
      CommitRec * c = &S->commits[S->commits_written % RING];
      c->t0 = S->commit_t0;
      c->t1 = now;
      c->fn = S->commit_fn;
      c->syncs = S->commit_syncs;
      S->commits_written++;
    }
    return;
  }
  if (part == ${SYNCCOPY})
  {
    if (!S->in_sync_copy)
      return;
    S->cur.t1 = now;
    S->in_sync_copy = 0;
    memcpy (&S->ring[S->written % RING], &S->cur, sizeof (S->cur));
    S->written++;
    if (S->commit_depth > 0)
      S->commit_syncs++;
    return;
  }
  if (!S->in_sync_copy)
    return;
  if (S->depth[part] > 0 && --S->depth[part] == 0)
  {
    S->cur.ticks[part] += now - S->start[part];
    if (part == ${SYNC})
      S->cur.sync_end = now;
  }
}
`;
const RECSIZE = 24 + 4 * NPARTS + ((4 * NPARTS) % 8) + 8 * NPARTS + 8 + 16 * MAXL;  // sizeof (Rec)
const COMMIT_SIZE = 24;
const OFF_COMMITS = 8;
const OFF_RING = OFF_COMMITS + COMMIT_SIZE * RING;
// The ring, the record being filled and the C side's own state, with room to spare for the latter.
const sharedSize = OFF_RING + RECSIZE * (RING + 1) + 4096;
const shared = Memory.alloc(sharedSize);
gf('memset', 'pointer', ['pointer', 'int', 'size_t'])(shared, 0, sharedSize);
let cm;
try {
  cm = new CModule(source, {
    shared,
    mach_absolute_time: Module.getGlobalExportByName('mach_absolute_time'),
    object_getClass: libobjc.getExportByName('object_getClass'),
    pthread_main_np: Module.getGlobalExportByName('pthread_main_np'),
    memset: Module.getGlobalExportByName('memset'),
    memcpy: Module.getGlobalExportByName('memcpy'),
  });
} catch (e) {
  write({ k: 'note', text: 'CModule: ' + e });
  throw e;
}

// --- hooks ----------------------------------------------------------------

const main = Process.mainModule;
function swift(name) {
  for (const n of [name, '_' + name]) {
    const s = main.findSymbolByName(n);
    if (s !== null && !s.isNull()) return s;
  }
  return null;
}
const installed = [];
const notes = [];
function attach(name, address, part) {
  if (address === null || address.isNull()) {
    notes.push('not found: ' + name);
    return;
  }
  try {
    Interceptor.attach(address, cm, ptr(part));
    installed.push(name);
  } catch (e) {
    notes.push('not attached: ' + name + ': ' + e);
  }
}

const W = '$s9LaunchPad16WALayerKitWindowC';
attach('syncCopy', swift(W + '8syncCopyyyF'), SYNCCOPY);
// sync(_:into:band:reach:visited:) before the strip-sync change, sync(_:into:band:zooms:visited:) after it.
attach('sync', swift(W + '4sync_4into4band5reach7visitedySo7CALayerC_AJSo6CGRectV12CoreGraphics7CGFloatVShySOGztF') ??
  swift(W + '4sync_4into4band5zooms7visitedySo7CALayerC_AJSo6CGRectVSayAJ5layer_SNy12CoreGraphics7CGFloatVG1xAQ1ytGShySOGztF'),
  SYNC);
attach('copy(of:)', swift(W + '4copy2ofSo7CALayerCAG_tF'), COPY);
attach('observe', swift(W + '7observeySay10Foundation21NSKeyValueObservationCGSo7CALayerCF'), OBSERVE);
// Before the strip-sync change only: its zoom(of:) and reaches(_:band:zooms:) are inlined into sync, so their time is
// part of sync's.
attach('animatedReach', swift(W + '13animatedReach2of12CoreGraphics7CGFloatVSo7CALayerC_tF'), REACH);
attach('placeRootCopy', swift(W + '13placeRootCopyyySo7CALayerCF'), PLACE);
attach('-[CALayer addAnimation:forKey:]', imp('CALayer', 'addAnimation:forKey:'), ANIM);
attach('-[NSObject addObserver:forKeyPath:options:context:]',
  imp('NSObject', 'addObserver:forKeyPath:options:context:'), KVOADD);
attach('-[NSObject removeObserver:forKeyPath:context:]', imp('NSObject', 'removeObserver:forKeyPath:context:'), KVORM);
attach('-[NSObject removeObserver:forKeyPath:]', imp('NSObject', 'removeObserver:forKeyPath:'), KVORM);
attach('+[CATransaction commit]', imp('CATransaction', 'commit', true), COMMIT);
attach('+[CATransaction flush]', imp('CATransaction', 'flush', true), FLUSH);

write({
  k: 'header', frida: Frida.version, pid: Process.id, process: main.name, utc, path,
  timebase: [numer, denom], mach: mach_absolute_time().toString(), installed,
});
for (const text of notes) write({ k: 'note', text });

// --- reading the ring -------------------------------------------------------

// Layout of Rec: t0, t1, sync_end (u64), n[NPARTS] (u32), padding to 8, ticks[NPARTS] (u64),
// nvisited, nadded (u32), visited[MAXL], added[MAXL] (pointers).
const offN = 24;
const offTicks = offN + 4 * NPARTS + ((4 * NPARTS) % 8);
const offCounts = offTicks + 8 * NPARTS;
const offVisited = offCounts + 8;
const offAdded = offVisited + 8 * MAXL;
const ringPtr = shared.add(OFF_RING);
const commitsPtr = shared.add(OFF_COMMITS);

const classNames = new Map();
function className(c) {
  const key = c.toString();
  let name = classNames.get(key);
  if (name === undefined) {
    name = c.isNull() ? 'nil' : class_getName(c).readUtf8String().replace(/^NSKVONotifying_/, '');
    classNames.set(key, name);
  }
  return name;
}
function histogram(base, count) {
  const out = {};
  for (let i = 0; i < count; i++) {
    const name = className(base.add(8 * i).readPointer());
    out[name] = (out[name] || 0) + 1;
  }
  return out;
}

let read = 0;
let commitsRead = 0;
const ms = ticks => toSec(ticks) * 1000;
function drain() {
  const written = shared.readU32();
  if (written - read > RING) {
    write({ k: 'note', text: 'ring overrun: ' + (written - read - RING) + ' syncs lost' });
    read = written - RING;
  }
  for (; read < written; read++) {
    const r = ringPtr.add((read % RING) * RECSIZE);
    const t0 = r.readU64(), t1 = r.add(8).readU64(), syncEnd = r.add(16).readU64();
    const line = { k: 'sync', t0: toSec(t0), t1: toSec(t1), ms: ms(t1.sub(t0)) };
    for (let p = 1; p < NPARTS; p++) {
      line[PARTS[p]] = { n: r.add(offN + 4 * p).readU32(), ms: ms(r.add(offTicks + 8 * p).readU64()) };
    }
    line.tail = syncEnd.equals(0) ? null : ms(t1.sub(syncEnd));
    const nvisited = r.add(offCounts).readU32(), nadded = r.add(offCounts + 4).readU32();
    line.visited = histogram(r.add(offVisited), Math.min(nvisited, MAXL));
    line.added = histogram(r.add(offAdded), Math.min(nadded, MAXL));
    line.dropped = line.kvoRm.n / 21;
    write(line);
  }
  const cw = shared.add(4).readU32();
  for (; commitsRead < cw; commitsRead++) {
    const c = commitsPtr.add((commitsRead % RING) * COMMIT_SIZE);
    const t0 = c.readU64(), t1 = c.add(8).readU64();
    write({
      k: 'commit', fn: c.add(16).readU32() === COMMIT ? 'commit' : 'flush', t0: toSec(t0), t1: toSec(t1),
      ms: ms(t1.sub(t0)), syncs: c.add(20).readU32(),
    });
  }
}
setInterval(drain, 200);
