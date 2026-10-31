// Test program for tools/re/frida/ca-anim.js. Adds a fixed set of animations
// with known values to a layer once per second and prints the same values, so
// a record written by ca-anim.js can be compared field by field. The layer sits
// under a parent layer whose speed, timeOffset and beginTime are not the
// defaults, to check the superlayer timing fields. Needs no window server: the
// animations are only added, never shown. The parent is the root layer of a
// local CAContext (private API, +[CAContext localContext], used only so that
// property changes create implicit animations; verified on macOS 15.6.1 and
// macOS 27.0.1): without a context a layer has no implicit actions.
//
// Output: one line "expect <key-prefix> <JSON>" per animation of the set (the
// same in every round), "expect superlayer <JSON>" for the parent layer, then
// "round <n> mediaTime <t>" for each round. A key in the record is
// "<key-prefix>-<n>"; the implicit animation's key is "opacity". Field paths
// are relative to the record's animation unless they start with animation.,
// transaction., stored. or modelValue.
//
// Build on the host (arm64, runs on the macOS 15 reference VM):
//   swiftc -target arm64-apple-macos15.0 -o .build/ca-anim-fixture tools/re/frida/ca-anim-fixture.swift
// Run in the VM with frida-gadget loaded (it listens on 27044 while Dock holds 27043):
//   DYLD_INSERT_LIBRARIES=$HOME/frida-gadget/frida-gadget.dylib ~/frida-gadget/ca-anim-fixture [seconds]
// seconds defaults to 30.

import Foundation
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)
let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 30

let parent = CALayer()
parent.name = "fixture-parent"
parent.speed = 0.75
parent.timeOffset = 0.25
parent.beginTime = 0.125
let layer = CALayer()
layer.name = "fixture-child"
parent.addSublayer(layer)
let context = (NSClassFromString("CAContext")! as AnyObject)
    .perform(NSSelectorFromString("localContext"))!.takeUnretainedValue() as! NSObject
context.setValue(parent, forKey: "layer")
CATransaction.flush()

func json(_ d: Double) -> String { "\(d)" }
func json(_ ds: [Double]) -> String { "[" + ds.map(json).joined(separator: ",") + "]" }

func doubles(_ t: CATransform3D) -> [Double] {
    [t.m11, t.m12, t.m13, t.m14, t.m21, t.m22, t.m23, t.m24,
     t.m31, t.m32, t.m33, t.m34, t.m41, t.m42, t.m43, t.m44].map(Double.init)
}

func controlPoints(_ f: CAMediaTimingFunction) -> String {
    var pts: [String] = []
    for i in 0..<4 {
        var v: [Float] = [0, 0]
        f.getControlPoint(at: i, values: &v)
        pts.append(json([Double(v[0]), Double(v[1])]))
    }
    return "[" + pts.joined(separator: ",") + "]"
}

var expectations: [(String, String)] = []
func expect(_ key: String, _ fields: [(String, String)]) {
    let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
    expectations.append((key, "{" + body + "}"))
}

// 1. Basic animation, CATransform3D values, every timing property non-default.
var from3D = CATransform3DMakeRotation(0.3, 0.2, 0.5, 0.8)
from3D.m34 = -1.0 / 850.0
let to3D = CATransform3DScale(CATransform3DMakeTranslation(12.5, -7.25, 3.0), 1.1, 0.9, 1.3)
let customTF = CAMediaTimingFunction(controlPoints: 0.1, 0.2, 0.3, 0.9)
func basicTransform() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "transform")
    a.fromValue = NSValue(caTransform3D: from3D)
    a.toValue = NSValue(caTransform3D: to3D)
    a.beginTime = 0.5
    a.duration = 1.25
    a.speed = 1.3
    a.timeOffset = 0.125
    a.repeatCount = 2.7
    a.repeatDuration = 3.75
    a.autoreverses = true
    a.fillMode = .both
    a.isRemovedOnCompletion = false
    a.timingFunction = customTF
    a.isAdditive = true
    a.isCumulative = true
    return a
}
expect("fx-basic", [
    ("class", "\"CABasicAnimation\""), ("keyPath", "\"transform\""),
    ("beginTime", json(0.5)), ("duration", json(1.25)), ("speed", json(Double(Float(1.3)))),
    ("timeOffset", json(0.125)), ("repeatCount", json(Double(Float(2.7)))), ("repeatDuration", json(3.75)),
    ("autoreverses", "true"), ("fillMode", "\"both\""), ("removedOnCompletion", "false"),
    ("timingFunction", controlPoints(customTF)), ("additive", "true"), ("cumulative", "true"),
    ("fromValue.doubles", json(doubles(from3D))), ("toValue.doubles", json(doubles(to3D))),
])

// 2. Keyframe animation, CGPoint values.
let kfPoints = [CGPoint(x: 1.5, y: 2.25), CGPoint(x: 100.125, y: -40.5), CGPoint(x: 333.0, y: 0.0625)]
let kfTimes: [Double] = [0, 0.3, 1]
let kfTFs = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)]
func keyframe() -> CAKeyframeAnimation {
    let a = CAKeyframeAnimation(keyPath: "position")
    a.values = kfPoints.map { NSValue(point: $0) }
    a.keyTimes = kfTimes.map { NSNumber(value: $0) }
    a.timingFunctions = kfTFs
    a.calculationMode = .cubic
    a.duration = 0.8
    return a
}
expect("fx-keyframe", [
    ("class", "\"CAKeyframeAnimation\""), ("keyPath", "\"position\""), ("duration", json(0.8)),
    ("values.doubles", "[" + kfPoints.map { json([Double($0.x), Double($0.y)]) }.joined(separator: ",") + "]"),
    ("keyTimes.number", json(kfTimes)),
    ("timingFunctions.controlPoints", "[" + kfTFs.map(controlPoints).joined(separator: ",") + "]"),
    ("calculationMode", "\"cubic\""),
])

// 3. Group: basic (Float NSNumber values) then keyframe (CGRect values).
let groupRects = [CGRect(x: 0, y: 0, width: 64, height: 64), CGRect(x: -8.5, y: 4.25, width: 80.75, height: 72.5)]
func group() -> CAAnimationGroup {
    let o = CABasicAnimation(keyPath: "opacity")
    o.fromValue = NSNumber(value: Float(0.2))
    o.toValue = NSNumber(value: Float(0.8))
    let b = CAKeyframeAnimation(keyPath: "bounds")
    b.values = groupRects.map { NSValue(rect: $0) }
    let g = CAAnimationGroup()
    g.animations = [o, b]
    g.duration = 2
    return g
}
expect("fx-group", [
    ("class", "\"CAAnimationGroup\""), ("duration", json(2)),
    ("animations.class", "[\"CABasicAnimation\",\"CAKeyframeAnimation\"]"),
    ("animations.0.fromValue.number", json(Double(Float(0.2)))), ("animations.0.toValue.number", json(Double(Float(0.8)))),
    ("animations.0.fromValue.objCType", "\"f\""),
    ("animations.1.values.doubles", "[" + groupRects.map {
        json([Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)]) }.joined(separator: ",") + "]"),
])

// 4. Colors.
let fromColor = CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
let toColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.5, 0.6, 0.7, 1.0])!
func color() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "backgroundColor")
    a.fromValue = fromColor
    a.toValue = toColor
    return a
}
expect("fx-color", [
    ("fromValue.colorSpace", "\"kCGColorSpaceSRGB\""), ("fromValue.components", json([0.1, 0.2, 0.3, 0.4])),
    ("toValue.colorSpace", "\"kCGColorSpaceDisplayP3\""), ("toValue.components", json([0.5, 0.6, 0.7, 1.0])),
])

// 5. CGPoint byValue, CGRect from/to.
let byPoint = CGPoint(x: 7.75, y: -3.5)
let fromRect = CGRect(x: 1, y: 2, width: 3, height: 4)
let toRect = CGRect(x: 10.5, y: 20.25, width: 30.125, height: 40.0625)
func pointBy() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "position")
    a.byValue = NSValue(point: byPoint)
    return a
}
func rect() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "bounds")
    a.fromValue = NSValue(rect: fromRect)
    a.toValue = NSValue(rect: toRect)
    return a
}
expect("fx-point", [("byValue.struct", "\"CGPoint\""), ("byValue.doubles", json([Double(byPoint.x), Double(byPoint.y)]))])
expect("fx-rect", [
    ("fromValue.struct", "\"CGRect\""), ("fromValue.doubles", json([1, 2, 3, 4])),
    ("modelValue.struct", "\"CGRect\""), ("modelValue.doubles", json([0, 0, 0, 0])),
    ("toValue.doubles", json([10.5, 20.25, 30.125, 40.0625])),
])

// 6. Value function with Double NSNumber values.
func rotate() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "transform")
    a.valueFunction = CAValueFunction(name: .rotateZ)
    a.fromValue = NSNumber(value: 0.0)
    a.toValue = NSNumber(value: Double.pi / 2)
    return a
}
expect("fx-rotate", [
    ("valueFunction.name", "\"rotateZ\""), ("fromValue.objCType", "\"d\""), ("toValue.number", json(Double.pi / 2)),
])

for (key, body) in expectations { print("expect \(key) \(body)") }
print("expect superlayer {\"class\":\"CALayer\",\"name\":\"fixture-parent\",\"speed\":\(json(Double(parent.speed))),\"timeOffset\":\(json(parent.timeOffset)),\"beginTime\":\(json(parent.beginTime))}")

// 7. Implicit animation: a property change inside a transaction with a set
// duration and timing function. Key "opacity" (chosen by Core Animation).
let implicitTF = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
let implicitPoints = controlPoints(implicitTF)
print("expect implicit {\"animation.keyPath\":\"opacity\",\"animation.duration\":\(json(0)),"
    + "\"transaction.animationDuration\":\(json(0.7)),\"transaction.animationTimingFunction\":\(implicitPoints),"
    + "\"stored.duration\":\(json(0.7)),\"stored.timingFunction\":\(implicitPoints),"
    + "\"animation.fromValue.number\":\(json(1)),\"modelValue.number\":\(json(0.25))}")

for round in 0..<seconds {
    print("round \(round) mediaTime \(CACurrentMediaTime())")
    layer.add(basicTransform(), forKey: "fx-basic-\(round)")
    layer.add(keyframe(), forKey: "fx-keyframe-\(round)")
    layer.add(group(), forKey: "fx-group-\(round)")
    layer.add(color(), forKey: "fx-color-\(round)")
    layer.add(pointBy(), forKey: "fx-point-\(round)")
    layer.add(rect(), forKey: "fx-rect-\(round)")
    layer.add(rotate(), forKey: "fx-rotate-\(round)")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    CATransaction.commit()
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.7)
    CATransaction.setAnimationTimingFunction(implicitTF)
    layer.opacity = 0.25
    CATransaction.commit()
    Thread.sleep(forTimeInterval: 1)
}
