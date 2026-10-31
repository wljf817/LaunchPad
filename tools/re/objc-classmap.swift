// Objective-C class map of a Mach-O image, and comparison of two class maps.
//
// Purpose: list, for every Objective-C class of the macOS 15 Dock (where the
// original Launchpad lives) or of a LaunchPad build, its superclass, adopted
// protocols, ivars with types and ownership, declared properties and methods
// with type encodings; then check that LaunchPad's classes follow the
// original's names, relationships and signatures.
//
// Usage:
//   swift tools/re/objc-classmap.swift map <thin Mach-O> <REA dispatch metadata JSON> <output.txt>
//   swift tools/re/objc-classmap.swift compare <original map> <other map>
//
// The REA JSON is the output of
//   rea inspect-native-dispatch-metadata <thin Mach-O> --max-records 20000 --format json --full-output
// for the same file. Keep the inputs and the output under research/ (clean room).
//
// Where each item comes from (every class block names its sources):
//   - REA: class list, superclass, protocols, ivar names and type encodings,
//     declared properties and their attributes, protocol selectors.
//   - dyld_info -objc: complete class list (REA stops at its record limit and
//     skips some Swift classes), categories, method selectors by implementation
//     address.
//   - otool -oV: method type encodings by implementation address, ivar layouts
//     (strong and weak bitmaps) and instanceStart, which give ivar ownership.
//     Its ivar names are unreliable in chained-fixup images (unresolved name
//     pointers print as an unrelated symbol), so ivars come from REA and fall
//     back to otool only for classes REA has no record of; unresolved names
//     print as "?".
//
// compare reports, for each class of the other map that has a class of the
// same name in the original: a different superclass, protocols the original
// class does not adopt, methods the original class does not have, methods
// whose type encodings differ (stack offsets and class names in object types
// removed first), ivars without an original counterpart (an ivar "x" matches
// the original "_x" or "x"); and classes the original does not have.
// .cxx_destruct and .cxx_construct are ignored. Exit status 1 when anything
// is reported, 0 when the maps agree.

import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let usage = """
usage: swift tools/re/objc-classmap.swift map <thin Mach-O> <REA dispatch metadata JSON> <output.txt>
       swift tools/re/objc-classmap.swift compare <original map> <other map>
"""

func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [tool] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot run \(tool): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}

func firstMatch(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { fail("bad pattern \(pattern)") }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (0..<match.numberOfRanges).map { index in
        let r = match.range(at: index)
        return r.location == NSNotFound ? "" : String(text[Range(r, in: text)!])
    }
}

// MARK: - map

struct Method { var kind: Character; var selector: String; var types: String }
struct Ivar { var name: String; var type: String; var offset: Int }

struct ClassRecord {
    var name: String
    var superclass = ""
    var protocols: [String] = []
    var instanceStart = 0
    var strongLayout: [UInt8] = []
    var weakLayout: [UInt8] = []
    var methods: [Method] = []
    var otoolIvars: [Ivar] = []
}

struct CategoryRecord { var className: String; var name: String; var methods: [Method] = [] }

/// Implementation address -> (kind, selector), plus superclass and protocols per class.
func parseDyldInfo(_ text: String) -> (selectors: [UInt64: (Character, String)], headers: [String: (String, [String])], categories: [String]) {
    var selectors: [UInt64: (Character, String)] = [:]
    var headers: [String: (String, [String])] = [:]
    var categories: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
        if let m = firstMatch(#"^\s+@interface (\S+) : (\S+)\s*(?:<(.*)>)?"#, line) {
            let protocols = m[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            headers[m[1]] = (m[2], protocols)
        } else if let m = firstMatch(#"^\s+@interface (\S+\(\S+\))\s*$"#, line) {
            categories.append(m[1])
        } else if let m = firstMatch(#"^\s+0x([0-9A-Fa-f]+)\s+([-+])\[\S+ (.+)\]$"#, line) {
            selectors[UInt64(m[1], radix: 16)!] = (Character(m[2]), m[3])
        }
    }
    return (selectors, headers, categories)
}

func layoutBytes(_ text: String) -> [UInt8] {
    text.split(separator: " ").compactMap { UInt8($0.dropFirst(2), radix: 16) }
}

func parseOtool(_ text: String, selectors: [UInt64: (Character, String)]) -> (classes: [String: ClassRecord], categories: [CategoryRecord]) {
    var classes: [String: ClassRecord] = [:]
    var categories: [CategoryRecord] = []
    var section = ""
    var current: ClassRecord?
    var isMeta = false
    var block = ""
    var lastLayout = ""
    var pendingTypes = ""
    var pendingName = ""
    var ivar = Ivar(name: "?", type: "", offset: 0)
    var category: CategoryRecord?
    var categoryBlock = ""

    func flush() {
        if var record = current {
            if let existing = classes[record.name] {
                // Merge the metaclass record (class methods) into the class record.
                var merged = existing
                if isMeta { merged.methods += record.methods } else {
                    record.methods = record.methods + existing.methods
                    merged = record
                }
                classes[record.name] = merged
            } else {
                classes[record.name] = record
            }
        }
        current = nil
        if let c = category { categories.append(c) }
        category = nil
    }

    func method(kind: Character, imp: UInt64) -> Method {
        let known = selectors[imp]
        return Method(kind: known?.0 ?? kind, selector: known?.1 ?? (pendingName.isEmpty ? "?" : pendingName), types: pendingTypes)
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
        if line.hasPrefix("Contents of ") { flush(); section = line; continue }
        if section.contains("__objc_classlist") {
            if firstMatch(#"^[0-9a-f]{16} 0x"#, line) != nil { flush(); current = ClassRecord(name: ""); isMeta = false; block = ""; continue }
            if line == "Meta Class" { flush(); current = ClassRecord(name: ""); isMeta = true; block = ""; continue }
            guard current != nil else { continue }
            if let m = firstMatch(#"^ {8}([a-zA-Z][a-zA-Z ]*[a-zA-Z])\s+(.*)$"#, line) {
                let key = m[1], value = m[2]
                switch key {
                case "name": current!.name = String(value.split(separator: " ").last ?? "")
                case "instanceStart": current!.instanceStart = Int(value) ?? 0
                case "ivarLayout", "weakIvarLayout": lastLayout = key
                case "layout map":
                    if lastLayout == "ivarLayout" { current!.strongLayout = layoutBytes(value) } else { current!.weakLayout = layoutBytes(value) }
                default: break
                }
                block = key
                continue
            }
            if block == "baseMethods" {
                if let m = firstMatch(#"^ {12}name\s+0x[0-9a-f]+ ([^(\s]\S*)$"#, line) { pendingName = m[1] }
                if let m = firstMatch(#"^ {12}types\s+0x[0-9a-f]+(?: \(0x[0-9a-f]+\))? (.+)$"#, line) { pendingTypes = m[1] }
                if let m = firstMatch(#"^ {12}imp\s+0x([0-9a-f]+)(?: \(0x([0-9a-f]+)\))?"#, line) {
                    let imp = UInt64(m[2].isEmpty ? m[1] : m[2], radix: 16)!
                    current!.methods.append(method(kind: isMeta ? "+" : "-", imp: imp))
                    pendingName = ""
                }
            } else if block == "ivars" {
                if let m = firstMatch(#"^ {12}offset\s+0x[0-9a-f]+ (\d+)$"#, line) { ivar = Ivar(name: "?", type: "", offset: Int(m[1])!) }
                if let m = firstMatch(#"^ {12}name\s+0x([0-9a-f]+) (\S+)$"#, line) { ivar.name = m[1] == "0" ? "?" : m[2] }
                if let m = firstMatch(#"^ {12}type\s+0x([0-9a-f]+) ?(.*)$"#, line) {
                    ivar.type = m[1] == "0" ? "" : m[2]
                    current!.otoolIvars.append(ivar)
                }
            }
        } else if section.contains("__objc_catlist") {
            if firstMatch(#"^[0-9a-f]{16} 0x"#, line) != nil { flush(); category = CategoryRecord(className: "", name: ""); continue }
            guard category != nil else { continue }
            if let m = firstMatch(#"^ {4}(name|cls)\s+0x[0-9a-f]+ (\S+)$"#, line) {
                if m[1] == "name" { category!.name = m[2] } else { category!.className = m[2].replacingOccurrences(of: "_OBJC_CLASS_$_", with: "") }
                continue
            }
            if let m = firstMatch(#"^ {4}([a-zA-Z]+)\s"#, line) { categoryBlock = m[1]; continue }
            if categoryBlock == "instanceMethods" || categoryBlock == "classMethods" {
                if let m = firstMatch(#"^ {8}name\s+0x[0-9a-f]+ ([^(\s]\S*)$"#, line) { pendingName = m[1] }
                if let m = firstMatch(#"^ {8}types\s+0x[0-9a-f]+(?: \(0x[0-9a-f]+\))? (.+)$"#, line) { pendingTypes = m[1] }
                if let m = firstMatch(#"^ {8}imp\s+0x([0-9a-f]+)(?: \(0x([0-9a-f]+)\))?"#, line) {
                    let imp = UInt64(m[2].isEmpty ? m[1] : m[2], radix: 16)!
                    category!.methods.append(method(kind: categoryBlock == "classMethods" ? "+" : "-", imp: imp))
                    pendingName = ""
                }
            }
        }
    }
    flush()
    return (classes, categories)
}

/// Word indexes (relative to instanceStart) covered by an ivar layout.
func layoutWords(_ bytes: [UInt8]) -> Set<Int> {
    var words: Set<Int> = []
    var position = 0
    for byte in bytes {
        position += Int(byte >> 4)
        for _ in 0..<Int(byte & 0x0f) { words.insert(position); position += 1 }
    }
    return words
}

struct READata {
    var classes: [String: [String: Any]] = [:]
    var ivars: [String: [Ivar]] = [:]
    var protocols: [[String: Any]] = []
}

func loadREA(_ path: String) -> READata {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) else { fail("cannot read REA JSON \(path)") }
    var found: [String: Any]?
    func walk(_ object: Any) {
        if found != nil { return }
        if let dict = object as? [String: Any] {
            if dict["objc_classes"] != nil { found = dict; return }
            dict.values.forEach(walk)
        } else if let array = object as? [Any] {
            array.forEach(walk)
        }
    }
    walk(root)
    guard let result = found else { fail("no objc_classes in \(path)") }
    var rea = READata()
    for case let c as [String: Any] in result["objc_classes"] as? [Any] ?? [] where (c["is_meta_class"] as? Bool) != true {
        if let name = c["name"] as? String { rea.classes[name] = c }
    }
    for case let i as [String: Any] in result["objc_ivars"] as? [Any] ?? [] {
        guard let owner = i["class_name"] as? String, let name = i["name"] as? String else { continue }
        rea.ivars[owner, default: []].append(Ivar(name: name, type: i["type_encoding"] as? String ?? "", offset: i["offset"] as? Int ?? 0))
    }
    rea.protocols = (result["objc_protocol_records"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    return rea
}

func ownership(of ivar: Ivar, in record: ClassRecord?) -> String {
    guard ivar.type.hasPrefix("@") else { return "" }
    guard let record, ivar.offset >= record.instanceStart, ivar.offset % 8 == 0 else { return " ownership=?" }
    let word = (ivar.offset - record.instanceStart) / 8
    if layoutWords(record.strongLayout).contains(word) { return " strong" }
    if layoutWords(record.weakLayout).contains(word) { return " weak" }
    return " unretained"
}

func map(binary: String, reaPath: String, output: String) {
    let archs = run("lipo", ["-archs", binary]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !archs.isEmpty, !archs.contains(" ") else { fail("\(binary) is not a thin Mach-O (architectures: \(archs))") }
    let dyld = parseDyldInfo(run("dyld_info", ["-objc", binary]))
    guard !dyld.selectors.isEmpty else { fail("dyld_info listed no Objective-C methods for \(binary)") }
    let otool = parseOtool(run("otool", ["-oV", binary]), selectors: dyld.selectors)
    guard !otool.classes.isEmpty else { fail("otool listed no Objective-C classes for \(binary)") }
    let rea = loadREA(reaPath)

    var out = "# Objective-C class map of \(binary) (\(archs))\n"
    out += "# Generated by tools/re/objc-classmap.swift from REA (\(reaPath)), dyld_info -objc and otool -oV.\n"
    out += "# Ivar ownership (strong/weak/unretained) comes from the class's ivar layouts; method types from otool.\n\n"

    let names = Set(otool.classes.keys).union(rea.classes.keys).filter { !$0.isEmpty }
    for name in names.sorted() {
        let record = otool.classes[name]
        let reaClass = rea.classes[name]
        let header = dyld.headers[name]
        let superclass = (reaClass?["super_class"] as? String) ?? header?.0 ?? "?"
        let protocols: [String] = (reaClass?["protocols"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) } ?? header?.1 ?? []
        out += "## \(name) : \(superclass) <\(protocols.joined(separator: ", "))>\n"
        out += reaClass != nil ? "  source: REA (class, ivars, properties), dyld_info (selectors), otool (types, layouts)\n"
                               : "  source: no REA record; dyld_info (selectors), otool (class, ivars, types, layouts)\n"
        let ivars = reaClass != nil ? (rea.ivars[name] ?? []) : (record?.otoolIvars ?? [])
        for ivar in ivars.sorted(by: { $0.offset < $1.offset }) {
            out += "  ivar \(ivar.name) \(ivar.type.isEmpty ? "?" : ivar.type)\(ownership(of: ivar, in: record))\n"
        }
        for case let p as [String: Any] in reaClass?["properties"] as? [Any] ?? [] {
            let attributes = (p["attributes"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? "")\($0["value"] as? String ?? "")" }
            out += "  property \(p["name"] as? String ?? "?") \(attributes.joined(separator: ","))\n"
        }
        for m in record?.methods ?? [] { out += "  \(m.kind)\(m.selector) \(m.types)\n" }
        out += "\n"
    }
    for c in otool.categories.sorted(by: { ($0.className, $0.name) < ($1.className, $1.name) }) {
        out += "## \(c.className)(\(c.name))\n  source: dyld_info (selectors), otool (category, types)\n"
        for m in c.methods { out += "  \(m.kind)\(m.selector) \(m.types)\n" }
        out += "\n"
    }
    for p in rea.protocols.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
        out += "## @protocol \(p["name"] as? String ?? "?") <\((p["adopted_protocols"] as? [String] ?? []).joined(separator: ", "))>\n  source: REA\n"
        var seen: Set<String> = []
        for key in ["methods", "optional_methods"] {
            for case let m as [String: Any] in p[key] as? [Any] ?? [] {
                let required = key == "methods" && (m["is_optional"] as? Bool) != true
                let kind = (m["method_type"] as? String) == "instance" ? "-" : "+"
                let line = "  \(required ? "required" : "optional") \(kind)\(m["selector"] as? String ?? "?")"
                if seen.insert(line).inserted { out += line + "\n" }
            }
        }
        out += "\n"
    }
    do { try out.write(toFile: output, atomically: true, encoding: .utf8) } catch { fail("cannot write \(output): \(error)") }
    print("\(names.count) classes, \(otool.categories.count) categories, \(rea.protocols.count) protocols -> \(output)")
}

// MARK: - compare

struct MapClass {
    var superclass = ""
    var protocols: Set<String> = []
    var methods: [String: String] = [:]   // "-sel" -> normalized types
    var ivars: Set<String> = []
}

func normalize(_ types: String) -> String {
    var s = types.replacingOccurrences(of: #"@"[^"]*""#, with: "@", options: .regularExpression)
    s = s.replacingOccurrences(of: #"@\?<[^>]*>"#, with: "@?", options: .regularExpression)
    s = s.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
    return s.replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
}

func loadMap(_ path: String) -> [String: MapClass] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    var classes: [String: MapClass] = [:]
    var current: String?
    for line in text.split(separator: "\n").map(String.init) {
        if line.hasPrefix("## ") {
            current = nil
            if let m = firstMatch(#"^## (\S+) : (\S+) <(.*)>$"#, line) {
                current = m[1]
                classes[m[1]] = MapClass(superclass: m[2], protocols: Set(m[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            }
            continue
        }
        guard let name = current else { continue }
        if let m = firstMatch(#"^  ivar (\S+) "#, line) { classes[name]!.ivars.insert(m[1]) }
        if let m = firstMatch(#"^  ([-+])(\S+) (.*)$"#, line) { classes[name]!.methods[m[1] + m[2]] = normalize(m[3]) }
    }
    return classes
}

func compare(originalPath: String, otherPath: String) {
    let original = loadMap(originalPath), other = loadMap(otherPath)
    let ignored: Set<String> = ["-.cxx_destruct", "-.cxx_construct"]
    var report: [String] = []
    for name in other.keys.sorted() {
        let mine = other[name]!
        guard let theirs = original[name] else { report.append("\(name): class not in original"); continue }
        if mine.superclass != theirs.superclass { report.append("\(name): superclass \(mine.superclass), original \(theirs.superclass)") }
        for p in mine.protocols.subtracting(theirs.protocols).sorted() { report.append("\(name): protocol \(p) not adopted by original") }
        for (selector, types) in mine.methods.sorted(by: { $0.key < $1.key }) where !ignored.contains(selector) {
            guard let originalTypes = theirs.methods[selector] else { report.append("\(name): method \(selector) not in original"); continue }
            if types != originalTypes { report.append("\(name): method \(selector) types \(types), original \(originalTypes)") }
        }
        for ivar in mine.ivars.sorted() where !theirs.ivars.contains(ivar) && !theirs.ivars.contains("_" + ivar) {
            report.append("\(name): ivar \(ivar) has no original counterpart")
        }
    }
    report.forEach { print($0) }
    print("\(report.count) difference(s)")
    exit(report.isEmpty ? 0 : 1)
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (5, "map"): map(binary: arguments[2], reaPath: arguments[3], output: arguments[4])
case (4, "compare"): compare(originalPath: arguments[2], otherPath: arguments[3])
default: fail(usage, status: 2)
}
