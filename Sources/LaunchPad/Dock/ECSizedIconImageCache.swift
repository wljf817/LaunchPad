import CoreGraphics
import Foundation
import LaunchPadPrivate
import os

/// Dock's cache of icons rendered at a size and scale factor as Core Animation render images
/// (REF-GRID-012). Launchpad uses it only for the placeholder of an item whose icon has not arrived:
/// for a nil icon it renders a default binding; for any other icon it only returns an entry that is
/// already cached.
@objc(ECSizedIconImageCache)
final class ECSizedIconImageCache: NSObject {
    /// Keyed by (IconRef or 0, size, truncated scale factor); the render objects are held weakly.
    @MainActor private static let renders = NSMapTable<NSData, ECSizedIconImageCacheRenderObject>(
        keyOptions: .strongMemory, valueOptions: .weakMemory, capacity: 0)
    /// The binding rendered for a nil icon, made once.
    @MainActor private static var defaultBinding: CFTypeRef?

    @MainActor
    @objc(entryWithIcon:forSize:andScaleFactor:)
    static func entry(withIcon icon: AnyObject?, forSize size: Int32, andScaleFactor scaleFactor: Float)
        -> ECSizedIconImageCacheEntry? {
        let key = cacheKey(icon, size, scaleFactor)
        if let found = renders.object(forKey: key)?.entry() {
            return found
        }
        guard icon == nil else { return nil }
        if defaultBinding == nil {
            // REF-GRID-012: type 0, creator 0x6e6c6464.
            defaultBinding = _LSBindingCreateWithTypeInfo(nil, 0, 0x6e6c6464, nil, 0)
        }
        guard let binding = defaultBinding,
              let render = ECSizedIconImageCacheRenderObject(icon: binding, andSize: size, usingScaleFactor: scaleFactor)
        else { return nil }
        renders.setObject(render, forKey: key)
        return render.entry()
    }

    @MainActor
    @objc(removeEntryForIcon:withSize:andScaleFactor:)
    static func removeEntry(forIcon icon: AnyObject?, withSize size: Int32, andScaleFactor scaleFactor: Float) {
        renders.removeObject(forKey: cacheKey(icon, size, scaleFactor))
    }

    /// 16 bytes: the icon's IconRef (0 without an icon), the size and the scale factor truncated.
    private static func cacheKey(_ icon: AnyObject?, _ size: Int32, _ scaleFactor: Float) -> NSData {
        var bytes = (UInt(0), size, Int32(scaleFactor))
        if let icon {
            bytes.0 = UInt(bitPattern: _LSBindingGetIconRef(icon))
        }
        return withUnsafeBytes(of: &bytes) { NSData(bytes: $0.baseAddress, length: 16) }
    }
}

/// An icon rendered at a size (points) and scale factor into a render image; counts its entries and
/// leaves the cache when the last one goes.
@objc(ECSizedIconImageCacheRenderObject)
final class ECSizedIconImageCacheRenderObject: NSObject, @unchecked Sendable {
    let _icon: AnyObject
    let _size: UInt16
    let _scaleFactor: Float
    let _image: CARenderImageRef
    var _count: UInt32 = 0

    @MainActor
    @objc(initWithIcon:andSize:usingScaleFactor:)
    init?(icon: AnyObject, andSize size: Int32, usingScaleFactor scaleFactor: Float) {
        guard let image = Self.iconImage(icon, size: CGFloat(size), scaleFactor: CGFloat(scaleFactor)) else { return nil }
        let pixels = Int(Float(size) * scaleFactor)
        guard let render = renderImage(width: pixels, height: pixels, tag: 0xf8, draw: { context in  // REF-GRID-012: VM tag 248
            context.saveGState()
            CGContextSetCompositeOperation(context, 1)
            context.scaleBy(x: CGFloat(scaleFactor), y: CGFloat(scaleFactor))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
            context.restoreGState()
            context.flush()
        }) else { return nil }
        _icon = icon
        _size = UInt16(truncatingIfNeeded: size)
        _scaleFactor = scaleFactor
        _image = render
        super.init()
    }

    deinit {
        CARenderRelease(UnsafeMutableRawPointer(_image))
    }

    /// The binding's image from IconServices at size × size points and the scale factor, on the
    /// Dock's background style (REF-GRID-012).
    @MainActor
    private static func iconImage(_ binding: AnyObject, size: CGFloat, scaleFactor: CGFloat) -> CGImage? {
        let icon = ISIcon(binding: binding)
        let descriptor = ISImageDescriptor(size: CGSize(width: size, height: size), scale: scaleFactor)
        descriptor.backgroundStyle = dockGlobals.darkDock ? 1 : 0
        icon.prepareImages(for: [descriptor])
        let image = icon.image(for: descriptor)
        if image?.placeholder == true {
            Logger().debug("The icon image is a placeholder")
        }
        guard let cgImage = image?.cgImage else {
            Logger().debug("No icon image")
            return nil
        }
        return cgImage
    }

    var image: CARenderImageRef { _image }

    @objc func entry() -> ECSizedIconImageCacheEntry {
        _count += 1
        return ECSizedIconImageCacheEntry(renderObject: self)
    }

    /// Note that the cache's key for this object was made without an icon when the icon is the
    /// default binding, so removing by its own icon does not find it; the weak table drops it.
    @MainActor
    @objc func removeEntry() {
        guard _count != 0 else { return }
        _count -= 1
        if _count == 0 {
            ECSizedIconImageCache.removeEntry(forIcon: _icon, withSize: Int32(_size), andScaleFactor: _scaleFactor)
        }
    }
}

/// A reference to a rendered icon; usable as a layer's contents through `-CA_copyRenderValue`.
@objc(ECSizedIconImageCacheEntry)
final class ECSizedIconImageCacheEntry: NSObject, @unchecked Sendable {
    let _render: ECSizedIconImageCacheRenderObject

    @objc(initWithRenderObject:)
    init(renderObject: ECSizedIconImageCacheRenderObject) {
        _render = renderObject
        super.init()
    }

    deinit {
        let render = UncheckedBox(_render)
        if Thread.isMainThread {
            MainActor.assumeIsolated { render.value.removeEntry() }
        } else {
            DispatchQueue.main.async { render.value.removeEntry() }
        }
    }

    @objc var width: UInt32 { UInt32(CARenderImageGetWidth(_render.image)) }
    @objc var height: UInt32 { UInt32(CARenderImageGetHeight(_render.image)) }

    /// The render image as a `CGImage`.
    @objc var image: AnyObject? { CARenderImageCopyCGImage(_render.image) }

    @objc func CA_copyRenderValue() -> UnsafeMutableRawPointer? {
        CARenderRetain(UnsafeMutableRawPointer(_render.image))
    }
}
