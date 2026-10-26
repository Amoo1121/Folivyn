import Darwin
import Foundation

public struct LoadedTextPreview: Sendable {
    public let text: String
    public let encoding: TextFileEncoding
    /// The preview omits source text because of its byte or line budget.
    public let truncated: Bool
}

public enum TextPreviewError: Error, LocalizedError, Equatable {
    case binaryContent

    public var errorDescription: String? {
        message(in: CoreLocalization.bundle)
    }

    func message(in bundle: Bundle) -> String {
        switch self {
        case .binaryContent:
            return CoreLocalization.string("preview.error.binaryContent", bundle: bundle)
        }
    }
}

/// A read-only, bounded prefix for Quick Look. This never creates an editable document.
public enum TextPreview {
    public static let defaultByteLimit = 200 * 1_024
    public static let defaultLineLimit = 2_000

    /// The byte budget applies to encoded text, excluding its optional BOM. Up to
    /// seven extra bytes are read to identify that BOM, validate a scalar crossing
    /// the boundary, and detect omitted content. Text is cut only between Unicode
    /// scalars; a combining sequence may continue beyond the preview.
    ///
    /// Only the bounded prefix is validated. No claim is made about unseen bytes
    /// later in a large file. Files are opened read-only, including hard links.
    public static func read(
        _ url: URL,
        byteLimit: Int = defaultByteLimit,
        lineLimit: Int = defaultLineLimit
    ) throws -> LoadedTextPreview {
        precondition(byteLimit > 0 && byteLimit <= Int.max - 7 && lineLimit > 0)
        guard url.isFileURL else { throw DocumentFileError.invalidURL(url) }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let bytes = try readPrefix(target, limit: byteLimit + 7)
        let decoded: (text: String, encoding: TextFileEncoding, truncated: Bool)
        if bytes.starts(with: [0xFF, 0xFE]) {
            let result = try decodeUTF16(bytes, byteLimit: byteLimit, littleEndian: true)
            decoded = (result.text, .utf16LittleEndianBOM, result.truncated)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            let result = try decodeUTF16(bytes, byteLimit: byteLimit, littleEndian: false)
            decoded = (result.text, .utf16BigEndianBOM, result.truncated)
        } else {
            let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
            let result = try decodeUTF8(bytes, offset: hasBOM ? 3 : 0, byteLimit: byteLimit)
            decoded = (result.text, hasBOM ? .utf8BOM : .utf8, result.truncated)
        }
        let limited = limitLines(decoded.text, to: lineLimit)
        return LoadedTextPreview(
            text: limited.text,
            encoding: decoded.encoding,
            truncated: decoded.truncated || limited.truncated
        )
    }

    private static func readPrefix(_ url: URL, limit: Int) throws -> [UInt8] {
        // Nonblocking open prevents a FIFO (including a path replaced between
        // resolution and open) from waiting for a writer. Validate the opened FD,
        // rather than relying on metadata for a potentially different path.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw readError(url, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw readError(url, code: errno) }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw DocumentFileError.notRegularFile(url)
        }
        do {
            var data = Data()
            data.reserveCapacity(limit)
            while data.count < limit {
                guard let chunk = try handle.read(upToCount: limit - data.count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return Array(data)
        } catch {
            throw DocumentFileError.readFailed(url, reason: error.localizedDescription)
        }
    }

    private static func readError(_ url: URL, code: Int32) -> DocumentFileError {
        if code == ENOENT { return .fileNotFound(url) }
        return .readFailed(url, reason: String(cString: strerror(code)))
    }

    private static func decodeUTF8(
        _ bytes: [UInt8], offset: Int, byteLimit: Int
    ) throws -> (text: String, truncated: Bool) {
        let end = min(bytes.count, offset + byteLimit)
        var cursor = offset
        while cursor < end {
            let first = bytes[cursor]
            let length: Int
            switch first {
            case 0x00...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: throw DocumentFileError.invalidTextEncoding
            }
            guard cursor + length <= bytes.count else { throw DocumentFileError.invalidTextEncoding }
            if length > 1 {
                for index in (cursor + 1)..<(cursor + length) {
                    guard (0x80...0xBF).contains(bytes[index]) else { throw DocumentFileError.invalidTextEncoding }
                }
                let second = bytes[cursor + 1]
                // Exclude overlong forms, surrogate code points, and > U+10FFFF.
                guard !(first == 0xE0 && second < 0xA0),
                      !(first == 0xED && second >= 0xA0),
                      !(first == 0xF0 && second < 0x90),
                      !(first == 0xF4 && second > 0x8F) else {
                    throw DocumentFileError.invalidTextEncoding
                }
            }
            if length == 1 { try requireTextControl(UInt16(first)) }
            if cursor + length > end { break }
            cursor += length
        }
        // Validation above makes this strict initializer succeed without repairs.
        guard let text = String(bytes: bytes[offset..<cursor], encoding: .utf8) else {
            throw DocumentFileError.invalidTextEncoding
        }
        return (text, cursor < bytes.count)
    }

    private static func decodeUTF16(
        _ bytes: [UInt8], byteLimit: Int, littleEndian: Bool
    ) throws -> (text: String, truncated: Bool) {
        let end = min(bytes.count, 2 + byteLimit)
        var cursor = 2
        var units = [UInt16]()
        func unit(at index: Int) -> UInt16 {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            return littleEndian ? first | (second << 8) : (first << 8) | second
        }
        while cursor < end {
            guard cursor + 2 <= bytes.count else { throw DocumentFileError.invalidTextEncoding }
            let first = unit(at: cursor)
            let length: Int
            if (0xD800...0xDBFF).contains(first) {
                guard cursor + 4 <= bytes.count, (0xDC00...0xDFFF).contains(unit(at: cursor + 2)) else {
                    throw DocumentFileError.invalidTextEncoding
                }
                length = 4
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else { throw DocumentFileError.invalidTextEncoding }
                try requireTextControl(first)
                length = 2
            }
            if cursor + length > end { break }
            units.append(first)
            if length == 4 { units.append(unit(at: cursor + 2)) }
            cursor += length
        }
        return (String(decoding: units, as: UTF16.self), cursor < bytes.count)
    }

    private static func requireTextControl(_ scalar: UInt16) throws {
        // An encoding-valid stream may still be binary. Reject NUL and C0 control
        // characters except whitespace used in ordinary source and log files.
        switch scalar {
        case 0...8, 11, 14...31: throw TextPreviewError.binaryContent
        default: break
        }
    }

    private static func limitLines(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        let scalars = text.unicodeScalars
        var cursor = scalars.startIndex
        var lines = 0
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            cursor = scalars.index(after: cursor)
            if scalar == "\r", cursor < scalars.endIndex, scalars[cursor] == "\n" {
                cursor = scalars.index(after: cursor)
            }
            if [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains(scalar.value) {
                lines += 1
                if lines == limit, cursor < scalars.endIndex {
                    return (String(scalars[..<cursor]), true)
                }
            }
        }
        return (text, false)
    }
}
