import Foundation
import XCTest
@testable import EditorCore

final class DocumentFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EditorCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testAllSupportedEncodingsPreserveOriginalBytesAndLineEndings() throws {
        let text = "中文 👩🏽‍💻 e\u{301}\r\n\u{FEFF}second\rthird\n"
        let variants: [(TextFileEncoding, Data)] = [
            (.utf8, Data(text.utf8)),
            (.utf8BOM, Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
            (.utf16LittleEndianBOM, Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!),
            (.utf16BigEndianBOM, Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!)
        ]
        for (encoding, original) in variants {
            let url = directory.appendingPathComponent(encoding.rawValue)
            try original.write(to: url)
            let loaded = try DocumentFile.read(url)
            XCTAssertEqual(Array(loaded.text.unicodeScalars), Array(text.unicodeScalars))
            XCTAssertEqual(loaded.encoding, encoding)
            let saved = try DocumentFile.save(loaded.text, to: url, encoding: loaded.encoding, expectedSnapshot: loaded.diskSnapshot)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(saved.diskSnapshot, loaded.diskSnapshot)
            let edited = text + "修改 🦊"
            _ = try DocumentFile.save(edited, to: url, encoding: encoding, expectedSnapshot: saved.diskSnapshot)
            XCTAssertEqual(try DocumentFile.read(url).text, edited)
            XCTAssertEqual(try DocumentFile.read(url).encoding, encoding)
        }
    }

    func testInvalidEncodingIsRejectedWithoutReplacingBytes() throws {
        let invalid: [[UInt8]] = [
            [0xC0, 0xAF],                       // Overlong UTF-8.
            [0xED, 0xA0, 0x80],                 // UTF-8 encoded surrogate.
            [0xFF, 0xFE, 0x61],                 // Odd UTF-16 length.
            [0xFF, 0xFE, 0x00, 0xD8],           // Unpaired high surrogate.
            [0xFE, 0xFF, 0xDC, 0x00],           // Unpaired low surrogate.
            [0xFF, 0xFE, 0x00, 0xD8, 0x61, 0]   // High surrogate followed by ASCII.
        ]
        for (index, bytes) in invalid.enumerated() {
            let url = directory.appendingPathComponent("invalid-\(index)")
            let original = Data(bytes)
            try original.write(to: url)
            XCTAssertThrowsError(try DocumentFile.read(url)) { error in
                XCTAssertEqual(error as? DocumentFileError, .invalidTextEncoding)
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testEmptyFilesAndBOMOnlyFilesRoundTrip() throws {
        for encoding in TextFileEncoding.allCases {
            let url = directory.appendingPathComponent("empty-\(encoding.rawValue)")
            let saved = try DocumentFile.save("", to: url, encoding: encoding)
            let loaded = try DocumentFile.read(url)
            XCTAssertEqual(loaded.text, "")
            XCTAssertEqual(loaded.encoding, encoding)
            XCTAssertEqual(loaded.diskSnapshot, saved.diskSnapshot)
        }
    }

    func testChangedContentConflictsEvenWhenSizeAndTimestampAreUnchanged() throws {
        let url = directory.appendingPathComponent("conflict.txt")
        let first = try DocumentFile.save("one", to: url, encoding: .utf8)
        let originalDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        try Data("two".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
        XCTAssertThrowsError(try DocumentFile.save("mine", to: url, encoding: .utf8, expectedSnapshot: first.diskSnapshot)) { error in
            guard case .externalConflict = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("two".utf8))
        let reloaded = try DocumentFile.read(url)
        XCTAssertEqual(reloaded.text, "two")
        XCTAssertNotEqual(reloaded.diskSnapshot, first.diskSnapshot)
        let saved = try DocumentFile.save("mine", to: url, encoding: .utf8, expectedSnapshot: reloaded.diskSnapshot)
        XCTAssertEqual(try DocumentFile.read(url).diskSnapshot, saved.diskSnapshot)
    }

    func testTouchWithoutContentChangesDoesNotConflict() throws {
        let url = directory.appendingPathComponent("touch.txt")
        let loaded = try DocumentFile.save("original", to: url, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: url.path)
        _ = try DocumentFile.save("edited", to: url, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)
        XCTAssertEqual(try DocumentFile.read(url).text, "edited")
    }

    func testDeletedFileRequiresExplicitOverwriteAndReloadReportsMissing() throws {
        let url = directory.appendingPathComponent("deleted.txt")
        let loaded = try DocumentFile.save("original", to: url, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try DocumentFile.save("edited", to: url, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)) { error in
            guard case .externalConflict = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try DocumentFile.read(url)) { error in
            guard case .fileNotFound = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        _ = try DocumentFile.save("recreated", to: url, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot, overwriteExternalChanges: true)
        XCTAssertEqual(try DocumentFile.read(url).text, "recreated")
    }

    func testNewDestinationCannotOverwriteExistingFileWithoutConsent() throws {
        let url = directory.appendingPathComponent("existing.txt")
        try Data("existing".utf8).write(to: url)
        XCTAssertThrowsError(try DocumentFile.save("replacement", to: url, encoding: .utf8))
        XCTAssertEqual(try Data(contentsOf: url), Data("existing".utf8))
        _ = try DocumentFile.save("replacement", to: url, encoding: .utf8, overwriteExternalChanges: true)
        XCTAssertEqual(try DocumentFile.read(url).text, "replacement")
    }

    func testReadAndSaveRejectOverPrototypeLimitWithoutChangingFile() throws {
        let url = directory.appendingPathComponent("large.log")
        try Data(repeating: 0x61, count: DocumentFile.maximumReadBytes + 1).write(to: url)
        XCTAssertThrowsError(try DocumentFile.read(url)) { error in
            guard case .tooLarge = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        let small = directory.appendingPathComponent("small.txt")
        let original = try DocumentFile.save("safe", to: small, encoding: .utf8)
        XCTAssertThrowsError(try DocumentFile.save(String(repeating: "a", count: DocumentFile.maximumReadBytes + 1), to: small, encoding: .utf8, expectedSnapshot: original.diskSnapshot))
        XCTAssertEqual(try Data(contentsOf: small), Data("safe".utf8))
    }

    func testAtomicSavePreservesPOSIXPermissionsOnLocalFilesystem() throws {
        let url = directory.appendingPathComponent("permissions.txt")
        let loaded = try DocumentFile.save("original", to: url, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        _ = try DocumentFile.save("replacement", to: url, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testSymlinkSaveUpdatesTargetAndPreservesLink() throws {
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        _ = try DocumentFile.save("original", to: target, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let loaded = try DocumentFile.read(link)
        XCTAssertEqual(loaded.url, target.resolvingSymlinksInPath())
        _ = try DocumentFile.save("changed", to: link, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try DocumentFile.read(target).text, "changed")
    }

    func testHardLinkedFilesCanBeReadButSaveIsRefused() throws {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        _ = try DocumentFile.save("original", to: first, encoding: .utf8)
        try FileManager.default.linkItem(at: first, to: second)
        let loaded = try DocumentFile.read(second)
        XCTAssertThrowsError(try DocumentFile.save("changed", to: second, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)) { error in
            guard case .multipleHardLinks = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: first), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("original".utf8))
    }

    func testFailedWriteLeavesExistingFileUntouched() throws {
        let protectedDirectory = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        let url = protectedDirectory.appendingPathComponent("keep.txt")
        let loaded = try DocumentFile.save("original", to: url, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path) }
        // Atomic replacement needs a writable parent directory even when the file is writable.
        XCTAssertThrowsError(try DocumentFile.save("replacement", to: url, encoding: .utf8, expectedSnapshot: loaded.diskSnapshot)) { error in
            guard case .saveFailed = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
    }
}
