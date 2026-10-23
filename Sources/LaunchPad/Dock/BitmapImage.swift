import CoreGraphics
import Darwin
import LaunchPadPrivate

// Dock's helpers that draw into a bitmap over anonymous mmap'd memory and wrap it as an image
// (REF-GRID-012): bytes per row rounded up to 64, 8 bits per component, premultiplied alpha first,
// 32-bit little endian; the bitmap context is kept per thread and pointed at the new memory each
// time; the memory is made read-only after drawing and unmapped with the image.

private let bitmapInfo: UInt32 = 0x2002  // REF-GRID-012: kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little

/// The two per-thread contexts: sRGB and device RGB.
private let contextKeys: (sRGB: pthread_key_t, device: pthread_key_t) = {
    var sRGB = pthread_key_t()
    var device = pthread_key_t()
    pthread_key_create(&sRGB, nil)
    pthread_key_create(&device, nil)
    return (sRGB, device)
}()

/// The memory, its size and its row length for a bitmap of `width` × `height`, tagged for VM
/// accounting with `tag`.
private func mapBitmap(width: Int, height: Int, tag: Int32) -> (UnsafeMutableRawPointer, Int, Int)? {
    let bytesPerRow = (width * 4 + 63) & ~63  // REF-GRID-012: rows aligned to 64 bytes
    let size = bytesPerRow * height
    guard let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, tag << 24, 0),
          memory != MAP_FAILED else { return nil }
    return (memory, size, bytesPerRow)
}

/// This thread's bitmap context, made the first time and pointed at `memory` afterwards.
private func threadContext(sRGB: Bool, memory: UnsafeMutableRawPointer, width: Int, height: Int,
                           bytesPerRow: Int) -> CGContext? {
    let key = sRGB ? contextKeys.sRGB : contextKeys.device
    if let existing = pthread_getspecific(key) {
        let context = Unmanaged<CGContext>.fromOpaque(existing).takeUnretainedValue()
        CGBitmapContextSetData(context, 0, 0, width, height, memory, 8, 32, bytesPerRow)
        return context
    }
    let space = sRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: memory, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo) else { return nil }
    pthread_setspecific(key, Unmanaged.passRetained(context).toOpaque())
    return context
}

private func protect(_ memory: UnsafeMutableRawPointer, _ size: Int) {
    vm_protect(mach_task_self_, vm_address_t(UInt(bitPattern: memory)), vm_size_t(size), 1, VM_PROT_READ)
}

/// A `CGImage` of `width` × `height` drawn by `draw`.
func bitmapImage(sRGB: Bool, width: Int, height: Int, tag: Int32, draw: (CGContext) -> Void) -> CGImage? {
    guard let (memory, size, bytesPerRow) = mapBitmap(width: width, height: height, tag: tag) else { return nil }
    guard let context = threadContext(sRGB: sRGB, memory: memory, width: width, height: height, bytesPerRow: bytesPerRow) else {
        munmap(memory, size)
        return nil
    }
    draw(context)
    protect(memory, size)
    guard let provider = CGDataProvider(dataInfo: nil, data: memory, size: size, releaseData: { _, data, size in
        munmap(UnsafeMutableRawPointer(mutating: data), size)
    }) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                   space: context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}

/// A Core Animation render image of `width` × `height` drawn by `draw`, over sRGB memory.
func renderImage(width: Int, height: Int, tag: Int32, draw: (CGContext) -> Void) -> CARenderImageRef? {
    guard let (memory, size, bytesPerRow) = mapBitmap(width: width, height: height, tag: tag) else { return nil }
    guard let context = threadContext(sRGB: true, memory: memory, width: width, height: height, bytesPerRow: bytesPerRow) else {
        munmap(memory, size)
        return nil
    }
    draw(context)
    protect(memory, size)
    var rowBytes = bytesPerRow
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let image = CARenderImageNewMipmapped(1, width, height, 1, space, memory, &rowBytes, { data, size in
        munmap(data, size)
    }, size) else {
        munmap(memory, size)
        return nil
    }
    return image
}
