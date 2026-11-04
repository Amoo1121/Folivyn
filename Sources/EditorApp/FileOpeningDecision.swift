import Foundation
import EditorCore

/// Classification follows strict decoding. Encoding-valid control data still
/// gets a read-only fallback; it is never repaired into an editable document.
enum FileOpeningDecision {
    case editable(LoadedTextFile)
    case preview(URL)

    static func open(_ url: URL) throws -> FileOpeningDecision {
        do {
            let loaded = try DocumentFile.read(url)
            if loaded.text.unicodeScalars.contains(where: { scalar in
                switch scalar.value { case 0...8, 11, 14...31: return true; default: return false }
            }) { return .preview(loaded.url) }
            return .editable(loaded)
        } catch DocumentFileError.tooLarge, DocumentFileError.invalidTextEncoding, DocumentFileError.unsupportedEncoding {
            return .preview(url.standardizedFileURL.resolvingSymlinksInPath())
        }
    }
}
