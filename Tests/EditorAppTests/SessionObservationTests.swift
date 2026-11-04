import AppKit
import EditorCore
import XCTest
@testable import EditorApp

final class SessionObservationTests: XCTestCase {
    @MainActor
    func testNewSessionStartsWatchingAfterFirstSaveAndStopsOnClose() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EditorSession()
        defer { session.stopFileObservation(); session.lineRuler.invalidate(); session.syntax.cancel(); session.presentation?.cancel() }
        session.startFileObservation()
        XCTAssertNil(session.fileObservation?.observedURL)
        let saved = try DocumentFile.save("", to: directory.appendingPathComponent("first.txt"), encoding: .utf8)
        session.acceptSaved(saved)
        XCTAssertEqual(session.fileObservation?.observedURL, saved.url)
        let observation = try XCTUnwrap(session.fileObservation)
        session.stopFileObservation()
        XCTAssertTrue(observation.isStopped)
        XCTAssertNil(session.fileObservation)
        try Data("external".utf8).write(to: saved.url)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.textView.string, "")
        XCTAssertFalse(session.diskChanged)
    }

    @MainActor
    func testPreviewSessionDoesNotStartEditableFileObserver() {
        _ = NSApplication.shared
        let session = EditorSession(readOnlyURL: URL(fileURLWithPath: "/unavailable-preview-test.txt"))
        defer { session.presentation?.cancel(); session.lineRuler.invalidate(); session.syntax.cancel() }
        session.startFileObservation()
        XCTAssertNil(session.fileObservation)
    }
}
