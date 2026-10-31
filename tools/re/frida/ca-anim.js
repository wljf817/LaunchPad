// Record every Core Animation animation added to any layer, for measuring the
// animation parameters of the macOS 15 Launchpad in Dock (reference VM).
// Frida 17 core API only: scripts loaded through REA have no Objective-C bridge
// (REF-ENV-003), so Objective-C is driven through the runtime's C functions and
// objc_msgSend.
//
// Hooks -[CALayer addAnimation:forKey:] and writes one JSON Lines record per
// call, when the call returns, to
// $HOME/frida-gadget/ca-anim-<UTC load time>.jsonl in the target process. The
// file is created exclusively (never overwritten); every line is flushed right
// after it is written. The first line is a header with the Frida version, the
// pid, CACurrentMediaTime() and UTC at load time, which maps host-side trigger
// times onto the records' media-time axis. REA messages carry only the file
// path and script errors, never the records themselves.
//
// Load through REA: start_frida_session { mode: "attach", pid, remote }, then
// load_frida_script { source_kind: "file", path: "<repo>/tools/re/frida/ca-anim.js" }.
// Unload with unload_frida_script; fetch the files with tools/re/frida-fetch.sh.
//
// Record fields ("type": "add"): mediaTime, key, layer (class, address, name,
// speed, timeOffset, beginTime), superlayers (the same for each ancestor, the
// direct superlayer first), caller (module and offset of the return address),
// transaction (the current CATransaction's animationDuration and
// animationTimingFunction), animation (the object passed in) and stored
// (duration and timingFunction of the copy the layer stores under the key,
// read when the call returns; null without a key) and, for property
// animations, modelValue (the layer's model value at the keyPath when the call
// returns). Core Animation copies the animation when it is added and fills a
// zero duration and the timing function of the copy from the transaction, so
// stored holds the values that take effect. Implicit animations carry only the
// old value as fromValue; their end value is modelValue.
//
// Animation fields depend on its class: CAAnimation timing for all,
// keyPath/additive/cumulative/valueFunction for CAPropertyAnimation,
// fromValue/toValue/byValue for CABasicAnimation, values/keyTimes/
// timingFunctions/calculationMode for CAKeyframeAnimation, and animations
// (each expanded in order) for CAAnimationGroup.
//
// Value encoding: nil is null. Numbers are written as the shortest decimal
// that parses back to the exact double; non-finite numbers are the strings
// "inf", "-inf" and "nan". NSString is a string. NSNumber is
// {objCType, number}. NSValue is {objCType, struct, doubles} when the struct
// is made of doubles only (CGPoint, CGSize, CGRect, CATransform3D), otherwise
// {objCType, bytes} in hex. CGColor is {colorSpace, components}.
// CAMediaTimingFunction is {controlPoints: [[x, y] x 4]}. NSArray is an array
// of encoded elements. Any other object is {class, description}
// (CAValueFunction adds its name).

'use strict';

const libobjc = Process.getModuleByName('libobjc.A.dylib');
const msgSendPtr = libobjc.getExportByName('objc_msgSend');

function nf(module, name, ret, args) {
  return new NativeFunction(module.getExportByName(name), ret, args);
}

const objc_getClass = nf(libobjc, 'objc_getClass', 'pointer', ['pointer']);
const sel_registerName = nf(libobjc, 'sel_registerName', 'pointer', ['pointer']);
const class_getMethodImplementation = nf(libobjc, 'class_getMethodImplementation', 'pointer', ['pointer', 'pointer']);
const object_getClassName = nf(libobjc, 'object_getClassName', 'pointer', ['pointer']);

// arm64 has no _stret/_fpret variants: one entry point, one signature per use.
const msgP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer']);
const msgPP = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'pointer']);
const msgPU = new NativeFunction(msgSendPtr, 'pointer', ['pointer', 'pointer', 'uint64']);
const msgD = new NativeFunction(msgSendPtr, 'double', ['pointer', 'pointer']);
const msgF = new NativeFunction(msgSendPtr, 'float', ['pointer', 'pointer']);
const msgB = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer']);
const msgBP = new NativeFunction(msgSendPtr, 'bool', ['pointer', 'pointer', 'pointer']);
const msgU = new NativeFunction(msgSendPtr, 'uint64', ['pointer', 'pointer']);
const msgVPU = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'pointer', 'uint64']);
const msgVUP = new NativeFunction(msgSendPtr, 'void', ['pointer', 'pointer', 'uint64', 'pointer']);

const cf = Process.getModuleByName('CoreFoundation');
const CFGetTypeID = nf(cf, 'CFGetTypeID', 'ulong', ['pointer']);
const CFRelease = nf(cf, 'CFRelease', 'void', ['pointer']);
const cg = Process.getModuleByName('CoreGraphics');
const CGColorGetTypeID = nf(cg, 'CGColorGetTypeID', 'ulong', []);
const CGColorGetNumberOfComponents = nf(cg, 'CGColorGetNumberOfComponents', 'size_t', ['pointer']);
const CGColorGetComponents = nf(cg, 'CGColorGetComponents', 'pointer', ['pointer']);
const CGColorGetColorSpace = nf(cg, 'CGColorGetColorSpace', 'pointer', ['pointer']);
const CGColorSpaceCopyName = nf(cg, 'CGColorSpaceCopyName', 'pointer', ['pointer']);
const CACurrentMediaTime = nf(Process.getModuleByName('QuartzCore'), 'CACurrentMediaTime', 'double', []);
const NSGetSizeAndAlignment = nf(Process.getModuleByName('Foundation'), 'NSGetSizeAndAlignment', 'pointer', ['pointer', 'pointer', 'pointer']);
const getenv = new NativeFunction(Module.getGlobalExportByName('getenv'), 'pointer', ['pointer']);

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
  const c = objc_getClass(Memory.allocUtf8String(name));
  if (c.isNull()) throw new Error('class not found: ' + name);
  return c;
}

const C = {
  CALayer: cls('CALayer'),
  CAPropertyAnimation: cls('CAPropertyAnimation'),
  CABasicAnimation: cls('CABasicAnimation'),
  CAKeyframeAnimation: cls('CAKeyframeAnimation'),
  CAAnimationGroup: cls('CAAnimationGroup'),
  CAMediaTimingFunction: cls('CAMediaTimingFunction'),
  CAValueFunction: cls('CAValueFunction'),
  CATransaction: cls('CATransaction'),
  NSString: cls('NSString'),
  NSNumber: cls('NSNumber'),
  NSValue: cls('NSValue'),
  NSArray: cls('NSArray'),
};
const cgColorTypeID = CGColorGetTypeID().toString();

function num(x) {
  if (Number.isFinite(x)) return x;
  if (Number.isNaN(x)) return 'nan';
  return x > 0 ? 'inf' : '-inf';
}

// The script runtime's own number-to-text conversion is not exact: it wrote
// some doubles as text that parses to a neighbouring double. exactNumber
// prints the shortest decimal that parses back to exactly x, using integer
// arithmetic on x's bits; writeLine puts it into the JSON as a bare number.
const NUMBER_MARK = '\u0001';
const NUMBER_TEXT = /"\\u0001([^"]*)"/g;
const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);

function pow10(n) {
  return 10n ** BigInt(n);
}

function exactNumber(x) {
  if (x === 0) return '0';
  f64[0] = x;
  const bits = u64[0];
  const neg = (bits >> 63n) === 1n;
  const biased = (bits >> 52n) & 0x7ffn;
  const frac = bits & ((1n << 52n) - 1n);
  const m = biased === 0n ? frac : frac | (1n << 52n);
  const e = Number(biased === 0n ? -1074n : biased - 1075n);
  // |x| = m * 2^e. Everything below is in units of 2^(e-2): the value is 4m,
  // the gap to the next double up is 2, down is 1 at a power of two, else 2.
  const twoUp = e - 2 >= 0 ? 1n << BigInt(e - 2) : 1n;
  const twoDown = e - 2 < 0 ? 1n << BigInt(2 - e) : 1n;
  const lowGap = frac === 0n && biased > 1n ? 1n : 2n;
  const even = (m & 1n) === 0n;
  const p = Math.floor(Math.log10(Math.abs(x)));
  for (let n = 1; n <= 17; n++) {
    const k = p - n + 1; // candidate = D * 10^k
    const up10 = k > 0 ? pow10(k) : 1n;
    const down10 = k < 0 ? pow10(-k) : 1n;
    // Scaled to a common denominator twoDown * down10.
    const value = 4n * m * twoUp * down10;
    const unit = up10 * twoDown;
    let d = value / unit;
    const rest = value - d * unit;
    if (2n * rest > unit || (2n * rest === unit && (d & 1n) === 1n)) d += 1n;
    const diff = d * unit - value;
    const gap = (diff >= 0n ? 2n : lowGap) * twoUp * down10;
    const dist = diff >= 0n ? diff : -diff;
    if (dist < gap || (dist === gap && even)) return (neg ? '-' : '') + decimal(d.toString(), k);
  }
  throw new Error('exactNumber failed for ' + x);
}

function decimal(digits, k) {
  digits = digits.replace(/0+$/, z => { k += z.length; return ''; });
  if (digits === '') return '0';
  const point = digits.length + k; // position of the decimal point
  if (k >= 0 && point <= 21) return digits + '0'.repeat(k);
  if (point > 0 && point <= 21) return digits.slice(0, point) + '.' + digits.slice(point);
  if (point <= 0 && point > -6) return '0.' + '0'.repeat(-point) + digits;
  return digits[0] + (digits.length > 1 ? '.' + digits.slice(1) : '') + 'e' + (point - 1);
}

// NativeFunction 'bool' returns the number 0 or 1.
function isKind(obj, c) {
  return !!msgBP(obj, sel('isKindOfClass:'), c);
}

function bool(obj, name) {
  return !!msgB(obj, sel(name));
}

function className(obj) {
  return object_getClassName(obj).readUtf8String();
}

function str(nsString) {
  if (nsString.isNull()) return null;
  return msgP(nsString, sel('UTF8String')).readUtf8String();
}

// "{CGRect={CGPoint=dd}{CGSize=dd}}" -> "CGRect" when every member is a double.
function doubleStruct(type) {
  const m = /^\{([^=}]*)=/.exec(type);
  if (m === null) return null;
  const members = type.replace(/\{[^=}]*=/g, '').replace(/[{}]/g, '');
  return members.length > 0 && /^d+$/.test(members) ? m[1] : null;
}

function timingFunction(tf) {
  const pt = Memory.alloc(8);
  const points = [];
  for (let i = 0; i < 4; i++) {
    msgVUP(tf, sel('getControlPointAtIndex:values:'), i, pt);
    points.push([num(pt.readFloat()), num(pt.add(4).readFloat())]);
  }
  return { controlPoints: points };
}

function value(obj) {
  if (obj.isNull()) return null;
  if (CFGetTypeID(obj).toString() === cgColorTypeID) {
    const n = CGColorGetNumberOfComponents(obj).toNumber();
    const p = CGColorGetComponents(obj);
    const components = [];
    for (let i = 0; i < n; i++) components.push(num(p.add(i * 8).readDouble()));
    const space = CGColorGetColorSpace(obj);
    let colorSpace = null;
    if (!space.isNull()) {
      const name = CGColorSpaceCopyName(space);
      if (!name.isNull()) {
        colorSpace = str(name);
        CFRelease(name);
      }
    }
    return { colorSpace, components };
  }
  if (isKind(obj, C.NSString)) return str(obj);
  if (isKind(obj, C.NSNumber)) {
    return {
      objCType: msgP(obj, sel('objCType')).readUtf8String(),
      number: num(msgD(obj, sel('doubleValue'))),
    };
  }
  if (isKind(obj, C.NSValue)) {
    const typePtr = msgP(obj, sel('objCType'));
    const type = typePtr.readUtf8String();
    const sizeBuf = Memory.alloc(16);
    NSGetSizeAndAlignment(typePtr, sizeBuf, sizeBuf.add(8));
    const size = sizeBuf.readU64().toNumber();
    const buf = Memory.alloc(Math.max(size, 1));
    msgVPU(obj, sel('getValue:size:'), buf, size);
    const name = doubleStruct(type);
    if (name !== null) {
      const doubles = [];
      for (let i = 0; i < size / 8; i++) doubles.push(num(buf.add(i * 8).readDouble()));
      return { objCType: type, struct: name, doubles };
    }
    const bytes = new Uint8Array(buf.readByteArray(size));
    return { objCType: type, bytes: Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('') };
  }
  if (isKind(obj, C.NSArray)) return array(obj, value);
  if (isKind(obj, C.CAMediaTimingFunction)) return timingFunction(obj);
  const out = { class: className(obj), description: str(msgP(obj, sel('description'))) };
  if (isKind(obj, C.CAValueFunction)) out.name = str(msgP(obj, sel('name')));
  return out;
}

function array(nsArray, encode) {
  if (nsArray.isNull()) return null;
  const n = msgU(nsArray, sel('count')).toNumber();
  const out = [];
  for (let i = 0; i < n; i++) out.push(encode(msgPU(nsArray, sel('objectAtIndex:'), i)));
  return out;
}

function animation(a) {
  const tf = msgP(a, sel('timingFunction'));
  const out = {
    class: className(a),
    beginTime: num(msgD(a, sel('beginTime'))),
    duration: num(msgD(a, sel('duration'))),
    speed: num(msgF(a, sel('speed'))),
    timeOffset: num(msgD(a, sel('timeOffset'))),
    repeatCount: num(msgF(a, sel('repeatCount'))),
    repeatDuration: num(msgD(a, sel('repeatDuration'))),
    autoreverses: bool(a, 'autoreverses'),
    fillMode: str(msgP(a, sel('fillMode'))),
    removedOnCompletion: bool(a, 'isRemovedOnCompletion'),
    timingFunction: timingPoints(tf),
  };
  if (isKind(a, C.CAPropertyAnimation)) {
    out.keyPath = str(msgP(a, sel('keyPath')));
    out.additive = bool(a, 'isAdditive');
    out.cumulative = bool(a, 'isCumulative');
    out.valueFunction = value(msgP(a, sel('valueFunction')));
  }
  if (isKind(a, C.CABasicAnimation)) {
    out.fromValue = value(msgP(a, sel('fromValue')));
    out.toValue = value(msgP(a, sel('toValue')));
    out.byValue = value(msgP(a, sel('byValue')));
  }
  if (isKind(a, C.CAKeyframeAnimation)) {
    out.values = array(msgP(a, sel('values')), value);
    out.keyTimes = array(msgP(a, sel('keyTimes')), value);
    out.timingFunctions = array(msgP(a, sel('timingFunctions')), value);
    out.calculationMode = str(msgP(a, sel('calculationMode')));
  }
  if (isKind(a, C.CAAnimationGroup)) {
    out.animations = array(msgP(a, sel('animations')), animation);
  }
  return out;
}

function layer(l) {
  return {
    class: className(l),
    address: l.toString(),
    name: str(msgP(l, sel('name'))),
    speed: num(msgF(l, sel('speed'))),
    timeOffset: num(msgD(l, sel('timeOffset'))),
    beginTime: num(msgD(l, sel('beginTime'))),
  };
}

function caller(returnAddress) {
  const address = returnAddress.strip();
  const m = Process.findModuleByAddress(address);
  return m === null
    ? { module: null, offset: address.toString() }
    : { module: m.name, offset: '0x' + address.sub(m.base).toString(16) };
}

function utcStamp(d) {
  // 2026-10-17T03:04:05.123Z -> 20261017T030405.123Z
  return d.toISOString().replace(/[-:]/g, '');
}

const loadDate = new Date();
const path = getenv(Memory.allocUtf8String('HOME')).readUtf8String() +
  '/frida-gadget/ca-anim-' + utcStamp(loadDate) + '.jsonl';
const file = new File(path, 'wx');

function writeLine(obj) {
  const text = JSON.stringify(obj, (k, v) => typeof v === 'number' ? NUMBER_MARK + exactNumber(v) : v);
  file.write(text.replace(NUMBER_TEXT, '$1') + '\n');
  file.flush();
}

writeLine({
  type: 'header',
  frida: Frida.version,
  pid: Process.id,
  mediaTime: CACurrentMediaTime(),
  utc: loadDate.toISOString(),
});

const addAnimation = sel('addAnimation:forKey:');
const imp = class_getMethodImplementation(C.CALayer, addAnimation).strip();

function timingPoints(tf) {
  return tf.isNull() ? null : timingFunction(tf).controlPoints;
}

Interceptor.attach(imp, {
  onEnter(args) {
    this.record = null;
    try {
      const l = args[0];
      const superlayers = [];
      for (let s = msgP(l, sel('superlayer')); !s.isNull(); s = msgP(s, sel('superlayer'))) {
        superlayers.push(layer(s));
      }
      this.layer = l;
      this.key = args[3];
      this.keyPath = isKind(args[2], C.CAPropertyAnimation) ? msgP(args[2], sel('keyPath')) : NULL;
      this.record = {
        type: 'add',
        mediaTime: CACurrentMediaTime(),
        key: str(args[3]),
        layer: layer(l),
        superlayers,
        caller: caller(this.returnAddress),
        transaction: {
          animationDuration: num(msgD(C.CATransaction, sel('animationDuration'))),
          animationTimingFunction: timingPoints(msgP(C.CATransaction, sel('animationTimingFunction'))),
        },
        animation: animation(args[2]),
        stored: null,
      };
    } catch (e) {
      send({ type: 'error', message: String(e), stack: e.stack });
    }
  },
  onLeave() {
    if (this.record === null) return;
    try {
      if (!this.key.isNull()) {
        const a = msgPP(this.layer, sel('animationForKey:'), this.key);
        if (!a.isNull()) {
          this.record.stored = {
            duration: num(msgD(a, sel('duration'))),
            timingFunction: timingPoints(msgP(a, sel('timingFunction'))),
          };
        }
      }
      const keyPath = this.record.animation.keyPath;
      if (typeof keyPath === 'string') {
        this.record.modelValue = value(msgPP(this.layer, sel('valueForKeyPath:'), this.keyPath));
      }
      writeLine(this.record);
    } catch (e) {
      send({ type: 'error', message: String(e), stack: e.stack });
    }
  },
});

send({ type: 'file', path });
