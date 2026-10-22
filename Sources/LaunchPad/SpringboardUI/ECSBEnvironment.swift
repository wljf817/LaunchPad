import CoreText
import LaunchPadPrivate

/// The fonts and sizes the grid's layers share (REF-ARCH-013). So far only the label font is used,
/// for the icon size (REF-GRID-006); drawing the names comes with 1.3.3.
@MainActor
@objc(ECSBEnvironment)
final class ECSBEnvironment: NSObject {
    private static var sharedEnvironment: ECSBEnvironment?

    /// A `CTFont`, typed as an object as in the original.
    var _labelFont: AnyObject?
    var _labelFontType: UInt32
    var _labelFontSize: Int

    /// Created on first use.
    @objc static var shared: ECSBEnvironment {
        if let sharedEnvironment {
            return sharedEnvironment
        }
        let environment = ECSBEnvironment()
        sharedEnvironment = environment
        return environment
    }

    override init() {
        // REF-GRID-006: UI font type 105, 13 points.
        _labelFontSize = 13
        _labelFontType = 105
        super.init()
        _createFont()
    }

    @objc var labelFontType: UInt32 {
        get { _labelFontType }
        set {
            guard _labelFontType != newValue else { return }
            _labelFontType = newValue
            _createFont()
        }
    }

    @objc var labelFontSize: Int {
        get { _labelFontSize }
        set {
            guard _labelFontSize != newValue else { return }
            _labelFontSize = newValue
            _createFont()
        }
    }

    @objc var labelFont: CTFont {
        _labelFont as! CTFont
    }

    /// The UI font of the type and size, with monospaced numbers (feature type 6, selector 0;
    /// REF-GRID-006).
    @objc func _createFont() {
        let descriptor = CTFontDescriptorCreateForUIType(CTFontUIFontType(rawValue: _labelFontType)!,
                                                         CGFloat(_labelFontSize), nil)!
        var type: Int32 = 6
        var selector: Int32 = 0
        let numbers = CTFontDescriptorCreateCopyWithFeature(descriptor, CFNumberCreate(nil, .intType, &type),
                                                            CFNumberCreate(nil, .intType, &selector))
        _labelFont = CTFontCreateWithFontDescriptor(numbers, 0, nil)
    }
}
