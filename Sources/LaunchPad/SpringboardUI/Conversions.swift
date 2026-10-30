import Foundation

/// A double converted to a 64-bit integer the way the original's arm64 code converts it (`fcvtzs`):
/// toward zero, saturating at the limits, 0 for NaN. Swift's own conversion traps instead.
func saturatingInt64(_ value: Double) -> Int64 {
    if value.isNaN {
        return 0
    }
    if value >= 9_223_372_036_854_775_807 {
        return .max
    }
    if value <= -9_223_372_036_854_775_808 {
        return .min
    }
    return Int64(value)
}

/// A number rounded to the nearest integer, halves toward zero: ceil(x − 0.5) above 0, otherwise
/// floor(x + 0.5). The original's own helper, used for the selection layer's corner radius
/// (REF-KEYBOARD-004).
func roundHalfTowardZero(_ value: Double) -> Double {
    value > 0 ? (value - 0.5).rounded(.up) : (value + 0.5).rounded(.down)
}
