import CoreGraphics
import Foundation
import ImageIO
import LaunchPadPrivate

/// Dock's cache of images in the main bundle by name and scale factor (REF-SEARCH-003). Lookups,
/// new entries and removals happen synchronously on its serial queue; an entry loads its image when
/// asked for it.
@objc(ECMultiScaleImageCache)
final class ECMultiScaleImageCache: NSObject, @unchecked Sendable {
    /// Created on first use.
    @objc static let sharedCache = ECMultiScaleImageCache()

    let _cache: NSMutableDictionary
    let _queue: DispatchQueue

    override init() {
        _cache = NSMutableDictionary(capacity: 0)
        _queue = DispatchQueue(label: "multiscaleimagecache")  // REF-SEARCH-003
        super.init()
    }

    /// The entry of the name at the scale factor, created when missing. A new entry at scale 1 or 2
    /// drops the entry of the other one when `removingOtherScaleFactors` (REF-SEARCH-003).
    @objc(imageWithName:andScaleFactor:removingOtherScaleFactors:)
    func image(withName name: String, andScaleFactor scaleFactor: Float, removingOtherScaleFactors: Bool) -> Any? {
        let entry: ECMultiScaleImage = _queue.sync {
            let key = Self.key(name, scaleFactor)
            if let found = _cache[key] as? ECMultiScaleImage {
                return found
            }
            let created = ECMultiScaleImage(name: name, usingScaleFactor: scaleFactor)
            _cache[key] = created
            if removingOtherScaleFactors && (scaleFactor == 1 || scaleFactor == 2) {
                _cache.removeObject(forKey: Self.key(name, 3 - scaleFactor))
            }
            return created
        }
        return entry.image
    }

    /// The original's key format is not visible from outside; this one is used only here (design
    /// decision 4).
    static func key(_ name: String, _ scaleFactor: Float) -> String {
        "\(name)-\(UInt32(scaleFactor))"
    }
}

/// An image of the main bundle at one scale factor, read from its file the first time it is asked
/// for and kept from then on (REF-SEARCH-003).
@objc(ECMultiScaleImage)
final class ECMultiScaleImage: NSObject, @unchecked Sendable {
    let _name: String
    let _scaleFactor: Float
    var _image: CGImage?

    @objc(initWithName:usingScaleFactor:)
    init(name: String, usingScaleFactor scaleFactor: Float) {
        _name = name
        _scaleFactor = scaleFactor
        super.init()
    }

    @objc var name: String { _name }

    /// `<name>.png` at scale 1, otherwise `<name>@<n>x.png`, falling back to `<name>.png` above
    /// scale 1. A file that is not found is looked for again next time (REF-SEARCH-003).
    /// Typed as an object, as in the original; the value is a `CGImage`.
    @objc var image: Any? {
        if _image == nil {
            let fileName = _scaleFactor == 1 ? "\(_name).png" : "\(_name)@\(Int32(_scaleFactor))x.png"
            var loaded = Self.image(launchPadBundle, fileName)
            if loaded == nil && _scaleFactor > 1 {
                loaded = Self.image(launchPadBundle, "\(_name).png")
            }
            if let loaded {
                _image = loaded
            }
        }
        return _image
    }

    private static func image(_ bundle: Bundle, _ fileName: String) -> CGImage? {
        guard let url = bundle.url(forResource: fileName, withExtension: nil),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options = [kCGImageSourceSkipMetadata: true, kCGImageSourceShouldCache: false] as CFDictionary  // REF-SEARCH-003
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
