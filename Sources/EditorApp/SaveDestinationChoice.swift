import AppKit
import EditorCore
import Foundation

/// The destination observed before NSSavePanel asks whether to replace a file.
/// A successful panel does not authorize overwriting a file that appeared later.
struct SaveDestinationChoice {
    let url: URL
    let expectedSnapshot: DiskSnapshot?

    init(capturing url: URL) throws {
        guard url.isFileURL else { throw DocumentFileError.invalidURL(url) }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        expectedSnapshot = try DocumentFile.snapshotIfPresent(self.url)
    }

    func validated(for selectedURL: URL) throws -> Self {
        guard selectedURL.isFileURL else { throw DocumentFileError.invalidURL(selectedURL) }
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard selected == url else { throw DocumentFileError.externalConflict(selected) }
        return self
    }
}

/// Keep this object alive through runModal: NSSavePanel.delegate is weak.
/// The filename callback precedes both extension adjustment and the native
/// Replace prompt. Folivyn sets no allowedContentTypes or automatic extension;
/// final URL validation rejects an unexpected adjustment instead of recapturing.
@MainActor
final class SaveDestinationPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private var confirmation: Result<SaveDestinationChoice, Error>?

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        confirmation = nil
        guard okFlag else { return filename }
        confirmation = Result {
            let candidate: URL
            if (filename as NSString).isAbsolutePath {
                candidate = URL(fileURLWithPath: filename)
            } else if let directory = (sender as? NSSavePanel)?.directoryURL {
                candidate = directory.appendingPathComponent(filename)
            } else {
                throw DocumentFileError.invalidURL(URL(fileURLWithPath: filename))
            }
            return try SaveDestinationChoice(capturing: candidate)
        }
        return filename
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try choice(for: url)
    }

    func choice(for url: URL) throws -> SaveDestinationChoice {
        guard let confirmation else { throw DocumentFileError.externalConflict(url) }
        return try confirmation.get().validated(for: url)
    }
}
