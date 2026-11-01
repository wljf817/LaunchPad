import Foundation

// Private CoreFoundation interface used by the tests only. Verified on macOS 27.2 (26B123).

/// Drops CoreFoundation's cached current locale and the user language that localized string
/// comparisons use, so they read the preferred languages again.
@_silgen_name("_CFLocaleResetCurrent")
func _CFLocaleResetCurrent()
