import Darwin
import Foundation
import XCTest
@testable import EditorCore

final class NewDocumentSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolivynNewSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testCompetingFileAfterValidationIsNotReplaced() throws {
        let target = directory.appendingPathComponent("new.txt")
        let other = Data("another writer 中文 🦊\r\n".utf8)
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: target, encoding: .utf8,
                                                  beforeNewFilePublish: {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try other.write(to: target)
        })) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(target))
        }
        XCTAssertEqual(try Data(contentsOf: target), other)
        XCTAssertEqual(try entries(), ["new.txt"])
    }

    func testCompetingSymlinkAfterValidationIsNotFollowedOrReplaced() throws {
        let target = directory.appendingPathComponent("new.txt")
        let other = directory.appendingPathComponent("other.txt")
        let original = Data("keep other".utf8)
        try original.write(to: other)
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: target, encoding: .utf8,
                                                  beforeNewFilePublish: {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        })) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(target))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), other.path)
        XCTAssertEqual(try Data(contentsOf: other), original)
        XCTAssertEqual(try entries(), ["new.txt", "other.txt"])
    }

    func testCompetingDirectoryAfterValidationIsPreserved() throws {
        let target = directory.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: target, encoding: .utf8,
                                                  beforeNewFilePublish: {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("keep child".utf8).write(to: target.appendingPathComponent("child"))
        })) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(target))
        }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("child")), Data("keep child".utf8))
        XCTAssertEqual(try entries(), ["new.txt"])
    }

    func testCheckpointFailureCleansTemporaryAndLeavesDestinationAbsent() throws {
        let target = directory.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: target, encoding: .utf8,
                                                  beforeNewFilePublish: {
            XCTAssertEqual(try self.entries().count, 1)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })) { error in
            guard case .saveFailed(let failedURL, _) = error as? DocumentFileError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, target)
        }
        XCTAssertEqual(try entries(), [])
    }

    func testChangedTemporaryEntryIsNeitherPublishedNorRemoved() throws {
        let target = directory.appendingPathComponent("new.txt")
        var replaced: URL!
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: target, encoding: .utf8,
                                                  beforeNewFilePublish: {
            let temporary = try XCTUnwrap(self.entries().first)
            replaced = self.directory.appendingPathComponent(temporary)
            try FileManager.default.removeItem(at: replaced)
            try Data("different owner entry".utf8).write(to: replaced)
        })) { error in
            guard case .saveFailed = error as? DocumentFileError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: replaced), Data("different owner entry".utf8))
        XCTAssertEqual(try entries(), [replaced.lastPathComponent])
    }

    func testSuccessfulNewFilesPreserveExactBytesAcrossSupportedEncodings() throws {
        for text in ["", "中文 🦊 e\u{301}\r\nsecond\nthird\r"] {
            for encoding in TextFileEncoding.allCases {
                let target = directory.appendingPathComponent("\(UUID().uuidString).txt")
                let saved = try DocumentFile.save(text, to: target, encoding: encoding)
                let loaded = try DocumentFile.read(target)
                XCTAssertEqual(Array(loaded.text.utf16), Array(text.utf16))
                XCTAssertEqual(loaded.encoding, encoding)
                XCTAssertEqual(loaded.diskSnapshot, saved.diskSnapshot)
                let expected: Data
                switch encoding {
                case .utf8: expected = Data(text.utf8)
                case .utf8BOM: expected = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
                case .utf16LittleEndianBOM: expected = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
                case .utf16BigEndianBOM: expected = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
                }
                XCTAssertEqual(try Data(contentsOf: target), expected)
            }
        }
        XCTAssertEqual(try entries().count, 8)
        XCTAssertFalse(try entries().contains(where: { $0.hasPrefix(".folivyn-") }))
    }

    func testExistingSnapshotAndExplicitOverwriteKeepTheirExistingSavePath() throws {
        let target = directory.appendingPathComponent("existing.txt")
        let original = try DocumentFile.save("original", to: target, encoding: .utf8)
        let saved = try DocumentFile.save("edited", to: target, encoding: .utf8,
                                         expectedSnapshot: original.diskSnapshot, beforeNewFilePublish: {
            XCTFail("Existing-document replacement must not use new-file publication")
        })
        XCTAssertEqual(try DocumentFile.read(target).diskSnapshot, saved.diskSnapshot)
        _ = try DocumentFile.save("explicit", to: target, encoding: .utf8,
                                  overwriteExternalChanges: true, beforeNewFilePublish: {
            XCTFail("Explicit overwrite must keep its existing replacement semantics")
        })
        XCTAssertEqual(try Data(contentsOf: target), Data("explicit".utf8))
        XCTAssertEqual(try entries(), ["existing.txt"])
    }

    func testNewFileNeedsParentWriteAndSearchButNotDirectoryListingPermission() throws {
        let parent = directory.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o300])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let target = parent.appendingPathComponent("new.txt")
        _ = try DocumentFile.save("new bytes", to: target, encoding: .utf8)
        XCTAssertEqual(try Data(contentsOf: target), Data("new bytes".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["new.txt"])
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
