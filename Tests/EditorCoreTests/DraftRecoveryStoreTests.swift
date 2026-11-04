import Darwin
import Foundation
import XCTest
@testable import EditorCore

final class DraftRecoveryStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        if let childRoot = ProcessInfo.processInfo.environment["FOLIVYN_RECOVERY_PROCESS_ROOT"] {
            directory = URL(fileURLWithPath: childRoot).deletingLastPathComponent()
                .appendingPathComponent("ChildTestFixture", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return
        }
        // Foundation may preserve the /var alias even after resolving symlinks
        // on macOS. The store deliberately rejects symlinks in every component.
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("DraftRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var root: URL { directory.appendingPathComponent("Recovery", isDirectory: true) }
    private func path(_ store: DraftRecoveryStore, documentID: UUID) -> URL {
        root.appendingPathComponent(store.instanceID.uuidString).appendingPathComponent(documentID.uuidString + ".draft")
    }
    private func assertError(_ expected: DraftRecoveryError, _ action: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? DraftRecoveryError, expected, file: file, line: line) }
    }

    func testExactUnicodeLineEndingsAndHintsRoundTripWithoutTouchingOrigin() async throws {
        let origin = directory.appendingPathComponent("原始.txt")
        let originalBytes = Data("disk stays unchanged\r\n".utf8)
        try originalBytes.write(to: origin)
        let text = "e\u{301} / é / 中文 🦊\r\nnext\n\r\u{0000}"
        let snapshot = DraftRecoverySnapshot(documentID: UUID(), generation: 9, text: text,
            originPath: origin.path, encodingHint: .utf16BigEndianBOM,
            selection: .init(location: 3, length: 6), updatedAt: Date(timeIntervalSince1970: 123456))
        let writer = try DraftRecoveryStore(directory: root)
        try await writer.save(snapshot)
        let reader = try DraftRecoveryStore(directory: root)
        let active = try await reader.scan()
        XCTAssertTrue(active.drafts.isEmpty)
        XCTAssertEqual(active.activeInstanceCount, 1)
        await writer.close()
        let recovered = try await reader.scan()
        let result = try XCTUnwrap(recovered.drafts.first)
        XCTAssertTrue(recovered.issues.isEmpty)
        XCTAssertEqual(Array(result.snapshot.text.utf16), Array(text.utf16), "No Unicode normalization or newline conversion")
        XCTAssertEqual(result.snapshot, snapshot)
        XCTAssertEqual(try Data(contentsOf: origin), originalBytes)
        XCTAssertEqual(result.reference.instanceID, writer.instanceID)
        await reader.close()
    }

    func testDiscardTombstoneRejectsLateSaveAndDoesNotDeleteNewerGeneration() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "first"))
        try await store.save(.init(documentID: id, generation: 3, text: "third"))
        await assertError(.staleGeneration) { try await store.discard(documentID: id, throughGeneration: 2) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(store, documentID: id).path))
        try await store.discard(documentID: id, throughGeneration: 4)
        await assertError(.staleGeneration) { try await store.save(.init(documentID: id, generation: 3, text: "late")) }
        await assertError(.staleGeneration) { try await store.save(.init(documentID: id, generation: 4, text: "same decision")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(store, documentID: id).path))
        try await store.save(.init(documentID: id, generation: 5, text: "new edit"))
        await store.close()
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertEqual(scan.drafts.map(\.snapshot.text), ["new edit"])
        await reader.close()
    }

    func testPrivatePermissionsAndAtomicReplacementLeaveOneCompleteSnapshot() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "old"))
        try await store.save(.init(documentID: id, generation: 2, text: "new\r\n🦊"))
        for folder in [root, root.appendingPathComponent(store.instanceID.uuidString)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: folder.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path(store, documentID: id).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(store.instanceID.uuidString).path)
        XCTAssertEqual(Set(names), Set([".lock", id.uuidString + ".draft"]))
        await store.close()
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertEqual(scan.drafts.map(\.snapshot.text), ["new\r\n🦊"])
        await reader.close()
    }

    func testSnapshotAndTotalLimitsPreservePreviousDataAndAllowRetry() async throws {
        let limits = DraftRecoveryLimits(maximumSnapshotBytes: 2_048, maximumTotalBytes: 2_800)
        let store = try DraftRecoveryStore(directory: root, limits: limits)
        let first = UUID(), second = UUID()
        try await store.save(.init(documentID: first, generation: 1, text: String(repeating: "a", count: 1_000)))
        let before = try Data(contentsOf: path(store, documentID: first))
        await assertError(.snapshotLimit) {
            try await store.save(.init(documentID: first, generation: 2, text: String(repeating: "b", count: 3_000)))
        }
        XCTAssertEqual(try Data(contentsOf: path(store, documentID: first)), before)
        await assertError(.totalLimit) {
            try await store.save(.init(documentID: second, generation: 1, text: String(repeating: "c", count: 1_400)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(store, documentID: second).path))
        try await store.save(.init(documentID: first, generation: 2, text: "small retry"))
        await store.close()
    }

    func testDraftCountQuotaIncludesOtherActiveInstances() async throws {
        let limits = DraftRecoveryLimits(maximumDraftCount: 1)
        let first = try DraftRecoveryStore(directory: root, limits: limits)
        let second = try DraftRecoveryStore(directory: root, limits: limits)
        let id = UUID()
        try await first.save(.init(documentID: id, generation: 1, text: "active"))
        await assertError(.draftCountLimit) { try await second.save(.init(documentID: UUID(), generation: 1, text: "other")) }
        try await first.discard(documentID: id, throughGeneration: 2)
        try await second.save(.init(documentID: UUID(), generation: 1, text: "now fits"))
        await first.close(); await second.close()
    }

    func testChecksumAndVersionErrorsDoNotHideValidDraftsOrDeleteCorruptData() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let valid = UUID(), corrupt = UUID(), future = UUID()
        for id in [valid, corrupt, future] { try await store.save(.init(documentID: id, generation: 1, text: "keep \(id)")) }
        await store.close()
        for (id, key, value) in [(corrupt, "checksum", Data(repeating: 0, count: 32) as Any), (future, "version", 99 as Any)] {
            let url = path(store, documentID: id)
            var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            plist[key] = value
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        }
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertEqual(scan.drafts.map(\.snapshot.documentID), [valid])
        XCTAssertTrue(scan.issues.contains { $0.documentID == corrupt && $0.error == .checksumMismatch })
        XCTAssertTrue(scan.issues.contains { $0.documentID == future && $0.error == .unsupportedVersion })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(store, documentID: corrupt).path))
        await reader.close()
    }

    func testSymlinkFIFOAndHardlinkSnapshotsAreRejectedWithoutFollowingThem() async throws {
        let target = directory.appendingPathComponent("outside")
        let bytes = Data("never overwrite this".utf8)
        try bytes.write(to: target)
        let store = try DraftRecoveryStore(directory: root)
        let linked = UUID(), fifo = UUID(), hardlinked = UUID()
        try FileManager.default.createSymbolicLink(at: path(store, documentID: linked), withDestinationURL: target)
        XCTAssertEqual(mkfifo(path(store, documentID: fifo).path, 0o600), 0)
        try FileManager.default.linkItem(at: target, to: path(store, documentID: hardlinked))
        await assertError(.unsafePath) { try await store.save(.init(documentID: linked, generation: 1, text: "wrong")) }
        await assertError(.unsafePath) { try await store.discard(documentID: linked, throughGeneration: 1) }
        await store.close()
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertTrue(scan.drafts.isEmpty)
        XCTAssertEqual(scan.issues.count, 3)
        XCTAssertTrue(scan.issues.allSatisfy { $0.error == .unsafePath })
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        await reader.close()
    }

    func testRootAndInstanceSymlinksAreRejected() async throws {
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        XCTAssertThrowsError(try DraftRecoveryStore(directory: root)) { XCTAssertEqual($0 as? DraftRecoveryError, .unsafePath) }
        try FileManager.default.removeItem(at: root)
        let store = try DraftRecoveryStore(directory: root)
        let fakeInstance = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(fakeInstance.uuidString), withDestinationURL: target)
        let scan = try await store.scan()
        XCTAssertTrue(scan.issues.contains { $0.instanceID == fakeInstance && $0.error == .unsafePath })
        await store.close()
    }

    func testDiscardRecoveredRevalidatesReferenceAndNeverTouchesOrigin() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 4, text: "restore me", originPath: "/does/not/exist"))
        await store.close()
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        let recovered = try XCTUnwrap(scan.drafts.first)
        let wrong = DraftRecoveryReference(instanceID: recovered.reference.instanceID, documentID: id,
            generation: 3, checksum: recovered.reference.checksum)
        await assertError(.changedRecovery) { try await reader.discardRecovered(wrong) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(store, documentID: id).path))
        // Adopt first. A crash between these two operations may duplicate a draft,
        // but cannot lose the only persisted copy.
        try await reader.save(recovered.snapshot)
        try await reader.discardRecovered(recovered.reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(store, documentID: id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(reader, documentID: id).path))
        await reader.close()
    }

    func testInvalidSelectionEmptyDraftAndClosedStore() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        await assertError(.invalidSelection) {
            try await store.save(.init(documentID: id, generation: 1, text: "🦊", selection: .init(location: 2, length: Int.max)))
        }
        try await store.save(.init(documentID: id, generation: 1, text: ""))
        await store.close()
        await assertError(.closed) { try await store.save(.init(documentID: UUID(), generation: 1, text: "late")) }
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertEqual(scan.drafts.map(\.snapshot.text), [""])
        await reader.close()
    }

    func testConcurrentOlderSavesCannotResurrectDiscardedDocument() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "first"))
        let oldSaves = (2...12).map { generation in Task {
            try? await store.save(.init(documentID: id, generation: UInt64(generation), text: "older \(generation)"))
        } }
        try await store.discard(documentID: id, throughGeneration: 20)
        for task in oldSaves { await task.value }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(store, documentID: id).path))
        await store.close()
    }

    func testSnapshotEqualityUsesExactUTF16AndSelectionsCannotSplitSurrogates() async throws {
        let id = UUID(), date = Date(timeIntervalSince1970: 123)
        let first = DraftRecoverySnapshot(documentID: id, generation: 1, text: "é", updatedAt: date)
        let second = DraftRecoverySnapshot(documentID: id, generation: 1, text: "e\u{301}", updatedAt: date)
        XCTAssertEqual(first.text, second.text, "Swift canonical equality is broader than source equality")
        XCTAssertNotEqual(first, second)
        let store = try DraftRecoveryStore(directory: root)
        for selection in [DraftRecoverySelection(location: 1), .init(location: 0, length: 1)] {
            await assertError(.invalidSelection) {
                try await store.save(.init(documentID: id, generation: 1, text: "🦊", selection: selection))
            }
        }
        try await store.save(.init(documentID: id, generation: 1, text: "🦊", selection: .init(location: 0, length: 2)))
        await store.close()
    }

    func testInsecureExistingRootAndSnapshotPermissionsAreRejectedWithoutChangingThem() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try DraftRecoveryStore(directory: root)) {
            XCTAssertEqual($0 as? DraftRecoveryError, .unsafePath)
        }
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((rootAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let store = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "private draft"))
        let before = try Data(contentsOf: path(store, documentID: id))
        XCTAssertEqual(chmod(path(store, documentID: id).path, 0o644), 0)
        await assertError(.unsafePath) { try await store.save(.init(documentID: id, generation: 2, text: "must not replace")) }
        await store.close()
        let reader = try DraftRecoveryStore(directory: root)
        let scan = try await reader.scan()
        XCTAssertTrue(scan.drafts.isEmpty)
        XCTAssertTrue(scan.issues.contains { $0.documentID == id && $0.error == .unsafePath })
        XCTAssertEqual(try Data(contentsOf: path(store, documentID: id)), before)
        await reader.close()
    }

    func testRootReplacementCannotRedirectDescriptorRelativeWritesThroughSymlink() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let originalRoot = directory.appendingPathComponent("OriginalRecovery", isDirectory: true)
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: root, to: originalRoot)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "anchored to the opened directory"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalRoot.appendingPathComponent(store.instanceID.uuidString)
            .appendingPathComponent(id.uuidString + ".draft").path))
        XCTAssertThrowsError(try DraftRecoveryStore(directory: root)) {
            XCTAssertEqual($0 as? DraftRecoveryError, .unsafePath)
        }
        await store.close()
    }

    func testReplacedInstanceDirectoryAndLockAreRejected() async throws {
        let store = try DraftRecoveryStore(directory: root)
        let instance = root.appendingPathComponent(store.instanceID.uuidString)
        let moved = root.appendingPathComponent("moved-instance")
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: instance, to: moved)
        try FileManager.default.createSymbolicLink(at: instance, withDestinationURL: outside)
        await assertError(.unsafePath) { try await store.save(.init(documentID: UUID(), generation: 1, text: "not outside")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: instance)
        try FileManager.default.moveItem(at: moved, to: instance)
        let lock = instance.appendingPathComponent(".lock")
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock)
        XCTAssertEqual(chmod(lock.path, 0o600), 0)
        await assertError(.unsafePath) { try await store.discard(documentID: UUID(), throughGeneration: 1) }
        await store.close()
    }

    func testSymlinkParentAndNonregularLocksAreRejectedWithoutFollowingThem() async throws {
        let realParent = directory.appendingPathComponent("real", isDirectory: true)
        let linkedParent = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        XCTAssertThrowsError(try DraftRecoveryStore(directory: linkedParent.appendingPathComponent("Recovery"))) {
            XCTAssertEqual($0 as? DraftRecoveryError, .unsafePath)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: realParent.path).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lock = root.appendingPathComponent(".store.lock")
        XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
        XCTAssertThrowsError(try DraftRecoveryStore(directory: root)) {
            XCTAssertEqual($0 as? DraftRecoveryError, .unsafePath)
        }
    }

    func testQuotaIncludesUnknownPrivateFilesAndCrashedTemporaryWrites() async throws {
        let limits = DraftRecoveryLimits(maximumSnapshotBytes: 2_048, maximumTotalBytes: 2_800)
        let store = try DraftRecoveryStore(directory: root, limits: limits)
        for location in [root, root.appendingPathComponent(store.instanceID.uuidString)] {
            let temporary = location.appendingPathComponent("abandoned.tmp")
            try Data(repeating: 0, count: 2_700).write(to: temporary)
            XCTAssertEqual(chmod(temporary.path, 0o600), 0)
            await assertError(.totalLimit) { try await store.save(.init(documentID: UUID(), generation: 1, text: "quota")) }
            XCTAssertEqual(try Data(contentsOf: temporary).count, 2_700, "Unknown data is counted, not deleted")
            try FileManager.default.removeItem(at: temporary)
        }
        try await store.save(.init(documentID: UUID(), generation: 1, text: "fits after cleanup"))
        await store.close()
    }

    func testDirectoryEntryQuotaIncludesNestedFilesAndReservesStagingSpace() async throws {
        let limits = DraftRecoveryLimits(maximumDraftCount: 2, maximumDirectoryEntries: 5)
        let store = try DraftRecoveryStore(directory: root, limits: limits)
        let id = UUID()
        try await store.save(.init(documentID: id, generation: 1, text: "initial"))
        // Root lock + instance directory + instance lock + snapshot = four.
        // A replacement temporarily needs a fifth entry and must still fit.
        try await store.save(.init(documentID: id, generation: 2, text: "replacement"))
        let extra = root.appendingPathComponent(store.instanceID.uuidString).appendingPathComponent("abandoned.tmp")
        try Data().write(to: extra)
        XCTAssertEqual(chmod(extra.path, 0o600), 0)
        let before = try Data(contentsOf: path(store, documentID: id))
        await assertError(.directoryEntryLimit) { try await store.save(.init(documentID: id, generation: 3, text: "too many entries")) }
        XCTAssertEqual(try Data(contentsOf: path(store, documentID: id)), before)
        await store.close()
    }

    func testOnlyInactiveEmptyInstancesAreCleaned() async throws {
        let writer = try DraftRecoveryStore(directory: root)
        let reader = try DraftRecoveryStore(directory: root)
        let oldFolder = root.appendingPathComponent(writer.instanceID.uuidString)
        let active = try await reader.scan()
        XCTAssertEqual(active.activeInstanceCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFolder.path))
        await writer.close()
        let cleaned = try await reader.scan()
        XCTAssertTrue(cleaned.drafts.isEmpty)
        XCTAssertTrue(cleaned.issues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
        await reader.close()
    }

    func testChangedValidRecoveredPayloadCannotBeDiscardedUsingOldReference() async throws {
        let writer = try DraftRecoveryStore(directory: root)
        let id = UUID()
        try await writer.save(.init(documentID: id, generation: 1, text: "old"))
        await writer.close()
        let reader = try DraftRecoveryStore(directory: root)
        let initialScan = try await reader.scan()
        let recovered = try XCTUnwrap(initialScan.drafts.first)
        let replacement = try DraftRecoveryStore(directory: directory.appendingPathComponent("OtherRecovery"))
        try await replacement.save(.init(documentID: id, generation: 2, text: "new version"))
        let replacementURL = directory.appendingPathComponent("OtherRecovery").appendingPathComponent(replacement.instanceID.uuidString)
            .appendingPathComponent(id.uuidString + ".draft")
        let changedData = try Data(contentsOf: replacementURL)
        try changedData.write(to: path(writer, documentID: id))
        await assertError(.changedRecovery) { try await reader.discardRecovered(recovered.reference) }
        XCTAssertEqual(try Data(contentsOf: path(writer, documentID: id)), changedData)
        await replacement.close(); await reader.close()
    }

    func testOtherProcessIsSkippedUntilForcedTermination() async throws {
        try await verifyProcessRecovery(interruptWrite: false)
    }

    func testTerminationWhileWritingLeavesACompleteRecoverableGeneration() async throws {
        try await verifyProcessRecovery(interruptWrite: true)
    }

    private func verifyProcessRecovery(interruptWrite: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let text = "unsaved e\u{301} 🦊\r\n"
        func textForGeneration(_ generation: UInt64) -> String {
            generation == 7 ? text : "generation \(generation)\n" + String(repeating: "snapshot line\r\n", count: 65_536)
        }
        if let childRoot = environment["FOLIVYN_RECOVERY_PROCESS_ROOT"] {
            let store = try DraftRecoveryStore(directory: URL(fileURLWithPath: childRoot))
            let id = try XCTUnwrap(environment["FOLIVYN_RECOVERY_PROCESS_DOCUMENT"].flatMap(UUID.init(uuidString:)))
            try await store.save(.init(documentID: id, generation: 7, text: text,
                originPath: environment["FOLIVYN_RECOVERY_PROCESS_ORIGIN"], encodingHint: .utf16LittleEndianBOM))
            let ready = try XCTUnwrap(environment["FOLIVYN_RECOVERY_PROCESS_READY"])
            try Data(store.instanceID.uuidString.utf8).write(to: URL(fileURLWithPath: ready), options: .atomic)
            // Parent forcibly terminates this process. The deadline prevents a
            // stranded child if the parent test runner itself is interrupted.
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let command = environment["FOLIVYN_RECOVERY_PROCESS_WRITE"], FileManager.default.fileExists(atPath: command) {
                    for generation in UInt64(8)...500 {
                        try await store.save(.init(documentID: id, generation: generation, text: textForGeneration(generation),
                            originPath: environment["FOLIVYN_RECOVERY_PROCESS_ORIGIN"], encodingHint: .utf16LittleEndianBOM))
                    }
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            await store.close()
            return
        }

        let id = UUID()
        let ready = directory.appendingPathComponent("child-ready")
        let writeCommand = directory.appendingPathComponent("child-write")
        let origin = directory.appendingPathComponent("origin.txt")
        let newerDiskBytes = Data("a newer disk version\n".utf8)
        try newerDiskBytes.write(to: origin)
        let output = directory.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        let child = Process()
        let terminated = expectation(description: "Recovery child terminated")
        child.terminationHandler = { _ in terminated.fulfill() }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "EditorCoreTests.DraftRecoveryStoreTests/testOtherProcessIsSkippedUntilForcedTermination",
                           Bundle(for: DraftRecoveryStoreTests.self).bundlePath]
        var childEnvironment = environment
        childEnvironment["FOLIVYN_RECOVERY_PROCESS_ROOT"] = root.path
        childEnvironment["FOLIVYN_RECOVERY_PROCESS_DOCUMENT"] = id.uuidString
        childEnvironment["FOLIVYN_RECOVERY_PROCESS_ORIGIN"] = origin.path
        childEnvironment["FOLIVYN_RECOVERY_PROCESS_READY"] = ready.path
        if interruptWrite { childEnvironment["FOLIVYN_RECOVERY_PROCESS_WRITE"] = writeCommand.path }
        child.environment = childEnvironment
        child.standardOutput = log; child.standardError = log
        try child.run()
        defer { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard child.isRunning, let value = try? String(contentsOf: ready, encoding: .utf8), let instanceID = UUID(uuidString: value) else {
            XCTFail("Child did not persist its snapshot: \((try? String(contentsOf: output, encoding: .utf8)) ?? "no log")")
            return
        }
        let reader = try DraftRecoveryStore(directory: root)
        let active = try await reader.scan()
        XCTAssertEqual(active.activeInstanceCount, 1)
        XCTAssertTrue(active.drafts.isEmpty)
        let activeReference = DraftRecoveryReference(instanceID: instanceID, documentID: id, generation: 7,
                                                    checksum: Data(repeating: 0, count: 32))
        await assertError(.instanceActive) { try await reader.discardRecovered(activeReference) }
        if interruptWrite {
            try Data().write(to: writeCommand)
            let folder = root.appendingPathComponent(instanceID.uuidString)
            let writeDeadline = ProcessInfo.processInfo.systemUptime + 8
            var observedStagingFile = false
            while child.isRunning && ProcessInfo.processInfo.systemUptime < writeDeadline {
                if try FileManager.default.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasSuffix(".tmp") }) {
                    observedStagingFile = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(observedStagingFile, "The test must observe an actual staged write before interrupting the process")
        }
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        await fulfillment(of: [terminated], timeout: 5)
        guard !child.isRunning else { XCTFail("Child did not exit after SIGKILL"); return }
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        let recovered = try await reader.scan()
        XCTAssertTrue(recovered.issues.isEmpty)
        XCTAssertEqual(recovered.activeInstanceCount, 0)
        let draft = try XCTUnwrap(recovered.drafts.first)
        XCTAssertEqual(draft.snapshot.documentID, id)
        if interruptWrite { XCTAssertTrue((7...500).contains(draft.snapshot.generation)) }
        else { XCTAssertEqual(draft.snapshot.generation, 7) }
        XCTAssertTrue(draft.snapshot.text.utf16.elementsEqual(textForGeneration(draft.snapshot.generation).utf16),
                      "Recovery must contain one entire committed generation, never a partially written replacement")
        XCTAssertEqual(draft.snapshot.originPath, origin.path)
        XCTAssertEqual(draft.snapshot.encodingHint, .utf16LittleEndianBOM)
        XCTAssertEqual(try Data(contentsOf: origin), newerDiskBytes)
        await reader.close()
    }
}
