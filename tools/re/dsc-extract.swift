// Split a dyld shared cache into standalone Mach-O images for static analysis.
//
// Private API: dyld_shared_cache_extract_dylibs_progress, exported by
// /usr/lib/dsc_extractor.bundle, which ships with macOS. It is undocumented;
// this file is the only place it is declared.
// Purpose: give REA and Hopper one Mach-O file per image of the reference VM's
// cache, since they cannot pick an image out of a cache themselves.
// Verified on the host: macOS 27.0.1 (26A434) loads the bundle, resolves the
// symbol, extracts images from its own cache, and extracts all 3,257 images
// of the macOS 15.6.1 (24G90) arm64e cache.
//
// Usage: swift tools/re/dsc-extract.swift <dyld_shared_cache_arm64e> <output-dir>
// Keep the output under research/ (clean room).

import Foundation

typealias ExtractFunction = @convention(c) (
    UnsafePointer<CChar>,
    UnsafePointer<CChar>,
    @convention(block) (UInt32, UInt32) -> Void
) -> Int32

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let bundlePath = "/usr/lib/dsc_extractor.bundle"
guard let bundle = dlopen(bundlePath, RTLD_NOW) else {
    fail("cannot load \(bundlePath): \(dlerror().map { String(cString: $0) } ?? "unknown error")", status: 1)
}
guard let symbol = dlsym(bundle, "dyld_shared_cache_extract_dylibs_progress") else {
    fail("dyld_shared_cache_extract_dylibs_progress not found in \(bundlePath)", status: 1)
}
let extract = unsafeBitCast(symbol, to: ExtractFunction.self)

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: swift tools/re/dsc-extract.swift <dyld_shared_cache_arm64e> <output-dir>", status: 2)
}

let status = extract(arguments[1], arguments[2]) { current, total in
    if current % 500 == 0 || current == total {
        print("\(current)/\(total)")
    }
}
exit(status)
