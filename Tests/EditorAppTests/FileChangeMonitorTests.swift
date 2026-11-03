import AppKit
import XCTest
@testable import EditorApp

final class FileChangeMonitorTests: XCTestCase {
    @MainActor
    func testWriteAtomicReplacementDeletionAndRecreationAreObserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.txt")
        try Data("one".utf8).write(to: url)
        var events = 0
        let monitor = FileChangeMonitor(url: url) { events += 1 }
        defer { monitor.stop() }
        for operation in 0..<4 {
            let previous = events
            switch operation {
            case 0: try Data("two".utf8).write(to: url)
            case 1: try Data("three".utf8).write(to: url, options: .atomic)
            case 2: try FileManager.default.removeItem(at: url)
            default: try Data("four".utf8).write(to: url)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while events == previous, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(events, previous, "Missing event for operation \(operation)")
        }
        monitor.stop()
        let stoppedCount = events
        try Data("after stop".utf8).write(to: url)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(events, stoppedCount)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after stop")
    }
}
