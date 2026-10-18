import CoreServices
import Darwin
import Foundation
import SQLite3

/// One of the six places apps are looked for (REF-LAYOUT-003), and its row in `app_sources`.
///
/// Thread confinement: set up and scanned from the main thread; the volume check runs on the
/// "Launch Pad Source Event" queue and reports back to the main thread; `rescan` runs on the
/// source's operation queue.
@objc(LPAppSource)
final class LPAppSource: NSObject, LPStorageStorable, @unchecked Sendable {
    weak var _owningManager: LPAppManager?
    @objc weak var storage: LPStorage?
    var _path: String?
    var fsEventLastID: UInt64 = 0
    var fsEventUUID: String?
    var shallowPathDepth: UInt = 0
    var processQueue: OperationQueue?
    var flags: UInt64 = 0
    var setup = false
    @objc var online = false
    @objc dynamic var initialBringupComplete = false
    @objc var location: Int = 0

    /// The serial queue that brings sources online, shared by all of them.
    private static let eventQueue = DispatchQueue(label: "Launch Pad Source Event")

    @objc(initForLocation:)
    init(forLocation location: Int) {
        self.location = location
        fsEventLastID = UInt64.max
        super.init()
    }

    /// Decodes `uuid` (the location's name), `flags`, `last_fsevent_id` and `fsevent_uuid`; nil for
    /// an unknown name.
    @objc(initWithSQLStatement:)
    init?(sqlStatement statement: OpaquePointer) {
        super.init()
        guard let text = sqlite3_column_text(statement, 0) else {
            NSLog("ERROR %s requires a uuid", NSStringFromClass(type(of: self)))
            return nil
        }
        switch String(cString: text) {
        case "system": location = 2
        case "cryptexes": location = 6
        case "read only system": location = 1
        case "user": location = 3
        case "shared user": location = 4
        case "internal": location = 5
        default: return nil
        }
        flags = UInt64(bitPattern: Int64(sqlite3_column_int(statement, 1)))
        fsEventLastID = UInt64(bitPattern: sqlite3_column_int64(statement, 2))
        if let text = sqlite3_column_text(statement, 3) {
            fsEventUUID = String(cString: text)
        }
    }

    /// The `app_sources` name of each location (REF-LAYOUT-003).
    private static let locationNames = ["error", "read only system", "system", "user", "shared user", "internal", "cryptexes"]

    @objc var uuid: String? {
        Self.locationNames.indices.contains(location) ? Self.locationNames[location] : nil
    }

    @objc var path: String? { _path }
    @objc var isShallow: Bool { flags & 1 != 0 }
    @objc var sourceTableName: String { "app_sources" }

    /// Setting the first manager sets the source up and starts bringing it online.
    @objc var owningManager: LPAppManager? {
        get { _owningManager }
        set {
            _owningManager = newValue
            if !setup, _owningManager != nil {
                commonInit()
                setup = true
            }
        }
    }

    @objc func commonInit() {
        switch location {
        case 1: _path = "/System/Applications"
        case 2: _path = "/Applications"
        case 3: _path = (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        case 4: _path = "/Users/Shared"
        case 5: _path = "/AppleInternal/Applications"
        case 6: _path = "/System/Volumes/Preboot/Cryptexes/App/System/Applications"
        default: _path = nil
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        processQueue = queue
        // The FSEvents bookkeeping the original creates here belongs to phase 6.
        _bringOnlineIfPossible()
    }

    /// When the path exists, checks its volume on the event queue and then scans it fully or not
    /// at all (design, decision 5). A missing path completes its bring-up at once.
    @objc func _bringOnlineIfPossible() {
        guard !online else { return }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            // Watching for the folder to appear belongs to phase 6.
            initialBringupComplete = true
            return
        }
        if isShallow {
            shallowPathDepth = UInt(((path as NSString).standardizingPath as NSString).pathComponents.count)
        }
        Self.eventQueue.async { [self] in
            var requiresFullScan: ObjCBool = false
            if _startWatchingForChanges(&requiresFullScan) {
                let fullScan = requiresFullScan.boolValue
                DispatchQueue.main.async { [self] in
                    online = true
                    if fullScan {
                        rescan()
                    } else {
                        initialBringupComplete = true
                    }
                }
            } else {
                NSLog("LPAppSource: unable to watch %@", path)
                DispatchQueue.main.async { [self] in
                    initialBringupComplete = true
                }
            }
        }
    }

    /// Decides whether the source needs a full scan: yes when its volume's FSEvents UUID differs
    /// from the stored one or none is stored, or the volume is not local; then the new UUID and the
    /// current event ID are recorded. The original also starts an FSEvents stream here, which
    /// belongs to phase 6 (design, decision 5).
    @objc(_startWatchingForChanges:)
    func _startWatchingForChanges(_ requiresFullScan: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        guard let path else { return false }
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return false }
        defer { close(fd) }
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: &volume.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mountPoint.hasPrefix("/System/Volumes/Data") || path.hasPrefix(mountPoint) else {
            return false
        }

        var fullScan = true
        if volume.f_flags & UInt32(MNT_LOCAL) != 0 {
            let uuid = FSEventsCopyUUIDForDevice(volume.f_fsid.val.0)
            if volume.f_flags & UInt32(MNT_DONTBROWSE) != 0, uuid == nil {
                requiresFullScan?.pointee = true
                return true
            }
            guard let uuid else { return false }
            let uuidString = CFUUIDCreateString(nil, uuid) as String?
            if let stored = fsEventUUID, let uuidString, (stored as NSString).isEqual(to: uuidString) {
                fullScan = false
            } else {
                fsEventUUID = uuidString
            }
        }
        requiresFullScan?.pointee = ObjCBool(fullScan)
        if fullScan {
            fsEventLastID = FSEventsGetCurrentEventId()
            DispatchQueue.main.async { [self] in
                updateFSEventSourceStorage()
            }
        }
        return true
    }

    /// Scans the whole path on the source's queue; the first scan completes the bring-up.
    @objc func rescan() {
        processQueue?.addOperation { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            owningManager?.scanForApplications(atPath: path, fromSource: self, options: isShallow ? 8 : 9) { [self] _ in
                if !initialBringupComplete {
                    initialBringupComplete = true
                }
                NSLog("LPAppSource: scanned %@ in %.3f s", path ?? "(null)", CFAbsoluteTimeGetCurrent() - start)
            }
        }
    }
}

// MARK: - LPStorage

extension LPAppSource {
    @objc var storageCreationDictionary: [String: Any] {
        [
            "uuid": uuid as Any,
            "flags": NSNumber(value: flags),
            "fsevent_uuid": fsEventUUID ?? NSNull(),
            "last_fsevent_id": NSNumber(value: fsEventLastID),
        ]
    }

    @objc func updateFSEventSourceStorage() {
        guard let storage, let uuid else { return }
        let table = sourceTableName
        let properties: [String: Any] = [
            "last_fsevent_id": NSNumber(value: fsEventLastID),
            "fsevent_uuid": fsEventUUID ?? NSNull(),
        ]
        let box = UncheckedBox(properties)
        storage.addBlockToDatabaseQueue {
            storage._updateAppSource(uuid, properties: box.value, inTable: table)
        }
    }
}
