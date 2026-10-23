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
