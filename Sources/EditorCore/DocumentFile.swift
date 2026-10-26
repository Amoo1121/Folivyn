import CryptoKit
import Foundation

/// The prototype deliberately supports only encodings that can be detected safely.
public enum TextFileEncoding: String, CaseIterable, Sendable {
    case utf8
    case utf8BOM
    case utf16LittleEndianBOM
    case utf16BigEndianBOM

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LittleEndianBOM: return "UTF-16 LE BOM"
        case .utf16BigEndianBOM: return "UTF-16 BE BOM"
        }
    }
}

/// A byte-level snapshot: touching a file without changing its contents is not a conflict.
public struct DiskSnapshot: Equatable, Sendable {
    public let byteCount: Int
    private let digest: Data

    fileprivate init(_ data: Data) {
        byteCount = data.count
        digest = Data(SHA256.hash(data: data))
    }
}

public struct LoadedTextFile: Sendable {
    /// Absolute, standardized URL with symbolic links resolved to their target.
    public let url: URL
    public let text: String
    public let encoding: TextFileEncoding
    public let diskSnapshot: DiskSnapshot
}

public enum DocumentFileError: Error, LocalizedError, Equatable {
    case invalidURL(URL)
    case fileNotFound(URL)
    case notRegularFile(URL)
    case tooLarge(actualBytes: Int64, limitBytes: Int)
    case unsupportedEncoding
    case invalidTextEncoding
    case externalConflict(URL)
    case multipleHardLinks(URL)
    case readFailed(URL, reason: String)
    case saveFailed(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "只能打开本地文件。"
        case .fileNotFound(let url):
            return "文件已不存在：\(url.lastPathComponent)"
        case .notRegularFile:
            return "请选择普通文本文件。"
        case .tooLarge(_, let limit):
            return "原型目前支持最大 \(limit / 1_024 / 1_024) MiB 的文本文件。"
        case .unsupportedEncoding:
            return "原型仅支持 UTF-8，以及带 BOM 的 UTF-16 LE / BE 文件。"
        case .invalidTextEncoding:
            return "文件不是有效的 UTF-8 或带 BOM 的 UTF-16 文本，未进行替换解码。"
        case .externalConflict(let url):
            return "磁盘上的“\(url.lastPathComponent)”已修改、删除或被其他文件替代。请重新加载，或确认后覆盖。"
        case .multipleHardLinks:
            return "此文件有多个硬链接。为避免改变链接关系，请另存为新文件。"
        case .readFailed(_, let reason):
            return "无法读取文件：\(reason)"
        case .saveFailed(_, let reason):
            return "无法保存文件：\(reason)"
        }
    }
}

/// Local file I/O only. No networking, downloaded codecs, or third-party dependencies.
public enum DocumentFile {
    public static let maximumReadBytes = 10 * 1_024 * 1_024

    public static func read(_ url: URL) throws -> LoadedTextFile {
        let target = try canonicalURL(url)
        let data = try readBytes(target)
        let decoded = try decode(data)
        return LoadedTextFile(
            url: target,
            text: decoded.text,
            encoding: decoded.encoding,
            diskSnapshot: DiskSnapshot(data)
        )
    }

    /// Pass the snapshot returned by the most recent successful read/save.
    /// A nil snapshot is for new destinations: existing destinations need explicit overwrite.
    /// Foundation's atomic replacement preserves the existing file on ordinary write failures.
    /// It preserves POSIX permissions on the tested local APFS filesystem. It is not a
    /// cross-process compare-and-swap: a separate writer can race the final check and rename.
    public static func save(
        _ text: String,
        to url: URL,
        encoding: TextFileEncoding,
        expectedSnapshot: DiskSnapshot? = nil,
        overwriteExternalChanges: Bool = false
    ) throws -> LoadedTextFile {
        let target = try canonicalURL(url)
        let data = encode(text, encoding: encoding)
        guard data.count <= maximumReadBytes else {
            throw DocumentFileError.tooLarge(actualBytes: Int64(data.count), limitBytes: maximumReadBytes)
        }

        let existingAttributes = try attributesIfPresent(target)
        if let attributes = existingAttributes {
            try requireRegularFile(attributes, url: target)
            if (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 > 1 {
                throw DocumentFileError.multipleHardLinks(target)
            }
        }

        if !overwriteExternalChanges {
            if let expectedSnapshot {
                guard existingAttributes != nil else {
                    throw DocumentFileError.externalConflict(target)
                }
                let currentData: Data
                do {
                    currentData = try readBytes(target)
                } catch DocumentFileError.tooLarge {
                    throw DocumentFileError.externalConflict(target)
                } catch DocumentFileError.fileNotFound {
                    throw DocumentFileError.externalConflict(target)
                }
                guard DiskSnapshot(currentData) == expectedSnapshot else {
                    throw DocumentFileError.externalConflict(target)
                }
                if currentData == data {
                    return LoadedTextFile(url: target, text: text, encoding: encoding, diskSnapshot: expectedSnapshot)
                }
            } else if existingAttributes != nil {
                throw DocumentFileError.externalConflict(target)
            }
        }

        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw DocumentFileError.saveFailed(target, reason: error.localizedDescription)
        }
        return LoadedTextFile(url: target, text: text, encoding: encoding, diskSnapshot: DiskSnapshot(data))
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw DocumentFileError.invalidURL(url) }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return nil
            }
            throw DocumentFileError.readFailed(url, reason: error.localizedDescription)
        }
    }

    private static func requireRegularFile(_ attributes: [FileAttributeKey: Any], url: URL) throws {
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DocumentFileError.notRegularFile(url)
        }
    }

    private static func readBytes(_ url: URL) throws -> Data {
        guard let attributes = try attributesIfPresent(url) else {
            throw DocumentFileError.fileNotFound(url)
        }
        try requireRegularFile(attributes, url: url)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Int64(maximumReadBytes) else {
            throw DocumentFileError.tooLarge(actualBytes: size, limitBytes: maximumReadBytes)
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            data.reserveCapacity(Int(size))
            // Bound the actual read too: metadata can become stale while another process writes.
            while let chunk = try handle.read(upToCount: min(1_024 * 1_024, maximumReadBytes + 1 - data.count)),
                  !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumReadBytes else {
                    throw DocumentFileError.tooLarge(actualBytes: Int64(data.count), limitBytes: maximumReadBytes)
                }
            }
            return data
        } catch let error as DocumentFileError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                throw DocumentFileError.fileNotFound(url)
            }
            throw DocumentFileError.readFailed(url, reason: error.localizedDescription)
        }
    }

    private static func decode(_ data: Data) throws -> (text: String, encoding: TextFileEncoding) {
        let bytes = [UInt8](data)
        // A UTF-16 LE file may begin with U+0000, which shares the UTF-32 LE
        // signature. Prefer the explicitly supported UTF-16 representation;
        // every accepted byte sequence must survive an unchanged save exactly.
        if bytes.starts(with: [0xFF, 0xFE]) {
            return (try decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: true), .utf16LittleEndianBOM)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return (try decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: false), .utf16BigEndianBOM)
        }
        let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = hasBOM ? Array(bytes.dropFirst(3)) : bytes
        guard let text = String(bytes: payload, encoding: .utf8) else {
            throw DocumentFileError.invalidTextEncoding
        }
        return (text, hasBOM ? .utf8BOM : .utf8)
    }

    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
        guard bytes.count.isMultiple(of: 2) else { throw DocumentFileError.invalidTextEncoding }
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            units.append(littleEndian ? first | (second << 8) : (first << 8) | second)
        }
        // String(decoding:as:) repairs invalid sequences, so validate surrogates first.
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    throw DocumentFileError.invalidTextEncoding
                }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { throw DocumentFileError.invalidTextEncoding }
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func encode(_ text: String, encoding: TextFileEncoding) -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LittleEndianBOM, .utf16BigEndianBOM:
            let littleEndian = encoding == .utf16LittleEndianBOM
            var data = Data(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            data.reserveCapacity(2 + text.utf16.count * 2)
            for unit in text.utf16 {
                let low = UInt8(truncatingIfNeeded: unit)
                let high = UInt8(truncatingIfNeeded: unit >> 8)
                data.append(littleEndian ? low : high)
                data.append(littleEndian ? high : low)
            }
            return data
        }
    }
}
