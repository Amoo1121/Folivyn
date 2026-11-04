import CryptoKit
import Darwin
import Foundation

public struct DraftRecoverySelection: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int = 0, length: Int = 0) { self.location = location; self.length = length }
}

/// Origin is a display hint only. Recovery never reads or writes that path.
public struct DraftRecoverySnapshot: Equatable, Sendable {
    public let documentID: UUID
    public let generation: UInt64
    public let text: String
    public let originPath: String?
    public let encodingHint: TextFileEncoding?
    public let selection: DraftRecoverySelection
    public let updatedAt: Date

    public init(documentID: UUID, generation: UInt64, text: String, originPath: String? = nil,
                encodingHint: TextFileEncoding? = nil, selection: DraftRecoverySelection = .init(),
                updatedAt: Date = Date()) {
        self.documentID = documentID; self.generation = generation; self.text = text
        self.originPath = originPath; self.encodingHint = encodingHint
        self.selection = selection; self.updatedAt = updatedAt
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.documentID == rhs.documentID && lhs.generation == rhs.generation &&
        lhs.text.utf16.elementsEqual(rhs.text.utf16) && lhs.originPath == rhs.originPath &&
        lhs.encodingHint == rhs.encodingHint && lhs.selection == rhs.selection && lhs.updatedAt == rhs.updatedAt
    }
}

public struct DraftRecoveryLimits: Sendable {
    public var maximumSnapshotBytes: Int
    public var maximumTotalBytes: Int
    public var maximumDraftCount: Int
    public var maximumDirectoryEntries: Int
    public init(maximumSnapshotBytes: Int = 32 * 1_024 * 1_024, maximumTotalBytes: Int = 256 * 1_024 * 1_024,
                maximumDraftCount: Int = 128, maximumDirectoryEntries: Int = 2_048) {
        self.maximumSnapshotBytes = maximumSnapshotBytes; self.maximumTotalBytes = maximumTotalBytes
        self.maximumDraftCount = maximumDraftCount; self.maximumDirectoryEntries = maximumDirectoryEntries
    }
}

public enum DraftRecoveryError: Error, Equatable, Sendable {
    case invalidConfiguration, unsafePath, closed, storeBusy, instanceActive, staleGeneration
    case snapshotLimit, totalLimit, draftCountLimit, directoryEntryLimit
    case invalidSnapshot, unsupportedVersion, checksumMismatch, invalidSelection, changedRecovery
    case io(operation: String, code: Int32)
}

public struct DraftRecoveryReference: Equatable, Sendable {
    public let instanceID: UUID
    public let documentID: UUID
    public let generation: UInt64
    public let checksum: Data
}

public struct RecoveredDraft: Sendable {
    public let reference: DraftRecoveryReference
    public let snapshot: DraftRecoverySnapshot
}

public struct DraftRecoveryIssue: Sendable {
    public let instanceID: UUID
    public let documentID: UUID?
    public let error: DraftRecoveryError
}

public struct DraftRecoveryScan: Sendable {
    public let drafts: [RecoveredDraft]
    public let issues: [DraftRecoveryIssue]
    public let activeInstanceCount: Int
}

/// A single writer for this process instance. All filesystem operations are
/// synchronous within the actor: a completed discard cannot be overtaken by an
/// older save. A second advisory lock serializes quota checks across instances.
/// Atomic replacement and fsync protect completed snapshots against process
/// interruption; this is not a guarantee against power or filesystem failure.
public actor DraftRecoveryStore {
    public nonisolated let instanceID: UUID
    private let directory: RecoveryFileDescriptor
    private let instanceDirectory: RecoveryFileDescriptor
    private let limits: DraftRecoveryLimits
    private let rootLock: RecoveryFileDescriptor
    private let instanceLock: RecoveryFileDescriptor
    private var generations: [UUID: UInt64] = [:]
    private var isClosed = false

    public init(directory: URL, limits: DraftRecoveryLimits = .init()) throws {
        guard limits.maximumSnapshotBytes > 0, limits.maximumSnapshotBytes < Int.max,
              limits.maximumTotalBytes >= limits.maximumSnapshotBytes,
              limits.maximumDraftCount > 0, limits.maximumDirectoryEntries > limits.maximumDraftCount else {
            throw DraftRecoveryError.invalidConfiguration
        }
        let root = try RecoveryFiles.openPrivateDirectory(directory)
        let rootLock = try RecoveryFiles.openLock(".store.lock", in: root, create: true)
        let id = UUID()
        let (child, lock) = try RecoveryFiles.withLock(rootLock) {
            let names = try RecoveryFiles.entries(root, limit: limits.maximumDirectoryEntries)
            guard names.count < limits.maximumDirectoryEntries else { throw DraftRecoveryError.directoryEntryLimit }
            let child = try RecoveryFiles.createPrivateDirectory(id.uuidString, in: root)
            let lock = try RecoveryFiles.openLock(".lock", in: child, create: true)
            guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else { throw DraftRecoveryError.instanceActive }
            return (child, lock)
        }
        self.directory = root; self.instanceID = id; self.instanceDirectory = child
        self.limits = limits; self.rootLock = rootLock; self.instanceLock = lock
    }

    /// Generations must increase for each new save/discard decision. Failed
    /// saves do not consume a generation; an equal-generation retry is allowed.
    public func save(_ snapshot: DraftRecoverySnapshot) throws {
        try requireOpen()
        if let latest = generations[snapshot.documentID], snapshot.generation <= latest {
            throw DraftRecoveryError.staleGeneration
        }
        try Self.validate(snapshot)
        // Reject large text before allocating its encoded container.
        guard snapshot.text.utf8.count <= limits.maximumSnapshotBytes else { throw DraftRecoveryError.snapshotLimit }
        let data = try Self.encode(snapshot)
        guard data.count <= limits.maximumSnapshotBytes else { throw DraftRecoveryError.snapshotLimit }
        let destination = snapshotName(snapshot.documentID)
        try RecoveryFiles.withLock(rootLock) {
            try requireCurrentInstance()
            let inventory = try inventory()
            // Include staging space: the old snapshot remains until replacement.
            guard inventory.bytes <= limits.maximumTotalBytes - data.count else { throw DraftRecoveryError.totalLimit }
            let exists = try RecoveryFiles.regularInfo(destination, in: instanceDirectory, missingAllowed: true) != nil
            guard inventory.count + (exists ? 0 : 1) <= limits.maximumDraftCount else { throw DraftRecoveryError.draftCountLimit }
            // A staging entry exists alongside the previous final name.
            guard inventory.entries < limits.maximumDirectoryEntries else { throw DraftRecoveryError.directoryEntryLimit }
            try RecoveryFiles.atomicWrite(data, to: destination, in: instanceDirectory)
        }
        generations[snapshot.documentID] = snapshot.generation
    }

    /// Call only when the close/reload/save decision has actually succeeded.
    public func discard(documentID: UUID, throughGeneration generation: UInt64) throws {
        try requireOpen()
        if let latest = generations[documentID], generation < latest { throw DraftRecoveryError.staleGeneration }
        try RecoveryFiles.withLock(rootLock) {
            try requireCurrentInstance()
            try RecoveryFiles.removeRegular(snapshotName(documentID), in: instanceDirectory, missingAllowed: true)
        }
        generations[documentID] = generation
    }

    /// Active instances are skipped. Invalid snapshots are reported individually
    /// and left untouched, so one damaged file does not erase other drafts.
    public func scan() throws -> DraftRecoveryScan {
        try requireOpen()
        return try RecoveryFiles.withLock(rootLock) {
            var drafts = [RecoveredDraft](), issues = [DraftRecoveryIssue]()
            try requireCurrentInstance()
            let rootNames = try RecoveryFiles.entries(directory, limit: limits.maximumDirectoryEntries)
            var active = 0, bytesRead = 0, entriesRead = rootNames.count
            for (id, name) in instanceFolders(rootNames) where id != instanceID {
                do {
                    let folder = try RecoveryFiles.childDirectory(name, in: directory)
                    let lock = try RecoveryFiles.openLock(".lock", in: folder, create: false)
                    guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else {
                        if errno == EWOULDBLOCK { active += 1; continue }
                        throw RecoveryFiles.io("lock instance")
                    }
                    defer { _ = flock(lock.value, LOCK_UN) }
                    let names = try RecoveryFiles.entries(folder, limit: limits.maximumDirectoryEntries - entriesRead)
                    entriesRead += names.count
                    for name in names where name.hasSuffix(".draft") {
                        guard let documentID = UUID(uuidString: String(name.dropLast(6))),
                              snapshotName(documentID) == name else {
                            issues.append(.init(instanceID: id, documentID: nil, error: .invalidSnapshot)); continue
                        }
                        do {
                            let size = Int(try RecoveryFiles.regularInfo(name, in: folder, missingAllowed: false)!.st_size)
                            guard size <= limits.maximumSnapshotBytes else { throw DraftRecoveryError.snapshotLimit }
                            guard size <= limits.maximumTotalBytes - bytesRead else { throw DraftRecoveryError.totalLimit }
                            guard drafts.count < limits.maximumDraftCount else { throw DraftRecoveryError.draftCountLimit }
                            let remaining = limits.maximumTotalBytes - bytesRead
                            let read = try RecoveryFiles.read(name, in: folder, limit: min(limits.maximumSnapshotBytes, remaining))
                            bytesRead += read.data.count
                            let decoded = try Self.decode(read.data)
                            guard decoded.snapshot.documentID == documentID else { throw DraftRecoveryError.invalidSnapshot }
                            drafts.append(RecoveredDraft(reference: .init(instanceID: id, documentID: documentID,
                                generation: decoded.snapshot.generation, checksum: decoded.checksum), snapshot: decoded.snapshot))
                        } catch { issues.append(.init(instanceID: id, documentID: documentID, error: Self.failure(error))) }
                    }
                    if names.allSatisfy({ $0 == ".lock" }) {
                        try RecoveryFiles.removeRegular(".lock", in: folder, missingAllowed: false)
                        guard unlinkat(directory.value, name, AT_REMOVEDIR) == 0 else { throw RecoveryFiles.io("remove empty instance") }
                        try RecoveryFiles.sync(directory, operation: "sync instance cleanup")
                    }
                } catch {
                    issues.append(.init(instanceID: id, documentID: nil, error: Self.failure(error)))
                    if error as? DraftRecoveryError == .directoryEntryLimit { break }
                }
            }
            return DraftRecoveryScan(drafts: drafts, issues: issues, activeInstanceCount: active)
        }
    }

    /// Persist an adopted draft in this instance before discarding its old
    /// reference. Deletion requires the exact generation and checksum scanned.
    public func discardRecovered(_ reference: DraftRecoveryReference) throws {
        try requireOpen()
        guard reference.instanceID != instanceID else { throw DraftRecoveryError.instanceActive }
        try RecoveryFiles.withLock(rootLock) {
            try requireCurrentInstance()
            let folder = try RecoveryFiles.childDirectory(reference.instanceID.uuidString, in: directory)
            let lock = try RecoveryFiles.openLock(".lock", in: folder, create: false)
            guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else { throw DraftRecoveryError.instanceActive }
            defer { _ = flock(lock.value, LOCK_UN) }
            let name = snapshotName(reference.documentID)
            let read = try RecoveryFiles.read(name, in: folder, limit: limits.maximumSnapshotBytes)
            let decoded = try Self.decode(read.data)
            guard decoded.snapshot.documentID == reference.documentID,
                  decoded.snapshot.generation == reference.generation, decoded.checksum == reference.checksum else {
                throw DraftRecoveryError.changedRecovery
            }
            try RecoveryFiles.removeRegular(name, in: folder, missingAllowed: false, expected: read.info)
        }
    }

    /// Releases this instance for recovery. Calling close does not discard data.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        instanceLock.close()
        rootLock.close()
        instanceDirectory.close()
        directory.close()
    }

    private func requireOpen() throws { if isClosed { throw DraftRecoveryError.closed } }
    private func snapshotName(_ id: UUID) -> String { id.uuidString + ".draft" }

    private func requireCurrentInstance() throws {
        try RecoveryFiles.requirePrivateDirectory(directory)
        try RecoveryFiles.requirePrivateDirectory(instanceDirectory)
        try RecoveryFiles.requireIdentity(rootLock, name: ".store.lock", in: directory)
        try RecoveryFiles.requireIdentity(instanceLock, name: ".lock", in: instanceDirectory)
        let current = try RecoveryFiles.childDirectory(instanceID.uuidString, in: directory)
        guard try RecoveryFiles.sameIdentity(current, instanceDirectory) else { throw DraftRecoveryError.unsafePath }
    }

    private func instanceFolders(_ names: [String]) -> [(UUID, String)] {
        names.compactMap { name in
            guard let id = UUID(uuidString: name), id.uuidString == name else { return nil }
            return (id, name)
        }
    }

    private func inventory() throws -> (bytes: Int, count: Int, entries: Int) {
        let rootNames = try RecoveryFiles.entries(directory, limit: limits.maximumDirectoryEntries)
        var bytes = 0, count = 0, entries = rootNames.count
        func countFile(_ name: String, in folder: RecoveryFileDescriptor) throws {
            let size = Int(try RecoveryFiles.regularInfo(name, in: folder, missingAllowed: false)!.st_size)
            let sum = bytes.addingReportingOverflow(size)
            guard !sum.overflow else { throw DraftRecoveryError.totalLimit }
            bytes = sum.partialValue
        }
        let instances = instanceFolders(rootNames)
        let instanceNames = Set(instances.map(\.1))
        for name in rootNames where name != ".store.lock" && !instanceNames.contains(name) {
            try countFile(name, in: directory)
        }
        for (_, name) in instances {
            let folder = try RecoveryFiles.childDirectory(name, in: directory)
            let names = try RecoveryFiles.entries(folder, limit: limits.maximumDirectoryEntries - entries)
            entries += names.count
            guard try RecoveryFiles.regularInfo(".lock", in: folder, missingAllowed: false)!.st_size == 0 else {
                throw DraftRecoveryError.unsafePath
            }
            for name in names where name != ".lock" {
                try countFile(name, in: folder)
                if name.hasSuffix(".draft") { count += 1 }
            }
        }
        return (bytes, count, entries)
    }

    private struct Payload: Codable {
        let documentID: UUID, generation: UInt64, text: String, originPath: String?, encodingHint: String?
        let selection: DraftRecoverySelection, updatedAt: Date
        init(_ snapshot: DraftRecoverySnapshot) {
            documentID = snapshot.documentID; generation = snapshot.generation; text = snapshot.text
            originPath = snapshot.originPath; encodingHint = snapshot.encodingHint?.rawValue
            selection = snapshot.selection; updatedAt = snapshot.updatedAt
        }
        func snapshot() throws -> DraftRecoverySnapshot {
            if let encodingHint, TextFileEncoding(rawValue: encodingHint) == nil { throw DraftRecoveryError.invalidSnapshot }
            return .init(documentID: documentID, generation: generation, text: text, originPath: originPath,
                         encodingHint: encodingHint.flatMap(TextFileEncoding.init(rawValue:)), selection: selection, updatedAt: updatedAt)
        }
    }
    private struct Envelope: Codable { let version: Int, payload: Data, checksum: Data }
    private static func encode(_ snapshot: DraftRecoverySnapshot) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(Payload(snapshot))
        return try encoder.encode(Envelope(version: 1, payload: payload, checksum: Data(SHA256.hash(data: payload))))
    }
    private static func decode(_ data: Data) throws -> (snapshot: DraftRecoverySnapshot, checksum: Data) {
        let decoder = PropertyListDecoder()
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw DraftRecoveryError.invalidSnapshot }
        guard envelope.version == 1 else { throw DraftRecoveryError.unsupportedVersion }
        guard envelope.checksum == Data(SHA256.hash(data: envelope.payload)) else { throw DraftRecoveryError.checksumMismatch }
        let snapshot: DraftRecoverySnapshot
        do { snapshot = try decoder.decode(Payload.self, from: envelope.payload).snapshot() }
        catch let error as DraftRecoveryError { throw error }
        catch { throw DraftRecoveryError.invalidSnapshot }
        try validate(snapshot)
        return (snapshot, envelope.checksum)
    }
    private static func validate(_ snapshot: DraftRecoverySnapshot) throws {
        let count = snapshot.text.utf16.count, selection = snapshot.selection
        guard selection.location >= 0, selection.length >= 0, selection.location <= count,
              selection.length <= count - selection.location else { throw DraftRecoveryError.invalidSelection }
        for offset in [selection.location, selection.location + selection.length] where offset > 0 && offset < count {
            let index = snapshot.text.utf16.index(snapshot.text.utf16.startIndex, offsetBy: offset)
            let unit = snapshot.text.utf16[index]
            if (0xDC00...0xDFFF).contains(unit) { throw DraftRecoveryError.invalidSelection }
        }
        guard snapshot.updatedAt.timeIntervalSince1970.isFinite,
              snapshot.originPath?.utf8.count ?? 0 <= 16_384 else { throw DraftRecoveryError.invalidSnapshot }
    }
    private static func failure(_ error: Error) -> DraftRecoveryError { error as? DraftRecoveryError ?? .invalidSnapshot }
}

private final class RecoveryFileDescriptor: @unchecked Sendable {
    private(set) var value: Int32
    init(_ value: Int32) { self.value = value }
    func close() { if value >= 0 { _ = Darwin.close(value); value = -1 } }
    deinit { close() }
}

private enum RecoveryFiles {
    static func io(_ operation: String) -> DraftRecoveryError { .io(operation: operation, code: errno) }
    /// Walk from / with directory descriptors. Every component is opened with
    /// O_NOFOLLOW; later operations stay anchored to these opened directories.
    /// Existing ancestors may be shared, but the recovery root must be private.
    static func openPrivateDirectory(_ url: URL) throws -> RecoveryFileDescriptor {
        guard url.isFileURL, url.path != "/", url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0) else { throw DraftRecoveryError.unsafePath }
        let components = url.pathComponents.dropFirst()
        guard !components.contains(".."), !components.contains(".") else { throw DraftRecoveryError.unsafePath }
        let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw io("open filesystem root") }
        var parent = RecoveryFileDescriptor(fd)
        for name in components {
            var created = false
            var child = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0 && errno == ENOENT {
                if mkdirat(parent.value, name, 0o700) == 0 { created = true }
                else if errno != EEXIST { throw io("create directory") }
                child = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { throw DraftRecoveryError.unsafePath }
                throw io("open directory")
            }
            let next = RecoveryFileDescriptor(child)
            if created {
                guard fchmod(child, 0o700) == 0 else { throw io("protect directory") }
                try sync(parent, operation: "sync new directory")
            }
            parent = next
        }
        try requirePrivateDirectory(parent)
        return parent
    }
    static func createPrivateDirectory(_ name: String, in parent: RecoveryFileDescriptor) throws -> RecoveryFileDescriptor {
        guard mkdirat(parent.value, name, 0o700) == 0 else { throw io("create instance") }
        let child = try childDirectory(name, in: parent)
        try sync(parent, operation: "sync new instance")
        return child
    }
    static func childDirectory(_ name: String, in parent: RecoveryFileDescriptor) throws -> RecoveryFileDescriptor {
        let fd = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw DraftRecoveryError.unsafePath }
            throw io("open instance")
        }
        let child = RecoveryFileDescriptor(fd)
        try requirePrivateDirectory(child)
        return child
    }
    static func requirePrivateDirectory(_ directory: RecoveryFileDescriptor) throws {
        let info = try descriptorInfo(directory)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw DraftRecoveryError.unsafePath
        }
    }
    static func descriptorInfo(_ descriptor: RecoveryFileDescriptor) throws -> stat {
        var info = stat()
        guard fstat(descriptor.value, &info) == 0 else { throw io("inspect descriptor") }
        return info
    }
    static func sameIdentity(_ lhs: RecoveryFileDescriptor, _ rhs: RecoveryFileDescriptor) throws -> Bool {
        let first = try descriptorInfo(lhs), second = try descriptorInfo(rhs)
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
    static func requireIdentity(_ descriptor: RecoveryFileDescriptor, name: String, in directory: RecoveryFileDescriptor) throws {
        let opened = try descriptorInfo(descriptor)
        let named = try regularInfo(name, in: directory, missingAllowed: false)!
        guard opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, named.st_size == 0 else {
            throw DraftRecoveryError.unsafePath
        }
    }
    static func openLock(_ name: String, in directory: RecoveryFileDescriptor, create: Bool) throws -> RecoveryFileDescriptor {
        let existing = try regularInfo(name, in: directory, missingAllowed: create)
        let fd = openat(directory.value, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC |
                       (existing == nil ? O_CREAT | O_EXCL : 0), 0o600)
        guard fd >= 0 else {
            // Two first launches can race only on creating the root lock.
            if create && existing == nil && errno == EEXIST { return try openLock(name, in: directory, create: false) }
            if errno == ELOOP { throw DraftRecoveryError.unsafePath }
            throw io("open lock")
        }
        let handle = RecoveryFileDescriptor(fd)
        if existing == nil {
            guard fchmod(fd, 0o600) == 0 else { throw io("protect lock") }
            try sync(directory, operation: "sync new lock")
        }
        try requireRegular(try descriptorInfo(handle))
        try requireIdentity(handle, name: name, in: directory)
        return handle
    }
    static func withLock<T>(_ lock: RecoveryFileDescriptor, _ body: () throws -> T) throws -> T {
        guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw DraftRecoveryError.storeBusy }
            throw io("lock store")
        }
        defer { _ = flock(lock.value, LOCK_UN) }
        return try body()
    }
    static func entries(_ directory: RecoveryFileDescriptor, limit: Int) throws -> [String] {
        // openat(".") gives each enumeration its own offset. dup() would share
        // an offset with the held directory descriptor and future enumerations.
        let fd = openat(directory.value, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw io("open directory listing") }
        guard let stream = fdopendir(fd) else { _ = Darwin.close(fd); throw io("list directory") }
        defer { closedir(stream) }
        var values = [String]()
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw io("read directory entry") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw DraftRecoveryError.unsafePath }
            if name == "." || name == ".." { continue }
            guard values.count < limit else { throw DraftRecoveryError.directoryEntryLimit }
            values.append(name)
        }
        return values.sorted()
    }
    static func requireRegular(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_size >= 0, info.st_size <= Int.max else {
            throw DraftRecoveryError.unsafePath
        }
    }
    static func regularInfo(_ name: String, in directory: RecoveryFileDescriptor, missingAllowed: Bool) throws -> stat? {
        var info = stat()
        guard fstatat(directory.value, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if missingAllowed && errno == ENOENT { return nil }
            throw io("inspect snapshot")
        }
        try requireRegular(info)
        return info
    }
    static func read(_ name: String, in directory: RecoveryFileDescriptor, limit: Int) throws -> (data: Data, info: stat) {
        _ = try regularInfo(name, in: directory, missingAllowed: false)
        let fd = openat(directory.value, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw DraftRecoveryError.unsafePath }
            throw io("open snapshot")
        }
        let descriptor = RecoveryFileDescriptor(fd)
        let info = try descriptorInfo(descriptor)
        try requireRegular(info)
        guard info.st_size >= 0, info.st_size <= limit else { throw DraftRecoveryError.snapshotLimit }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, min($0.count, limit + 1 - data.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw io("read snapshot") }
            if count == 0 { break }
            data.append(contentsOf: chunk.prefix(count))
            guard data.count <= limit else { throw DraftRecoveryError.snapshotLimit }
        }
        guard unchanged(info, try descriptorInfo(descriptor)), data.count == info.st_size else {
            throw DraftRecoveryError.changedRecovery
        }
        return (data, info)
    }
    static func atomicWrite(_ data: Data, to destination: String, in directory: RecoveryFileDescriptor) throws {
        _ = try regularInfo(destination, in: directory, missingAllowed: true)
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(directory.value, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw io("create snapshot") }
        let descriptor = RecoveryFileDescriptor(fd)
        defer { _ = unlinkat(directory.value, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw io("protect snapshot") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw io("write snapshot") }
                offset += count
            }
        }
        try sync(descriptor, operation: "sync snapshot")
        _ = try regularInfo(destination, in: directory, missingAllowed: true)
        guard renameat(directory.value, temporary, directory.value, destination) == 0 else { throw io("replace snapshot") }
        try sync(directory, operation: "sync snapshot replacement")
    }
    static func removeRegular(_ name: String, in directory: RecoveryFileDescriptor,
                              missingAllowed: Bool, expected: stat? = nil) throws {
        guard let current = try regularInfo(name, in: directory, missingAllowed: missingAllowed) else { return }
        if let expected, !unchanged(expected, current) { throw DraftRecoveryError.changedRecovery }
        guard unlinkat(directory.value, name, 0) == 0 else { throw io("remove snapshot") }
        try sync(directory, operation: "sync snapshot removal")
    }
    static func unchanged(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    static func sync(_ descriptor: RecoveryFileDescriptor, operation: String) throws {
        while fsync(descriptor.value) != 0 { if errno != EINTR { throw io(operation) } }
    }
}
