// Swift type map of a Mach-O image.
//
// Purpose: list every Swift class, struct and enum that a Mach-O image
// registers in __swift5_types, with module, kind, Objective-C class name,
// superclass, fields and field types, enum cases and payload types, and the
// implementations in each class's vtable and override table. The macOS 15
// Dock (where the original Launchpad lives) is stripped of local symbols, but
// its Swift reflection metadata is intact, and this is what the tool reads.
//
// Usage:
//   swift tools/re/swift-types.swift <thin Mach-O> <output.txt>
//
// Keep the input and the output under research/ (clean room).
//
// Where each item comes from:
//   - The file itself: load commands (segments, sections); __swift5_types
//     (relative pointers to type context descriptors); the descriptors and
//     their parent chains (module, extension, anonymous and type contexts);
//     the field descriptors (__swift5_fieldmd) and mangled names they point
//     to; class vtables and override tables.
//   - dyld_info -fixups: the targets of pointer slots, which the file stores
//     as chained fixups (a rebase to an address in this image, or a symbol
//     bound from another image). Used for indirect references, for
//     Objective-C protocol records and for __objc_classlist.
//   - __objc_classlist: each Swift class object's metadata points at its
//     class descriptor (offset 0x40) and its class_ro_t holds the
//     Objective-C name; that pairs Objective-C names with Swift types.
//   - swift-demangle (Xcode toolchain): mangled type names to Swift spelling.
//
// Symbolic references inside mangled names:
//   0x01  direct relative reference to a context descriptor in this image
//   0x02  relative reference to a pointer slot, whose fixup is a rebase to a
//         descriptor in this image or a bound descriptor symbol of another
//         image ($s<mangling>Mn for types, Mp for protocols)
//   0x0C  direct relative reference to a relative pointer to the
//         __objc_protorefs slot of an Objective-C protocol
// The demangler counts each of these as one substitution, so every one is
// replaced by a placeholder that also adds exactly one substitution
// (qd900_<n>_Sg, an optional generic parameter that no real type uses; a
// protocol reference is replaced together with the "_p" that follows it,
// which adds none). Where the mangling needs a real nominal type or protocol
// (a type bound to generic arguments, the protocol of an associated type),
// the placeholder is a nominal mangling, which adds more substitutions; it is
// demangled in two forms that add different numbers, and accepted only if
// both give the same text. After demangling, each placeholder is replaced by
// the name of what it stands for. Other reference kinds (accessor functions,
// extended existential shapes, absolute pointers), names the demangler
// rejects and nominal placeholders whose two forms disagree are printed as
// "? (reason) ..." and counted as failures.
//
// Names: Module.Outer.Inner. A type nested in an extension is
// "(extension in M):Extended.Inner". A type whose parent is an anonymous
// context (a private or local declaration) is "Parent.(Name in <anonymous>)".

import CryptoKit
import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let usage = "usage: swift tools/re/swift-types.swift <thin Mach-O> <output.txt>"

func run(_ tool: String, _ arguments: [String], input: String? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [tool] + arguments
    var inputURL: URL?
    if let input {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swift-types-\(UUID().uuidString).txt")
        do { try input.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(url.path): \(error)") }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { fail("cannot read \(url.path)") }
        process.standardInput = handle
        inputURL = url
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot run \(tool): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
    guard process.terminationStatus == 0 else { fail("\(tool) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16, uppercase: true) }

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fail(usage, status: 2) }
let inputPath = arguments[0]
let outputPath = arguments[1]
guard let file = FileManager.default.contents(atPath: inputPath) else { fail("cannot read \(inputPath)") }
let bytes = [UInt8](file)

// MARK: - Mach-O

struct Segment { var vmaddr: UInt64; var fileoff: UInt64; var filesize: UInt64 }
struct Section { var address: UInt64; var size: UInt64 }

func le(_ offset: Int, _ count: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<count { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
    return value
}

func fixedName(_ offset: Int) -> String {
    String(decoding: bytes[offset..<offset + 16].prefix { $0 != 0 }, as: UTF8.self)
}

guard bytes.count > 32, le(0, 4) == 0xFEED_FACF else { fail("\(inputPath) is not a thin 64-bit Mach-O") }
var segments: [Segment] = []
var sections: [String: Section] = [:]  // "segment,section"
var commandOffset = 32
for _ in 0..<Int(le(16, 4)) {
    let command = le(commandOffset, 4)
    if command == 0x19 {  // LC_SEGMENT_64
        segments.append(Segment(vmaddr: le(commandOffset + 24, 8), fileoff: le(commandOffset + 40, 8), filesize: le(commandOffset + 48, 8)))
        for index in 0..<Int(le(commandOffset + 64, 4)) {
            let header = commandOffset + 72 + index * 80
            sections["\(fixedName(header + 16)),\(fixedName(header))"] = Section(address: le(header + 32, 8), size: le(header + 40, 8))
        }
    }
    commandOffset += Int(le(commandOffset + 4, 4))
}

func fileOffset(_ address: UInt64) -> Int {
    for segment in segments where address >= segment.vmaddr && address < segment.vmaddr + segment.filesize {
        return Int(segment.fileoff + address - segment.vmaddr)
    }
    fail("address \(hex(address)) is not backed by the file")
}

func u8(_ address: UInt64) -> UInt8 { bytes[fileOffset(address)] }
func u16(_ address: UInt64) -> UInt16 { UInt16(le(fileOffset(address), 2)) }
func u32(_ address: UInt64) -> UInt32 { UInt32(le(fileOffset(address), 4)) }
func i32(_ address: UInt64) -> Int32 { Int32(bitPattern: u32(address)) }
func offset(_ address: UInt64, by value: Int32) -> UInt64 { UInt64(bitPattern: Int64(bitPattern: address) + Int64(value)) }

func cString(_ address: UInt64) -> String {
    let start = fileOffset(address)
    var end = start
    while bytes[end] != 0 { end += 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

/// Target of a relative direct pointer, nil when the pointer is null.
func relative(_ address: UInt64) -> UInt64? {
    let value = i32(address)
    return value == 0 ? nil : offset(address, by: value)
}

// MARK: - Fixups

enum Target { case local(UInt64), symbol(String) }

var fixups: [UInt64: Target] = [:]
for line in run("dyld_info", ["-fixups", inputPath]).split(separator: "\n") {
    let fields = line.split(separator: " ")
    guard fields.count >= 5, fields[2].hasPrefix("0x"), let address = UInt64(fields[2].dropFirst(2), radix: 16) else { continue }
    if fields[3].hasSuffix("rebase"), fields[4].hasPrefix("0x"), let target = UInt64(fields[4].dropFirst(2), radix: 16) {
        fixups[address] = .local(target)
    } else if fields[3].hasSuffix("bind") {
        // "library/symbol"
        let target = fields[4]
        fixups[address] = .symbol(String(target[(target.firstIndex(of: "/").map { target.index(after: $0) } ?? target.startIndex)...]))
    }
}
guard !fixups.isEmpty else { fail("dyld_info -fixups listed nothing for \(inputPath)") }

enum Reference { case local(UInt64), symbol(String), unresolved(String) }

func slotTarget(_ slot: UInt64) -> Reference {
    switch fixups[slot] {
    case .local(let target)?: return .local(target)
    case .symbol(let name)?: return .symbol(name)
    case nil: return .unresolved("no fixup at pointer slot \(hex(slot))")
    }
}

/// Target of a relative indirectable pointer (low bit set: points at a pointer slot).
func indirectable(_ address: UInt64) -> Reference? {
    let value = i32(address)
    if value == 0 { return nil }
    if value & 1 == 0 { return .local(offset(address, by: value)) }
    return slotTarget(offset(address, by: value & ~1))
}

// MARK: - Context descriptors

let moduleKind: UInt32 = 0, extensionKind: UInt32 = 1, anonymousKind: UInt32 = 2, protocolKind: UInt32 = 3
let classKind: UInt32 = 16, structKind: UInt32 = 17, enumKind: UInt32 = 18

struct Context {
    var flags: UInt32
    var kind: UInt32
    var parent: Reference?
    var name: String
}

var contextCache: [UInt64: Context] = [:]

func context(_ address: UInt64) -> Context {
    if let cached = contextCache[address] { return cached }
    let flags = u32(address)
    let kind = flags & 0x1F
    var name = ""
    if [moduleKind, protocolKind, classKind, structKind, enumKind].contains(kind), let nameAddress = relative(address + 8) {
        name = cString(nameAddress)
    }
    let result = Context(flags: flags, kind: kind, parent: indirectable(address + 4), name: name)
    contextCache[address] = result
    return result
}

// MARK: - Mangled names

enum Placeholder: Hashable {
    case descriptor(UInt64)
    case external(mangling: String, isProtocol: Bool)
    case objcProtocol(String)
}

/// A mangled name with its symbolic references replaced by placeholders. `alternate` differs from
/// `mangled` only in nominal placeholders (see `nominalPlaceholder`).
struct Prepared {
    var mangled = ""
    var alternate = ""
    var problems: [String] = []
    var raw = ""
}

var placeholders: [Placeholder] = []
var placeholderIndex: [Placeholder: Int] = [:]

func number(_ value: Placeholder) -> Int {
    if placeholderIndex[value] == nil {
        placeholderIndex[value] = placeholders.count
        placeholders.append(value)
    }
    return placeholderIndex[value]!
}

/// Placeholder for a type used as a value: one substitution, like the symbolic reference it replaces.
func placeholder(_ value: Placeholder) -> String { "qd900_\(number(value))_Sg" }

/// Placeholders for a reference that must stay a nominal type or a protocol in the mangling: a type
/// bound to generic arguments ("y...G", bound level by level, so its enclosing types are spelled out
/// too) or a protocol that is not an existential (the protocol of an associated type, "...Qz").
/// A nominal mangling adds more than one substitution. The two forms, rooted at "Swift" and at
/// "__SYM__", add different numbers of entries; if both demangle to the same text once the
/// placeholders are replaced, no later substitution index was thrown off by the extra entries.
func nominalPlaceholder(_ value: Placeholder, suffix: Character) -> (String, String) {
    var levels: [(Placeholder, Character)] = [(value, suffix)]
    if case .descriptor(var address) = value {
        while case .local(let parent)? = context(address).parent, [classKind, structKind, enumKind].contains(context(parent).kind) {
            let kind = context(parent).kind
            levels.insert((.descriptor(parent), kind == classKind ? "C" : kind == enumKind ? "O" : "V"), at: 0)
            address = parent
        }
    }
    let body = levels.map { level in
        let name = "_\(number(level.0))_"
        return "\(name.count)\(name)\(level.1)"
    }.joined()
    return ("s" + body, "7__SYM__" + body)
}

func rawBytes(_ start: UInt64) -> String {
    var address = start
    var parts: [String] = []
    while true {
        let byte = u8(address)
        let width = byte == 0 ? 1 : (1...0x17).contains(byte) ? 5 : (0x18...0x1F).contains(byte) ? 9 : 1
        for index in 0..<UInt64(width) { parts.append(String(format: "%02x", u8(address + index))) }
        if byte == 0 { break }
        address += UInt64(width)
    }
    return parts.joined(separator: " ")
}

func prepare(_ start: UInt64) -> Prepared {
    var result = Prepared()
    var address = start
    while true {
        let byte = u8(address)
        if byte == 0 { break }
        switch byte {
        case 0x01, 0x02, 0x0C:
            let target = offset(address + 1, by: i32(address + 1))
            address += 5
            var value: Placeholder?
            var isProtocol = false
            var suffix: Character = "V"
            if byte == 0x0C {
                // target: a relative pointer to a __objc_protorefs slot, which points at the protocol_t
                isProtocol = true
                if let slot = relative(target), case .local(let protocolRecord)? = fixups[slot],
                   case .local(let nameAddress)? = fixups[protocolRecord + 8] {
                    value = .objcProtocol(cString(nameAddress))
                } else {
                    result.problems.append("Objective-C protocol reference \(hex(target)) does not lead to a protocol name")
                }
            } else {
                switch byte == 0x01 ? .local(target) : slotTarget(target) {
                case .local(let descriptor):
                    let kind = context(descriptor).kind
                    if [classKind, structKind, enumKind, protocolKind].contains(kind) {
                        value = .descriptor(descriptor)
                        isProtocol = kind == protocolKind
                        suffix = kind == classKind ? "C" : kind == enumKind ? "O" : "V"
                    } else {
                        result.problems.append("reference to a context of kind \(kind) at \(hex(descriptor))")
                    }
                case .symbol(let name):
                    if name.hasPrefix("_$s"), name.hasSuffix("Mn") || name.hasSuffix("Mp") {
                        let mangling = String(name.dropFirst(3).dropLast(2))
                        isProtocol = name.hasSuffix("Mp")
                        value = .external(mangling: mangling, isProtocol: isProtocol)
                        suffix = mangling.last ?? "V"
                    } else {
                        result.problems.append("bound symbol \(name) is not a type or protocol descriptor")
                    }
                case .unresolved(let reason):
                    result.problems.append(reason)
                }
            }
            var nominal = false
            if isProtocol {
                if u8(address) == UInt8(ascii: "_"), u8(address + 1) == UInt8(ascii: "p") {
                    address += 2
                } else {
                    nominal = true
                    suffix = "P"
                }
            } else {
                nominal = u8(address) == UInt8(ascii: "y")
            }
            if let value, nominal {
                let (first, second) = nominalPlaceholder(value, suffix: suffix)
                result.mangled += first
                result.alternate += second
            } else {
                let text = value.map(placeholder) ?? "?"
                result.mangled += text
                result.alternate += text
            }
        case 0x03...0x17:
            result.problems.append("symbolic reference kind 0x\(String(byte, radix: 16))")
            address += 5
        case 0x18...0x1F:
            result.problems.append("absolute symbolic reference kind 0x\(String(byte, radix: 16))")
            address += 9
        default:
            result.mangled.append(Character(UnicodeScalar(byte)))
            result.alternate.append(Character(UnicodeScalar(byte)))
            address += 1
        }
    }
    if !result.problems.isEmpty { result.raw = rawBytes(start) }
    return result
}

// MARK: - Collect

struct Field { var line: String; var type: Prepared? }
struct Impl { var address: UInt64; var line: String }

struct TypeRecord {
    var address: UInt64
    var kind: UInt32
    var generic = false
    var superclass: Prepared?
    var fields: [Field] = []
    var impls: [Impl] = []
    var notes: [String] = []
}

guard let typeSection = sections["__TEXT,__swift5_types"] else { fail("\(inputPath) has no __swift5_types section") }

/// An Objective-C class implemented in Swift (`@objc @implementation`): declared in an Objective-C
/// header, so it has no Swift type descriptor and its class data pointer has no Swift bit, but its
/// ivars are Swift stored properties, whose type encodings are empty or "?" (clang never emits either
/// for an Objective-C ivar).
struct ImplementedClass { var name: String; var superclass: String; var ivars: [String]; var properties: [String] }

func pointedString(_ slot: UInt64) -> String? {
    guard case .local(let address)? = fixups[slot] else { return nil }
    return cString(address)
}

func objcClassName(_ target: Target?) -> String {
    switch target {
    case .local(let classObject)?:
        guard case .local(let data)? = fixups[classObject + 0x20] else { return "?" }
        return pointedString((data & ~7) + 0x18) ?? "?"
    case .symbol(let symbol)?:
        return symbol.hasPrefix("_OBJC_CLASS_$_") ? String(symbol.dropFirst(14)) : symbol
    case nil:
        return "(root)"
    }
}

/// Entries of an ivar_list_t or property_list_t (entsize, count, entries) that a class_ro_t field points to.
func objcList(_ slot: UInt64) -> [UInt64] {
    guard case .local(let list)? = fixups[slot] else { return [] }
    let size = UInt64(u32(list)), count = UInt64(u32(list + 4))
    return (0..<count).map { list + 8 + $0 * size }
}

// Objective-C names of Swift classes, by class descriptor; Objective-C classes implemented in Swift.
var objcNames: [UInt64: String] = [:]
var implementedClasses: [ImplementedClass] = []
if let classList = sections["__DATA_CONST,__objc_classlist"] ?? sections["__DATA,__objc_classlist"] {
    for slot in stride(from: classList.address, to: classList.address + classList.size, by: 8) {
        guard case .local(let classObject)? = fixups[slot], case .local(let data)? = fixups[classObject + 0x20] else { continue }
        let readOnly = data & ~7
        guard let name = pointedString(readOnly + 0x18) else { continue }
        if data & 3 != 0 {  // FAST_IS_SWIFT_LEGACY / FAST_IS_SWIFT_STABLE
            if case .local(let descriptor)? = fixups[classObject + 0x40] { objcNames[descriptor] = name }
            continue
        }
        // class_ro_t: ivars at 0x30, properties at 0x40; ivar_t: name at 8, type at 16, size at 28.
        let ivars = objcList(readOnly + 0x30).map { (name: pointedString($0 + 8) ?? "?", type: pointedString($0 + 16) ?? "", size: u32($0 + 28)) }
        guard ivars.contains(where: { $0.type.isEmpty || $0.type == "?" }) else { continue }
        implementedClasses.append(ImplementedClass(
            name: name,
            superclass: objcClassName(fixups[classObject + 8]),
            ivars: ivars.map { "ivar \($0.name) size \($0.size) type \"\($0.type)\"" },
            properties: objcList(readOnly + 0x40).map { "property \(pointedString($0) ?? "?") \(pointedString($0 + 8) ?? "?")" }))
    }
}

let methodKinds = ["method", "init", "getter", "setter", "modify", "read"]

func methodLine(_ flags: UInt32) -> String {
    let kind = Int(flags & 0xF)
    var words = [kind < methodKinds.count ? methodKinds[kind] : "kind\(kind)", flags & 0x10 != 0 ? "instance" : "static"]
    if flags & 0x20 != 0 { words.append("dynamic") }
    if flags & 0x40 != 0 { words.append("async") }
    return words.joined(separator: " ")
}

var types: [TypeRecord] = []
var skippedRecords = 0
for recordAddress in stride(from: typeSection.address, to: typeSection.address + typeSection.size, by: 4) {
    let value = i32(recordAddress)
    let descriptor: UInt64
    switch value & 3 {
    case 0: descriptor = offset(recordAddress, by: value & ~3)
    case 1:
        guard case .local(let target)? = fixups[offset(recordAddress, by: value & ~3)] else { skippedRecords += 1; continue }
        descriptor = target
    default: skippedRecords += 1; continue
    }
    let header = context(descriptor)
    guard [classKind, structKind, enumKind].contains(header.kind) else { skippedRecords += 1; continue }
    var record = TypeRecord(address: descriptor, kind: header.kind, generic: header.flags & 0x80 != 0)

    if header.kind == classKind, let superclass = relative(descriptor + 20) {
        record.superclass = prepare(superclass)
    }
    if let fieldDescriptor = relative(descriptor + 16) {
        let recordSize = UInt64(u16(fieldDescriptor + 10))
        for index in 0..<UInt64(u32(fieldDescriptor + 12)) {
            let fieldRecord = fieldDescriptor + 16 + index * recordSize
            let flags = u32(fieldRecord)
            let name = relative(fieldRecord + 8).map(cString) ?? "?"
            let type = relative(fieldRecord + 4).map(prepare)
            let line: String
            if header.kind == enumKind {
                line = (flags & 1 != 0 ? "indirect case " : "case ") + name
            } else {
                line = "field " + (flags & 2 != 0 ? "var " : "let ") + name
            }
            record.fields.append(Field(line: line, type: type))
        }
    }

    if header.kind == classKind {
        // Trailing objects after the 44-byte class descriptor.
        let kindFlags = header.flags >> 16
        var cursor = descriptor + 44
        var parsable = true
        if record.generic {
            let parameters = UInt64(u16(cursor + 8))
            let requirements = UInt64(u16(cursor + 10))
            let genericFlags = u16(cursor + 14)
            cursor += 16 + (parameters + 3) / 4 * 4 + requirements * 12
            if genericFlags != 0 {
                parsable = false
                record.notes.append("vtable not read: generic context flags \(String(genericFlags, radix: 16))")
            }
        }
        if parsable {
            if kindFlags & (1 << 13) != 0 { cursor += 4 }  // resilient superclass
            switch kindFlags & 3 {  // metadata initialization
            case 1: cursor += 12
            case 2: cursor += 4
            default: break
            }
            if kindFlags & (1 << 15) != 0 {  // vtable
                let count = UInt64(u32(cursor + 4))
                cursor += 8
                for index in 0..<count {
                    let method = cursor + index * 8
                    if let impl = relative(method + 4) {
                        record.impls.append(Impl(address: impl, line: "vtable \(methodLine(u32(method)))"))
                    }
                }
                cursor += count * 8
            }
            if kindFlags & (1 << 14) != 0 {  // override table
                let count = UInt64(u32(cursor))
                cursor += 4
                for index in 0..<count {
                    let entry = cursor + index * 12
                    var line = "override"
                    if case .local(let method)? = indirectable(entry + 4) { line += " " + methodLine(u32(method)) }
                    if let impl = relative(entry + 8) {
                        record.impls.append(Impl(address: impl, line: line))
                    }
                }
            }
        }
    }
    types.append(record)
}

// Extension contexts on the parent chains (their extended types are demangled too).
var extendedContexts: [UInt64: Prepared] = [:]
for record in types {
    var parent = context(record.address).parent
    while case .local(let address)? = parent {
        let current = context(address)
        if current.kind == extensionKind, extendedContexts[address] == nil, let mangled = relative(address + 8) {
            extendedContexts[address] = prepare(mangled)
        }
        parent = current.parent
    }
}

// MARK: - Demangle

var requests: [String] = []
var requestIndex: [String: Int] = [:]
func request(_ text: String) {
    if requestIndex[text] == nil {
        requestIndex[text] = requests.count
        requests.append(text)
    }
}

func requestType(_ prepared: Prepared?) {
    guard let prepared, prepared.problems.isEmpty else { return }
    request("$s\(prepared.mangled)D")
    request("$s\(prepared.alternate)D")
}

for record in types {
    requestType(record.superclass)
    for field in record.fields { requestType(field.type) }
}
for prepared in extendedContexts.values { requestType(prepared) }
for (index, value) in placeholders.enumerated() {
    request("$sqd900_\(index)_SgD")
    if case .external(let mangling, let isProtocol) = value { request("$s\(mangling)\(isProtocol ? "_p" : "")D") }
}

let demangledLines = run("swift-demangle", ["--compact"], input: requests.joined(separator: "\n") + "\n")
    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
guard demangledLines.count >= requests.count else { fail("swift-demangle returned \(demangledLines.count) lines for \(requests.count) names") }

func demangled(_ text: String) -> String? {
    let output = demangledLines[requestIndex[text]!]
    return output.hasPrefix("$s") ? nil : output
}

// Printed form of each placeholder ("B902?") -> placeholder number.
var placeholderByPrinted: [String: Int] = [:]
for index in placeholders.indices {
    guard let printed = demangled("$sqd900_\(index)_SgD") else { fail("swift-demangle rejected placeholder \(index)") }
    placeholderByPrinted[printed] = index
}
let valuePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])[A-Z]+902\?"#)
let outerPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?:Swift|__SYM__)\._([0-9]+)_(?![A-Za-z0-9_])"#)
let innerPattern = try! NSRegularExpression(pattern: #"\._([0-9]+)_(?![A-Za-z0-9_])"#)

// MARK: - Names

var nameCache: [UInt64: String] = [:]
var failures = 0

func moduleName(_ reference: Reference?) -> String {
    var current = reference
    while case .local(let address)? = current {
        let value = context(address)
        if value.kind == moduleKind { return value.name }
        current = value.parent
    }
    return "?"
}

func contextName(_ reference: Reference?) -> String {
    switch reference {
    case .local(let address)?: return fullName(address)
    case .symbol(let name)?: return "?(\(name))"
    case .unresolved(let reason)?: return "?(\(reason))"
    case nil: return "?"
    }
}

func fullName(_ address: UInt64) -> String {
    if let cached = nameCache[address] { return cached }
    let value = context(address)
    let result: String
    switch value.kind {
    case moduleKind:
        result = value.name
    case extensionKind:
        result = "(extension in \(moduleName(value.parent))):" + (extendedContexts[address].map { render($0, counting: false) } ?? "?")
    case anonymousKind:
        result = contextName(value.parent)
    default:
        if case .local(let parent)? = value.parent, context(parent).kind == anonymousKind {
            result = "\(contextName(context(parent).parent)).(\(value.name) in <anonymous>)"
        } else {
            result = "\(contextName(value.parent)).\(value.name)"
        }
    }
    nameCache[address] = result
    return result
}

func placeholderName(_ index: Int) -> String {
    switch placeholders[index] {
    case .descriptor(let address): return fullName(address)
    case .external(let mangling, let isProtocol): return demangled("$s\(mangling)\(isProtocol ? "_p" : "")D") ?? "?(\(mangling))"
    case .objcProtocol(let name): return "__C.\(name)"
    }
}

func simpleName(_ index: Int) -> String {
    guard case .descriptor(let address) = placeholders[index] else { return placeholderName(index) }
    let value = context(address)
    if case .local(let parent)? = value.parent, context(parent).kind == anonymousKind { return "(\(value.name) in <anonymous>)" }
    return value.name
}

/// Replaces the printed placeholders in demangler output by the names they stand for: value
/// placeholders ("B902?") and the outermost level of nominal ones ("Swift._12_") by full names,
/// the inner levels of nominal ones ("._291_") by simple names.
func substitutePlaceholders(_ text: String) -> String {
    var output = text
    for (pattern, inner) in [(valuePattern, false), (outerPattern, false), (innerPattern, true)] {
        let current = output
        for match in pattern.matches(in: current, range: NSRange(current.startIndex..., in: current)).reversed() {
            let index = pattern === valuePattern
                ? placeholderByPrinted[String(current[Range(match.range, in: current)!])]
                : Int(current[Range(match.range(at: 1), in: current)!])
            guard let index, index < placeholders.count else { continue }
            output.replaceSubrange(Range(match.range, in: output)!, with: inner ? "." + simpleName(index) : placeholderName(index))
        }
    }
    return output
}

func render(_ prepared: Prepared, counting: Bool = true) -> String {
    guard prepared.problems.isEmpty else {
        if counting { failures += 1 }
        return "? (\(prepared.problems.joined(separator: "; "))) bytes \(prepared.raw)"
    }
    guard let text = demangled("$s\(prepared.mangled)D") else {
        if counting { failures += 1 }
        return "? (swift-demangle rejected \(prepared.mangled))"
    }
    let output = substitutePlaceholders(text)
    if prepared.alternate != prepared.mangled {
        guard let other = demangled("$s\(prepared.alternate)D"), substitutePlaceholders(other) == output else {
            if counting { failures += 1 }
            return "? (placeholder forms disagree: \(prepared.mangled))"
        }
    }
    return output
}

// MARK: - Output

let kindNames: [UInt32: String] = [classKind: "class", structKind: "struct", enumKind: "enum"]
var blocks: [(name: String, text: String)] = []
var counts: [String: [String: Int]] = [:]  // module -> kind -> count
for record in types {
    let name = fullName(record.address)
    let module = moduleName(.local(record.address))
    let kind = kindNames[record.kind]!
    counts[module, default: [:]][kind, default: 0] += 1
    var lines = ["## \(name)", "  kind: \(kind)", "  module: \(module)", "  descriptor: \(hex(record.address))"]
    if record.generic { lines.append("  generic: yes") }
    if let objc = objcNames[record.address] { lines.append("  objc: \(objc)") }
    if let superclass = record.superclass { lines.append("  superclass: \(render(superclass))") }
    for field in record.fields {
        lines.append("  \(field.line)" + (field.type.map { ": " + render($0) } ?? ""))
    }
    for impl in record.impls { lines.append("  impl \(hex(impl.address)) \(impl.line)") }
    for note in record.notes { lines.append("  note: \(note)") }
    blocks.append((name, lines.joined(separator: "\n")))
}
blocks.sort { $0.name < $1.name }

// Modules that extend each Objective-C class implemented in Swift ("(extension in M):__C.Name").
var extendingModules: [String: Set<String>] = [:]
for (address, prepared) in extendedContexts {
    let extended = render(prepared, counting: false)
    if extended.hasPrefix("__C.") { extendingModules[String(extended.dropFirst(4)), default: []].insert(moduleName(context(address).parent)) }
}
var implementedBlocks: [String] = []
for implemented in implementedClasses.sorted(by: { $0.name < $1.name }) {
    let modules = extendingModules[implemented.name].map { $0.sorted().joined(separator: ", ") } ?? "none found"
    implementedBlocks.append((["## @implementation \(implemented.name)", "  superclass: \(implemented.superclass)", "  extended in: \(modules)"]
        + implemented.ivars.map { "  " + $0 } + implemented.properties.map { "  " + $0 }).joined(separator: "\n"))
}

let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
var header = [
    "# Swift types of \((inputPath as NSString).lastPathComponent)",
    "# input sha256: \(digest)",
    "# sources: __swift5_types, type and field descriptors, vtables (file); pointer slots (dyld_info -fixups); Objective-C names, ivars and properties (__objc_classlist, class_ro_t); type names (swift-demangle)",
    "# types: \(types.count) (\(types.filter { $0.kind == classKind }.count) classes, \(types.filter { $0.kind == structKind }.count) structs, \(types.filter { $0.kind == enumKind }.count) enums); records skipped: \(skippedRecords)",
    "# unresolved type names: \(failures)",
    "# Objective-C classes implemented in Swift (@objc @implementation; listed after the Swift types): \(implementedClasses.count)",
    "# per module:",
]
for module in counts.keys.sorted() {
    let perKind = counts[module]!.keys.sorted().map { "\($0) \(counts[module]![$0]!)" }.joined(separator: ", ")
    header.append("#   \(module): \(perKind)")
}
let output = header.joined(separator: "\n") + "\n\n" + (blocks.map(\.text) + implementedBlocks).joined(separator: "\n\n") + "\n"
do { try output.write(toFile: outputPath, atomically: true, encoding: .utf8) } catch { fail("cannot write \(outputPath): \(error)") }
print("\(types.count) types, \(failures) unresolved type names, \(implementedClasses.count) Objective-C classes implemented in Swift -> \(outputPath)")
