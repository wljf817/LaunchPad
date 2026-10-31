// Static call graph from a set of Objective-C classes of a Mach-O image.
//
// Purpose: for every method of the start classes (the original Launchpad's
// classes in the macOS 15 Dock and the Dock classes they use), list
// mechanically what the method's code refers to: the messages it sends, the
// classes it references, the selectors it passes as data, the imported
// functions it calls, and the Dock functions it calls or takes the address
// of. No method logic is interpreted. Output: a method-level graph and a
// class-level dependency matrix.
//
// Usage:
//   swift -O tools/re/callgraph.swift <thin arm64 Mach-O> <class map> <Swift types> <start classes> <output dir>
//
// <class map> is the output of tools/re/objc-classmap.swift map, <Swift
// types> the output of tools/re/swift-types.swift, both for the same file.
// <start classes> has one class name per line ("Class" or "Class(Category)";
// "#" starts a comment). Writes callgraph-methods.txt and
// callgraph-classes.txt to <output dir>. Keep inputs and outputs under
// research/ (clean room).
//
// Where each item comes from:
//   - Function boundaries: dyld_info -function_starts.
//   - Instructions: otool -tV (its "symbol stub for:" and "Objc message:"
//     comments name the imported function a stub calls).
//   - Selector of each objc_msgSend$<selector> stub: dyld_info -section
//     __TEXT __objc_stubs.
//   - Pointer slots (GOT, selector references, super references, block
//     literals): dyld_info -fixups (local rebase target or bound symbol and
//     its library).
//   - Methods and their implementation addresses, class objects,
//     superclasses, categories: the file's __objc_classlist and __objc_catlist
//     (class_ro_t method lists, relative or absolute), through the fixups.
//   - Protocols and their selectors, adopted protocols: the class map.
//   - Owning Swift type of a function: vtable and override implementations in
//     the Swift types file.
//
// Edges, recognised per function (once) by a linear pass that tracks which
// registers hold a page, an address, a selector or a class. At a branch
// target only the values equal on all incoming forward paths are kept (a
// target reached from later in the function, a loop, keeps none); after a
// call the caller-saved registers are dropped (after a call to a leaf
// function, only the registers it writes):
//   msg     bl to objc_msgSend$<sel>, or bl objc_msgSend with a selector
//           reference in x1. The receiver is exact only when x0 holds a class
//           loaded from a class reference (a class message); objc_msgSendSuper2
//           is exact too (the superclass of the class whose super reference
//           was loaded, or of the method's class; in a helper, of the class of
//           the method it is expanded into). Otherwise the candidates
//           are the Dock classes (and categories) that implement the selector
//           themselves, instance and class methods alike: one candidate is
//           "unique", more are "multi", none is "external". objc_alloc,
//           objc_alloc_init, objc_opt_new, objc_opt_class, objc_opt_self and
//           objc_allocWithZone are recorded as the messages they stand for.
//   class   a class reference (GOT slot or address of a class object).
//   sel     a selector reference that is not the selector of a message send.
//   import  bl/b to an imported function's stub; the library from the fixups.
//   call    bl/b to the implementation of an Objective-C method, or to a Swift
//           vtable or override implementation (exact).
//   other Dock functions (helpers, block implementations, Swift functions
//           without a vtable entry) that are called (bl, or b to another
//           function) or whose address is taken (adr, adrp+add, a GOT slot,
//           or a global block literal's invoke pointer) contribute their own
//           edges to the method, marked "via" the first such function; cycles
//           are followed once.
//   unresolved  blr/br and their authenticated forms (unless the register holds
//           an imported function from a GOT slot, or a Dock function's address).
//   Calls to objc_msgSend whose selector is not known are counted separately.
//
// Class matrix: one row per start class and target (a class, a Swift type,
// "(external)" for messages no Dock class implements, or "lib:<library>"),
// with distinct-edge counts per kind; messages and selector references are
// split into exact, unique and multi. "protocol-only" lists the protocols when
// every established edge to the target (all but "multi") is a message or
// selector reference whose selector belongs to a protocol the target adopts;
// it reads "(multi only)" when the target has multi-candidate edges only.

import CryptoKit
import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let usage = "usage: swift -O tools/re/callgraph.swift <thin arm64 Mach-O> <class map> <Swift types> <start classes> <output dir>"

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

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16, uppercase: true) }

func parseHex<S: StringProtocol>(_ text: S) -> UInt64? {
    text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : nil
}

/// "#0x10", "#16", "#-0x8" -> Int64
func parseImmediate<S: StringProtocol>(_ text: S) -> Int64? {
    var body = Substring(text)
    guard body.hasPrefix("#") else { return nil }
    body = body.dropFirst()
    var negative = false
    if body.hasPrefix("-") { negative = true; body = body.dropFirst() }
    let value = body.hasPrefix("0x") ? Int64(body.dropFirst(2), radix: 16) : Int64(body)
    return value.map { negative ? -$0 : $0 }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5 else { fail(usage, status: 2) }
let (inputPath, classMapPath, swiftTypesPath, startPath, outputDirectory) = (arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
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
    if le(commandOffset, 4) == 0x19 {  // LC_SEGMENT_64
        segments.append(Segment(vmaddr: le(commandOffset + 24, 8), fileoff: le(commandOffset + 40, 8), filesize: le(commandOffset + 48, 8)))
        for index in 0..<Int(le(commandOffset + 64, 4)) {
            let header = commandOffset + 72 + index * 80
            sections["\(fixedName(header + 16)),\(fixedName(header))"] = Section(address: le(header + 32, 8), size: le(header + 40, 8))
        }
    }
    commandOffset += Int(le(commandOffset + 4, 4))
}

func fileOffset(_ address: UInt64) -> Int? {
    for segment in segments where address >= segment.vmaddr && address < segment.vmaddr + segment.filesize {
        return Int(segment.fileoff + address - segment.vmaddr)
    }
    return nil
}

func u32(_ address: UInt64) -> UInt32 { fileOffset(address).map { UInt32(le($0, 4)) } ?? 0 }
func i32(_ address: UInt64) -> Int32 { Int32(bitPattern: u32(address)) }
func offset(_ address: UInt64, by value: Int32) -> UInt64 { UInt64(bitPattern: Int64(bitPattern: address) + Int64(value)) }

func cString(_ address: UInt64) -> String {
    guard let start = fileOffset(address) else { return "?" }
    var end = start
    while end < bytes.count, bytes[end] != 0 { end += 1 }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

func inSection(_ address: UInt64, _ name: String) -> Bool {
    guard let section = sections[name] else { return false }
    return address >= section.address && address < section.address + section.size
}

// MARK: - Fixups

enum Target { case local(UInt64), symbol(library: String, name: String) }

var fixups: [UInt64: Target] = [:]
var libraryOfSymbol: [String: String] = [:]
for line in run("dyld_info", ["-fixups", inputPath]).split(separator: "\n") {
    let fields = line.split(separator: " ")
    guard fields.count >= 5, let address = parseHex(fields[2]) else { continue }
    if fields[3].hasSuffix("rebase"), let target = parseHex(fields[4]) {
        fixups[address] = .local(target)
    } else if fields[3].hasSuffix("bind") {
        let parts = fields[4].split(separator: "/", maxSplits: 1)
        let library = parts.count == 2 ? String(parts[0]) : "?"
        let name = String(parts.last ?? "")
        fixups[address] = .symbol(library: library, name: name)
        libraryOfSymbol[name] = library
    }
}
guard !fixups.isEmpty else { fail("dyld_info -fixups listed nothing for \(inputPath)") }

func pointedString(_ slot: UInt64) -> String? {
    guard case .local(let address)? = fixups[slot] else { return nil }
    return cString(address)
}

// MARK: - Objective-C metadata

struct Method { var owner: String; var isClassMethod: Bool; var selector: String; var category: String? }

var methodsByImp: [UInt64: [Method]] = [:]
var implementers: [String: Set<String>] = [:]  // selector -> owner names ("Class" or "Class(Category)")
var classNameOfObject: [UInt64: String] = [:]  // class objects and metaclasses
var superclassOf: [String: String] = [:]

func methodList(_ slot: UInt64) -> [(selector: String, imp: UInt64)] {
    guard case .local(let list)? = fixups[slot] else { return [] }
    let flags = u32(list)
    let count = UInt64(u32(list + 4))
    var result: [(String, UInt64)] = []
    if flags & 0x8000_0000 != 0 {  // relative method list: name (selector reference), types, imp
        for index in 0..<count {
            let entry = list + 8 + index * 12
            let selectorReference = offset(entry, by: i32(entry))
            let imp = offset(entry + 8, by: i32(entry + 8))
            result.append((pointedString(selectorReference) ?? "?", imp))
        }
    } else {  // absolute: name, types, imp pointers
        let size = UInt64(flags & 0xFFFC)
        for index in 0..<count {
            let entry = list + 8 + index * size
            guard case .local(let imp)? = fixups[entry + 16] else { continue }
            result.append((pointedString(entry) ?? "?", imp))
        }
    }
    return result
}

func className(of classObject: UInt64) -> String? {
    guard case .local(let data)? = fixups[classObject + 0x20] else { return nil }
    return pointedString((data & ~7) + 0x18)
}

func record(_ methods: [(selector: String, imp: UInt64)], owner: String, isClassMethod: Bool, category: String?) {
    let ownerName = category.map { "\(owner)(\($0))" } ?? owner
    for method in methods {
        methodsByImp[method.imp, default: []].append(Method(owner: owner, isClassMethod: isClassMethod, selector: method.selector, category: category))
        implementers[method.selector, default: []].insert(ownerName)
    }
}

if let classList = sections["__DATA_CONST,__objc_classlist"] ?? sections["__DATA,__objc_classlist"] {
    for slot in stride(from: classList.address, to: classList.address + classList.size, by: 8) {
        guard case .local(let classObject)? = fixups[slot], let name = className(of: classObject),
              case .local(let data)? = fixups[classObject + 0x20] else { continue }
        classNameOfObject[classObject] = name
        switch fixups[classObject + 8] {
        case .local(let superObject)?: superclassOf[name] = className(of: superObject)
        case .symbol(_, let symbol)?: superclassOf[name] = symbol.hasPrefix("_OBJC_CLASS_$_") ? String(symbol.dropFirst(14)) : symbol
        case nil: break
        }
        record(methodList((data & ~7) + 0x20), owner: name, isClassMethod: false, category: nil)
        if case .local(let metaclass)? = fixups[classObject], case .local(let metaData)? = fixups[metaclass + 0x20] {
            classNameOfObject[metaclass] = name
            record(methodList((metaData & ~7) + 0x20), owner: name, isClassMethod: true, category: nil)
        }
    }
}
if let categoryList = sections["__DATA_CONST,__objc_catlist"] ?? sections["__DATA,__objc_catlist"] {
    for slot in stride(from: categoryList.address, to: categoryList.address + categoryList.size, by: 8) {
        guard case .local(let category)? = fixups[slot], let name = pointedString(category) else { continue }
        let owner: String
        switch fixups[category + 8] {
        case .local(let classObject)?: owner = className(of: classObject) ?? "?"
        case .symbol(_, let symbol)?: owner = symbol.hasPrefix("_OBJC_CLASS_$_") ? String(symbol.dropFirst(14)) : symbol
        case nil: continue
        }
        record(methodList(category + 16), owner: owner, isClassMethod: false, category: name)
        record(methodList(category + 24), owner: owner, isClassMethod: true, category: name)
    }
}
guard !methodsByImp.isEmpty else { fail("no Objective-C methods found in \(inputPath)") }

// Protocols (selectors) and adopted protocols from the class map.
guard let classMap = try? String(contentsOfFile: classMapPath, encoding: .utf8) else { fail("cannot read \(classMapPath)") }
var protocolsOfSelector: [String: Set<String>] = [:]
var protocolParents: [String: [String]] = [:]
var adoptedProtocols: [String: [String]] = [:]
do {
    var currentProtocol: String?
    for line in classMap.split(separator: "\n") {
        if line.hasPrefix("## @protocol ") {
            let words = line.dropFirst(13).split(separator: " ", maxSplits: 1)
            currentProtocol = String(words[0])
            protocolParents[String(words[0])] = words.count > 1
                ? words[1].trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
        } else if line.hasPrefix("## ") {
            currentProtocol = nil
            let header = line.dropFirst(3)
            if let colon = header.range(of: " : ") {
                let name = String(header[..<colon.lowerBound])
                if let open = header.firstIndex(of: "<"), let close = header.lastIndex(of: ">") {
                    adoptedProtocols[name] = header[header.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            }
        } else if let current = currentProtocol, let range = line.range(of: #"^\s+(required|optional) [-+]"#, options: .regularExpression) {
            protocolsOfSelector[String(line[range.upperBound...]), default: []].insert(current)
        }
    }
}

/// All protocols a class adopts, through its superclasses and the protocols' parents.
func allProtocols(of className: String) -> Set<String> {
    var result: Set<String> = []
    var pending: [String] = []
    var current: String? = className
    while let name = current {
        pending += adoptedProtocols[name] ?? []
        current = superclassOf[name]
    }
    while let next = pending.popLast() {
        if result.insert(next).inserted { pending += protocolParents[next] ?? [] }
    }
    return result
}

// Swift vtable and override implementations -> owning Swift type.
guard let swiftTypes = try? String(contentsOfFile: swiftTypesPath, encoding: .utf8) else { fail("cannot read \(swiftTypesPath)") }
var swiftTypeOfFunction: [UInt64: String] = [:]
do {
    var currentType = ""
    for line in swiftTypes.split(separator: "\n") {
        if line.hasPrefix("## ") { currentType = String(line.dropFirst(3)) }
        else if line.hasPrefix("  impl "), let address = parseHex(line.split(separator: " ")[1]) { swiftTypeOfFunction[address] = "Swift " + currentType }
    }
}

// Start classes.
guard let startText = try? String(contentsOfFile: startPath, encoding: .utf8) else { fail("cannot read \(startPath)") }
let startClasses = Set(startText.split(separator: "\n").map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

// MARK: - Code

var functionStarts: [UInt64] = []
for line in run("dyld_info", ["-function_starts", inputPath]).split(separator: "\n") {
    if let address = parseHex(line.split(separator: " ").first ?? "") { functionStarts.append(address) }
}
functionStarts.sort()
let functionStartSet = Set(functionStarts)
guard !functionStarts.isEmpty else { fail("dyld_info -function_starts listed nothing for \(inputPath)") }

var stubSelectors: [UInt64: String] = [:]
do {
    var pending: String?
    for line in run("dyld_info", ["-section", "__TEXT", "__objc_stubs", inputPath]).split(separator: "\n") {
        if line.hasPrefix("_objc_msgSend$"), line.hasSuffix(":") {
            pending = String(line.dropFirst(14).dropLast())
        } else if let selector = pending, let address = parseHex(line.split(separator: " ").first ?? "") {
            stubSelectors[address] = selector
            pending = nil
        }
    }
}

struct Instruction { var address: UInt64; var mnemonic: Substring; var operands: Substring; var comment: Substring }

var instructions: [Instruction] = []
var stubSymbols: [UInt64: String] = [:]  // import stub address -> symbol
for line in run("otool", ["-tV", inputPath]).split(separator: "\n") {
    let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count >= 2, fields[0].count == 16, let address = UInt64(fields[0], radix: 16) else { continue }
    var operands: Substring = fields.count > 2 ? fields[2] : ""
    var comment: Substring = ""
    if let semicolon = operands.range(of: " ; ") {
        comment = operands[semicolon.upperBound...]
        operands = operands[..<semicolon.lowerBound]
    }
    if fields[1] == "bl" || fields[1] == "b", let target = parseHex(operands) {
        for marker in ["symbol stub for: ", "Objc message: "] where comment.hasPrefix(marker) {
            stubSymbols[target] = String(comment.dropFirst(marker.count))
        }
    }
    instructions.append(Instruction(address: address, mnemonic: fields[1], operands: operands, comment: comment))
}
guard !instructions.isEmpty else { fail("otool -tV gave no instructions for \(inputPath)") }
var instructionIndex: [UInt64: Int] = [:]
for (index, instruction) in instructions.enumerated() { instructionIndex[instruction.address] = index }

/// Index range of the instructions of the function starting at `start`.
func functionRange(_ start: UInt64) -> Range<Int>? {
    guard let first = instructionIndex[start] else { return nil }
    var low = 0, high = functionStarts.count
    while low < high { let mid = (low + high) / 2; if functionStarts[mid] <= start { low = mid + 1 } else { high = mid } }
    let end = low < functionStarts.count ? functionStarts[low] : UInt64.max
    var last = first
    while last < instructions.count, instructions[last].address < end { last += 1 }
    return first..<last
}

// MARK: - Edges

enum Value: Equatable {
    case page(UInt64)
    case address(UInt64)
    case selector(String, consumed: Int)  // consumed: id of the load
    case objcClass(String)
    case superClass(String)
    case function(String)  // an imported function's address, from a GOT slot
}

struct Edge: Hashable {
    var kind: String        // msg, class, sel, import, call
    var name: String        // selector, class, symbol, method
    var certainty: String   // exact, unique, multi, external, "" (non-message)
    var targets: [String]   // classes, Swift types, "lib:..." or "(external)"
    var protocols: [String]
    var via: String
}

struct FunctionFacts {
    var edges: Set<Edge> = []
    var helpers: [UInt64] = []
    var unresolved = 0
    var unknownSelectors = 0
}

let runtimeMessages: [String: [String]] = [
    "_objc_alloc": ["alloc"], "_objc_alloc_init": ["alloc", "init"], "_objc_opt_new": ["new"],
    "_objc_opt_class": ["class"], "_objc_opt_self": ["self"], "_objc_allocWithZone": ["allocWithZone:"],
]

func messageEdge(selector: String, receiverClass: String?, via: String) -> Edge {
    let protocols = (protocolsOfSelector[selector] ?? []).sorted()
    if let receiverClass {
        return Edge(kind: "msg", name: selector, certainty: "exact", targets: [receiverClass], protocols: protocols, via: via)
    }
    let candidates = (implementers[selector] ?? []).sorted()
    let certainty = candidates.isEmpty ? "external" : candidates.count == 1 ? "unique" : "multi"
    return Edge(kind: "msg", name: selector, certainty: certainty, targets: candidates.isEmpty ? ["(external)"] : candidates, protocols: protocols, via: via)
}

func methodName(_ method: Method) -> String {
    let owner = method.category.map { "\(method.owner)(\($0))" } ?? method.owner
    return "\(method.isClassMethod ? "+" : "-")[\(owner) \(method.selector)]"
}

/// Class or Swift type a code address belongs to, when it is a method implementation.
func ownerOfFunction(_ address: UInt64) -> (target: String, name: String)? {
    if let method = methodsByImp[address]?.first {
        return (method.category.map { "\(method.owner)(\($0))" } ?? method.owner, methodName(method))
    }
    if let type = swiftTypeOfFunction[address] { return (type, "\(type) \(hex(address))") }
    return nil
}

func valueOfSlot(_ slot: UInt64) -> Value? {
    if inSection(slot, "__DATA,__objc_selrefs") { return pointedString(slot).map { .selector($0, consumed: 0) } }
    switch fixups[slot] {
    case .local(let target)?:
        if let name = classNameOfObject[target] {
            return inSection(slot, "__DATA_CONST,__objc_superrefs") || inSection(slot, "__DATA,__objc_superrefs") ? .superClass(name) : .objcClass(name)
        }
        return .address(target)
    case .symbol(_, let name)?:
        if name.hasPrefix("_OBJC_CLASS_$_") { return .objcClass(String(name.dropFirst(14))) }
        return .function(name)
    case nil:
        return nil
    }
}

let noDestination: Set<Substring> = ["str", "stp", "strb", "strh", "stur", "sturb", "sturh", "stlr", "stxr", "stlxr", "cmp", "cmn", "tst", "ccmp", "ccmn",
                                     "b", "bl", "br", "blr", "braa", "brab", "blraa", "blrab", "braaz", "blraaz", "brabz", "blrabz", "ret", "retaa", "retab",
                                     "cbz", "cbnz", "tbz", "tbnz", "nop", "pacibsp", "paciasp", "autibsp", "autiasp", "brk", "dmb", "dsb", "isb", "hint",
                                     "fcmp", "fccmp", "stlxp", "stxp", "stnp", "prfm", "msr", "svc"]

func registerNumber<S: StringProtocol>(_ operand: S) -> Int? {
    guard operand.hasPrefix("x"), let number = Int(operand.dropFirst()), number <= 30 else { return nil }
    return number
}

/// General-purpose registers an instruction writes (an x or w register as the first operand, and the
/// second one of a load pair), unless the mnemonic has no destination.
func destinationRegisters(_ instruction: Instruction, _ operands: [String]) -> [Int] {
    guard !noDestination.contains(instruction.mnemonic), let first = operands.first else { return [] }
    var result: [Int] = []
    for operand in [first] + (["ldp", "ldpsw", "ldnp", "ldaxp", "ldxp"].contains(instruction.mnemonic) && operands.count > 1 ? [operands[1]] : [])
    where operand.hasPrefix("x") || operand.hasPrefix("w") {
        if let number = Int(operand.dropFirst()), number <= 30 { result.append(number) }
    }
    return result
}

var factsCache: [UInt64: FunctionFacts] = [:]
var leafCache: [UInt64: Set<Int>?] = [:]

/// Registers written by a leaf function (no calls, no branches out, no indirect branches), or nil.
/// After a call to a leaf, only these registers lose their tracked values (the machine outliner
/// moves short register-copying sequences into such functions).
func leafWrites(_ start: UInt64) -> Set<Int>? {
    if let cached = leafCache[start] { return cached }
    var result: Set<Int>? = []
    if let range = functionRange(start) {
        let end = range.upperBound < instructions.count ? instructions[range.upperBound].address : UInt64.max
        for index in range {
            let instruction = instructions[index]
            let mnemonic = instruction.mnemonic
            let operands = instruction.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if mnemonic.hasPrefix("bl") || mnemonic.hasPrefix("br") || (mnemonic == "b" && (parseHex(operands.first ?? "").map { $0 < start || $0 >= end } ?? true)) {
                result = nil
                break
            }
            result?.formUnion(destinationRegisters(instruction, operands))
        }
    } else {
        result = nil
    }
    leafCache[start] = result
    return result
}
var outsideStartTargets = 0

func facts(_ start: UInt64) -> FunctionFacts {
    if let cached = factsCache[start] { return cached }
    var result = FunctionFacts()
    guard let range = functionRange(start) else { factsCache[start] = result; return result }
    let end = range.upperBound < instructions.count ? instructions[range.upperBound].address : UInt64.max

    // Branch targets inside the function. At a target reached only by forward branches, the tracked
    // values are those equal on every incoming path (the branches and the fall-through); at a target
    // also reached from later in the function (a loop), tracking restarts.
    var labelSources: [UInt64: [UInt64]] = [:]
    for index in range {
        let instruction = instructions[index]
        if instruction.mnemonic.hasPrefix("b") || instruction.mnemonic.hasPrefix("cb") || instruction.mnemonic.hasPrefix("tb"),
           let last = instruction.operands.split(separator: " ").last, let target = parseHex(last), target >= start, target < end {
            labelSources[target, default: []].append(instruction.address)
        }
    }
    var pendingStates: [UInt64: [[Int: Value]]] = [:]
    var fallsThrough = true

    var registers: [Int: Value] = [:]
    var lastSuperClass: String?
    let ownClass = methodsByImp[start]?.first?.owner
    var selectorLoads: [Int: String] = [:]
    var consumedLoads: Set<Int> = []
    var loadCounter = 0

    func addHelper(_ target: UInt64) {
        if target != start, !result.helpers.contains(target) { result.helpers.append(target) }
    }

    func noteAddress(_ address: UInt64) {
        if functionStartSet.contains(address), inSection(address, "__TEXT,__text") {
            if let owner = ownerOfFunction(address) {
                result.edges.insert(Edge(kind: "call", name: owner.name, certainty: "exact", targets: [owner.target], protocols: [], via: ""))
            } else {
                addHelper(address)
            }
        } else if let name = classNameOfObject[address] {
            result.edges.insert(Edge(kind: "class", name: name, certainty: "exact", targets: [name], protocols: [], via: ""))
        } else if case .symbol(_, let isa)? = fixups[address], isa.hasSuffix("NSConcreteGlobalBlock"), case .local(let invoke)? = fixups[address + 16] {
            addHelper(invoke)
        }
    }

    func setValue(_ register: Int, _ value: Value?) {
        var value = value
        if case .address(let address)? = value, let name = classNameOfObject[address] { value = .objcClass(name) }  // adrp+add to a class object
        registers[register] = value
        guard let value else { return }
        switch value {
        case .objcClass(let name):
            result.edges.insert(Edge(kind: "class", name: name, certainty: "exact", targets: [name], protocols: [], via: ""))
        case .superClass(let name):
            lastSuperClass = name
        case .address(let address):
            noteAddress(address)
        default:
            break
        }
    }

    func callSelector(_ selector: String) {
        var receiver: String?
        if case .objcClass(let name)? = registers[0] { receiver = name }
        result.edges.insert(messageEdge(selector: selector, receiverClass: receiver, via: ""))
    }

    func callSymbol(_ symbol: String) {
        if symbol == "_objc_msgSend" || symbol == "_objc_msgSendSuper2" {
            guard case .selector(let selector, let load)? = registers[1] else { result.unknownSelectors += 1; return }
            consumedLoads.insert(load)
            if symbol == "_objc_msgSendSuper2" {
                // the superclass of the class whose super reference was loaded, of this method's class,
                // or (in a helper) of the class of the method the helper is expanded into
                let superclass = (lastSuperClass ?? ownClass).map { superclassOf[$0] ?? "?" } ?? "(super)"
                result.edges.insert(Edge(kind: "msg", name: selector, certainty: "exact", targets: [superclass], protocols: (protocolsOfSelector[selector] ?? []).sorted(), via: ""))
            } else {
                callSelector(selector)
            }
        } else if let selectors = runtimeMessages[symbol] {
            for selector in selectors { callSelector(selector) }
        } else {
            result.edges.insert(Edge(kind: "import", name: symbol, certainty: "", targets: ["lib:" + (libraryOfSymbol[symbol] ?? "?")], protocols: [], via: ""))
        }
    }

    func callTarget(_ target: UInt64) {
        if let selector = stubSelectors[target] {
            callSelector(selector)
        } else if let symbol = stubSymbols[target] {
            callSymbol(symbol)
        } else if inSection(target, "__TEXT,__text") {
            if !functionStartSet.contains(target) { outsideStartTargets += 1 }
            if let owner = ownerOfFunction(target) {
                result.edges.insert(Edge(kind: "call", name: owner.name, certainty: "exact", targets: [owner.target], protocols: [], via: ""))
            } else {
                addHelper(target)
            }
        }
    }

    for index in range {
        let instruction = instructions[index]
        if let sources = labelSources[instruction.address] {
            if sources.contains(where: { $0 >= instruction.address }) {
                registers = [:]
            } else {
                var merged: [Int: Value]? = fallsThrough ? registers : nil
                for state in pendingStates[instruction.address] ?? [] {
                    merged = merged.map { current in current.filter { state[$0.key] == $0.value } } ?? state
                }
                registers = merged ?? [:]
            }
        }
        fallsThrough = !["b", "br", "braa", "brab", "braaz", "brabz", "ret", "retaa", "retab", "brk"].contains(instruction.mnemonic)
        if instruction.mnemonic.hasPrefix("b") || instruction.mnemonic.hasPrefix("cb") || instruction.mnemonic.hasPrefix("tb"),
           let last = instruction.operands.split(separator: " ").last, let target = parseHex(last), target > instruction.address, target < end {
            pendingStates[target, default: []].append(registers)
        }
        let mnemonic = instruction.mnemonic
        let operands = instruction.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        switch mnemonic {
        case "adrp":
            if let destination = registerNumber(operands.first ?? ""), let page = parseHex(instruction.comment.split(separator: " ").first ?? "") {
                registers[destination] = .page(page)
            } else if let destination = registerNumber(operands.first ?? "") { registers[destination] = nil }
        case "add":
            guard operands.count >= 3, let destination = registerNumber(operands[0]) else {
                for register in destinationRegisters(instruction, operands) { registers[register] = nil }
                break
            }
            if let base = registerNumber(operands[1]), case .page(let page)? = registers[base], let immediate = parseImmediate(operands[2]) {
                setValue(destination, .address(UInt64(bitPattern: Int64(bitPattern: page) + immediate)))
            } else {
                registers[destination] = nil
            }
        case "adr":
            guard let destination = registerNumber(operands.first ?? "") else { break }
            if operands.count >= 2, let immediate = parseImmediate(operands[1]) {
                setValue(destination, .address(UInt64(bitPattern: Int64(bitPattern: instruction.address) + immediate)))
            } else {
                registers[destination] = nil
            }
        case "ldr":
            guard let destination = registerNumber(operands.first ?? "") else {
                if let first = operands.first, first.hasPrefix("w") || first.hasPrefix("x") { registers[Int(first.dropFirst()) ?? -1] = nil }
                break
            }
            // ldr xD, [xN, #imm] or ldr xD, [xN]
            let memory = instruction.operands.drop { $0 != "[" }
            if memory.hasSuffix("]"), !memory.contains("!") {
                let inner = memory.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if let base = registerNumber(inner[0]), case .page(let page)? = registers[base] {
                    let slot = UInt64(bitPattern: Int64(bitPattern: page) + (inner.count > 1 ? parseImmediate(inner[1]) ?? 0 : 0))
                    if case .selector(let selector, _)? = valueOfSlot(slot) {
                        loadCounter += 1
                        selectorLoads[loadCounter] = selector
                        registers[destination] = .selector(selector, consumed: loadCounter)
                    } else {
                        setValue(destination, valueOfSlot(slot))
                    }
                    break
                }
            }
            registers[destination] = nil
        case "mov":
            guard operands.count == 2, let destination = registerNumber(operands[0]) else {
                for register in destinationRegisters(instruction, operands) { registers[register] = nil }
                break
            }
            if let source = registerNumber(operands[1]) { registers[destination] = registers[source] } else { registers[destination] = nil }
        case "bl":
            let target = parseHex(operands.first ?? "")
            if let target { callTarget(target) }
            else if let operand = operands.first, operand.hasPrefix("_objc_msgSend$") { callSelector(String(operand.dropFirst(14))) }
            if let target, inSection(target, "__TEXT,__text"), let written = leafWrites(target) {
                for register in written { registers[register] = nil }
            } else {
                for register in 0...18 { registers[register] = nil }
            }
            registers[30] = nil
        case "b":
            if let target = parseHex(operands.first ?? ""), target < start || target >= end { callTarget(target) }
        case "blr", "br", "blraa", "blrab", "braa", "brab", "blraaz", "blrabz", "braaz", "brabz":
            switch registerNumber(operands.first ?? "").flatMap({ registers[$0] }) {
            case .function(let symbol)?: callSymbol(symbol)
            case .address(let address)? where inSection(address, "__TEXT,__text"): callTarget(address)
            default: result.unresolved += 1
            }
            if mnemonic.hasPrefix("bl") { for register in 0...18 { registers[register] = nil }; registers[30] = nil }
        default:
            for register in destinationRegisters(instruction, operands) { registers[register] = nil }
        }
    }
    for (load, selector) in selectorLoads where !consumedLoads.contains(load) {
        let candidates = (implementers[selector] ?? []).sorted()
        let certainty = candidates.isEmpty ? "external" : candidates.count == 1 ? "unique" : "multi"
        result.edges.insert(Edge(kind: "sel", name: selector, certainty: certainty, targets: candidates.isEmpty ? ["(external)"] : candidates,
                                 protocols: (protocolsOfSelector[selector] ?? []).sorted(), via: ""))
    }
    factsCache[start] = result
    return result
}

/// A method's edges: its own, plus those of the helpers it reaches, marked with the first helper.
func methodEdges(_ imp: UInt64, owner: String) -> (edges: Set<Edge>, unresolved: Int, unknownSelectors: Int, helpers: Int) {
    let own = facts(imp)
    var edges = own.edges
    var unresolved = own.unresolved
    var unknownSelectors = own.unknownSelectors
    var visited: Set<UInt64> = [imp]
    var queue: [(UInt64, String)] = own.helpers.map { ($0, "fn_" + hex($0)) }
    while !queue.isEmpty {
        let (helper, via) = queue.removeFirst()
        guard visited.insert(helper).inserted else { continue }
        let helperFacts = facts(helper)
        unresolved += helperFacts.unresolved
        unknownSelectors += helperFacts.unknownSelectors
        for var edge in helperFacts.edges {
            edge.via = via
            if edge.targets == ["(super)"] { edge.targets = [superclassOf[owner] ?? "?"] }
            edges.insert(edge)
        }
        queue += helperFacts.helpers.map { ($0, via) }
    }
    return (edges, unresolved, unknownSelectors, visited.count - 1)
}

// MARK: - Run

struct MethodEntry { var name: String; var source: String; var imp: UInt64 }
var entries: [MethodEntry] = []
for (imp, methods) in methodsByImp {
    for method in methods {
        let owner = method.category.map { "\(method.owner)(\($0))" } ?? method.owner
        if startClasses.contains(owner) || (method.category != nil && startClasses.contains(method.owner)) {
            entries.append(MethodEntry(name: methodName(method), source: owner, imp: imp))
        }
    }
}
entries.sort { ($0.source, $0.name) < ($1.source, $1.name) }
let foundClasses = Set(entries.map { $0.source.split(separator: "(").first.map(String.init) ?? $0.source })
let missingClasses = startClasses.filter { name in !foundClasses.contains(name) && !entries.contains { $0.source == name } }.sorted()

struct Cell { var counts: [String: Int] = [:]; var certain = 0; var protocolOnly = true; var protocols: Set<String> = [] }
var matrix: [String: [String: Cell]] = [:]
var methodLines: [String] = []
var totalUnresolved = 0
var totalUnknownSelectors = 0
var totalEdges = 0

for entry in entries {
    let (edges, unresolved, unknownSelectors, helpers) = methodEdges(entry.imp, owner: entry.source.split(separator: "(").first.map(String.init) ?? entry.source)
    totalUnresolved += unresolved
    totalUnknownSelectors += unknownSelectors
    totalEdges += edges.count
    var lines = ["## \(entry.name) \(hex(entry.imp))", "  helpers: \(helpers), unresolved indirect calls: \(unresolved), objc_msgSend with unknown selector: \(unknownSelectors)"]
    let sorted = edges.sorted { ($0.kind, $0.name, $0.via, $0.targets.joined()) < ($1.kind, $1.name, $1.via, $1.targets.joined()) }
    for edge in sorted {
        lines.append("  " + [edge.kind, edge.name, edge.certainty.isEmpty ? "-" : edge.certainty, edge.targets.joined(separator: ","),
                             edge.protocols.isEmpty ? "-" : edge.protocols.joined(separator: ","), edge.via.isEmpty ? "-" : edge.via].joined(separator: "\t"))
        let column = edge.kind == "msg" || edge.kind == "sel" ? "\(edge.kind).\(edge.certainty)" : edge.kind
        for target in edge.targets {
            var cell = matrix[entry.source, default: [:]][target, default: Cell()]
            cell.counts[column, default: 0] += 1
            if edge.certainty != "multi" {  // the protocol-only test looks at the established edges only
                cell.certain += 1
                let adopted = target.hasPrefix("lib:") || target.hasPrefix("(") ? [] : allProtocols(of: target.split(separator: "(").first.map(String.init) ?? target)
                let shared = Set(edge.protocols).intersection(adopted)
                if edge.kind == "msg" || edge.kind == "sel", !shared.isEmpty { cell.protocols.formUnion(shared) } else { cell.protocolOnly = false }
            }
            matrix[entry.source, default: [:]][target] = cell
        }
    }
    methodLines.append(lines.joined(separator: "\n"))
}

let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
let header = [
    "# input: \((inputPath as NSString).lastPathComponent), sha256 \(digest)",
    "# sources: function starts, __objc_stubs, fixups (dyld_info); instructions (otool -tV); methods, classes, categories (__objc_classlist, __objc_catlist); protocols (class map); Swift vtables (Swift types)",
    "# start classes: \(startClasses.count) (without methods of their own: \(missingClasses.isEmpty ? "none" : missingClasses.joined(separator: ", "))); methods: \(entries.count); distinct edges: \(totalEdges); unresolved indirect calls: \(totalUnresolved); objc_msgSend with unknown selector: \(totalUnknownSelectors); calls into the middle of a function: \(outsideStartTargets)",
]
let methodHeader = header + ["# edge columns: kind, name, certainty, targets, protocols, via"]
let columns = ["class", "msg.exact", "msg.unique", "msg.multi", "msg.external", "sel.unique", "sel.multi", "sel.external", "call", "import"]
var matrixLines = header + ["# columns: source, target, " + columns.joined(separator: ", ") + ", protocol-only"]
for source in matrix.keys.sorted() {
    for target in matrix[source]!.keys.sorted() {
        let cell = matrix[source]![target]!
        let protocolOnly = cell.certain == 0 ? "(multi only)" : cell.protocolOnly && !cell.protocols.isEmpty ? cell.protocols.sorted().joined(separator: ",") : "-"
        matrixLines.append(([source, target] + columns.map { String(cell.counts[$0] ?? 0) } + [protocolOnly]).joined(separator: "\t"))
    }
}

do {
    try (methodHeader.joined(separator: "\n") + "\n\n" + methodLines.joined(separator: "\n\n") + "\n")
        .write(toFile: (outputDirectory as NSString).appendingPathComponent("callgraph-methods.txt"), atomically: true, encoding: .utf8)
    try (matrixLines.joined(separator: "\n") + "\n")
        .write(toFile: (outputDirectory as NSString).appendingPathComponent("callgraph-classes.txt"), atomically: true, encoding: .utf8)
} catch { fail("cannot write to \(outputDirectory): \(error)") }
print("\(entries.count) methods, \(totalEdges) edges, \(totalUnresolved) unresolved indirect calls -> \(outputDirectory)")
