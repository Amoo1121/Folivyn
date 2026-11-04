import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class SaveDestinationChoiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolivynSaveChoice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        directory = directory.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testFileAppearingAfterPanelValidationIsNotOverwritten() throws {
        let target = directory.appendingPathComponent("new.txt")
        let choice = try SaveDestinationChoice(capturing: target).validated(for: target)
        XCTAssertNil(choice.expectedSnapshot)
        let other = Data("another writer 中文 🦊\r\n".utf8)
        try other.write(to: target)
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: choice.url, encoding: .utf8,
                                                   expectedSnapshot: choice.expectedSnapshot)) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(target))
        }
        XCTAssertEqual(try Data(contentsOf: target), other)
    }

    func testUnchangedBinaryDestinationCanBeReplacedUsingRawSnapshot() throws {
        let target = directory.appendingPathComponent("existing.bin")
        let binary = Data([0xFF, 0x00, 0xFE, 0xC0, 0xAF])
        try binary.write(to: target)
        XCTAssertThrowsError(try DocumentFile.read(target))
        let choice = try SaveDestinationChoice(capturing: target).validated(for: target)
        XCTAssertEqual(choice.expectedSnapshot?.byteCount, binary.count)
        XCTAssertEqual(try Data(contentsOf: target), binary)
        _ = try DocumentFile.save("replacement 中文 🦊", to: choice.url, encoding: .utf8BOM,
                                  expectedSnapshot: choice.expectedSnapshot)
        XCTAssertEqual(try Data(contentsOf: target), Data([0xEF, 0xBB, 0xBF]) + Data("replacement 中文 🦊".utf8))
    }

    func testExistingDestinationChangedDuringConfirmationKeepsNewBytes() throws {
        let target = directory.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: target)
        let choice = try SaveDestinationChoice(capturing: target)
        let updated = Data("changed while the Replace question was open".utf8)
        try updated.write(to: target, options: .atomic)
        let validated = try choice.validated(for: target)
        XCTAssertThrowsError(try DocumentFile.save("my draft", to: validated.url, encoding: .utf8,
                                                   expectedSnapshot: validated.expectedSnapshot)) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(target))
        }
        XCTAssertEqual(try Data(contentsOf: target), updated)
    }

    func testFinalFilenameMismatchAndRetargetedSymlinkAreRejected() throws {
        let target = directory.appendingPathComponent("chosen")
        let choice = try SaveDestinationChoice(capturing: target)
        let adjusted = target.appendingPathExtension("txt")
        XCTAssertThrowsError(try choice.validated(for: adjusted)) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(adjusted))
        }
        let other = directory.appendingPathComponent("other.txt")
        try Data("keep other".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        XCTAssertThrowsError(try choice.validated(for: target)) { error in
            XCTAssertEqual(error as? DocumentFileError, .externalConflict(other))
        }
        XCTAssertEqual(try Data(contentsOf: other), Data("keep other".utf8))
    }

    func testOversizedAndNonRegularDestinationsAreErrorsRatherThanAbsence() throws {
        let large = directory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(DocumentFile.maximumReadBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try SaveDestinationChoice(capturing: large)) { error in
            guard case .tooLarge = error as? DocumentFileError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try DocumentFile.snapshotIfPresent(directory)) { error in
            XCTAssertEqual(error as? DocumentFileError, .notRegularFile(self.directory))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: large.path)[.size] as? NSNumber)?.intValue,
                       DocumentFile.maximumReadBytes + 1)
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/file.txt"))
        XCTAssertThrowsError(try DocumentFile.snapshotIfPresent(remote)) { error in
            XCTAssertEqual(error as? DocumentFileError, .invalidURL(remote))
        }
    }

    @MainActor
    func testDelegateCapturesOnlyConfirmedAttemptsAndNeverRecapturesDuringValidation() throws {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        panel.directoryURL = directory
        let delegate = SaveDestinationPanelDelegate()
        let target = directory.appendingPathComponent("new.txt")
        _ = delegate.panel(panel, userEnteredFilename: "new.txt", confirmed: false)
        XCTAssertThrowsError(try delegate.panel(panel, validate: target))
        _ = delegate.panel(panel, userEnteredFilename: "new.txt", confirmed: true)
        try Data("appeared before validation".utf8).write(to: target)
        try delegate.panel(panel, validate: target)
        XCTAssertNil(try delegate.choice(for: target).expectedSnapshot)
        _ = delegate.panel(panel, userEnteredFilename: "new.txt", confirmed: false)
        XCTAssertThrowsError(try delegate.choice(for: target))
        _ = delegate.panel(panel, userEnteredFilename: "new.txt", confirmed: true)
        XCTAssertNotNil(try delegate.choice(for: target).expectedSnapshot)
    }

    @MainActor
    func testDelegateRetainsCaptureFailureUntilAnotherConfirmedAttempt() throws {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        panel.directoryURL = directory
        let delegate = SaveDestinationPanelDelegate()
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        _ = delegate.panel(panel, userEnteredFilename: "target", confirmed: true)
        try FileManager.default.removeItem(at: target)
        try Data("now a regular file".utf8).write(to: target)
        XCTAssertThrowsError(try delegate.panel(panel, validate: target)) { error in
            guard case .notRegularFile(let failedURL) = error as? DocumentFileError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL.path, target.path)
        }
        _ = delegate.panel(panel, userEnteredFilename: "target", confirmed: true)
        try delegate.panel(panel, validate: target)
        XCTAssertNotNil(try delegate.choice(for: target).expectedSnapshot)
    }
}
