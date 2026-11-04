import Foundation

/// An explicit whole-document edit plan. Reading, viewing and ordinary saving
/// never call this operation. Only CR, LF and CRLF are converted; every other
/// Unicode scalar, including NEL/LS/PS and an in-text BOM, is retained exactly.
public enum NewlineConversion {
    public enum Target: String, CaseIterable, Sendable {
        case lf = "LF", crlf = "CRLF", cr = "CR"

        fileprivate var units: [UInt16] {
            switch self { case .lf: return [10]; case .crlf: return [13, 10]; case .cr: return [13] }
        }
    }

    public struct Limits: Sendable {
        public let maximumInputUTF16Units: Int
        public let maximumOutputUTF16Units: Int

        /// Expansion to CRLF has its own budget. Callers may lower either limit,
        /// but may not raise it above the editor's 10 Mi UTF-16-unit hard ceiling.
        public init(maximumInputUTF16Units: Int = 10 * 1_024 * 1_024,
                    maximumOutputUTF16Units: Int = 10 * 1_024 * 1_024) {
            self.maximumInputUTF16Units = maximumInputUTF16Units
            self.maximumOutputUTF16Units = maximumOutputUTF16Units
        }
    }

    public struct Conversion: Sendable {
        public let text: String
        public let sourceUTF16Count: Int
        public let selection: NSRange?
        public let changedNewlineCount: Int
        public var isChanged: Bool { changedNewlineCount > 0 }
    }

    /// Preserves the number of ending sequences, including leading/trailing empty
    /// lines. Selection coordinates are UTF-16. A boundary inside a CRLF stays
    /// between its units when CRLF is retained; when collapsed, it maps after the
    /// replacement newline. The same monotonic rule applies to both endpoints.
    /// Invalid ranges and boundaries splitting surrogate pairs are rejected.
    ///
    /// Run off the main actor. Before applying as one undoable whole-source edit,
    /// the caller must check source revision, exact source and IME state again.
    /// Encoded-byte limits are still checked separately by DocumentFile.save.
    public static func convert(
        _ source: String, to target: Target, selection: NSRange? = nil,
        limits: Limits = Limits(),
        isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }
    ) throws -> Conversion {
        let hardLimit = 10 * 1_024 * 1_024
        guard (0...hardLimit).contains(limits.maximumInputUTF16Units),
              (0...hardLimit).contains(limits.maximumOutputUTF16Units) else {
            throw NewlineConversionError.invalidLimits
        }
        if isCancelled() { throw CancellationError() }
        let selectionEnd: Int?
        if let selection {
            guard selection.location >= 0, selection.length >= 0,
                  selection.location <= Int.max - selection.length else { throw NewlineConversionError.invalidSelection }
            selectionEnd = selection.location + selection.length
        } else { selectionEnd = nil }
        var mappedStart: Int?, mappedEnd: Int?
        func mapBoundary(_ input: Int, to output: Int) {
            if selection?.location == input { mappedStart = output }
            if selectionEnd == input { mappedEnd = output }
        }

        var output: [UInt16] = []
        output.reserveCapacity(min(4_096, limits.maximumOutputUTF16Units))
        let newline = target.units
        var iterator = source.utf16.makeIterator()
        var current = iterator.next()
        var previous: UInt16?
        var offset = 0, changedCount = 0, nextCancellationCheck = 0
        while let unit = current {
            if offset >= nextCancellationCheck {
                if isCancelled() { throw CancellationError() }
                nextCancellationCheck = offset + 4_096
            }
            if let previous, (0xD800...0xDBFF).contains(previous), (0xDC00...0xDFFF).contains(unit),
               selection?.location == offset || selectionEnd == offset { throw NewlineConversionError.invalidSelection }
            mapBoundary(offset, to: output.count)
            let following = iterator.next()
            let isCRLF = unit == 13 && following == 10
            let inputLength = isCRLF ? 2 : 1
            guard inputLength <= limits.maximumInputUTF16Units - offset else {
                throw NewlineConversionError.inputLimitExceeded(limit: limits.maximumInputUTF16Units)
            }
            let isNewline = unit == 13 || unit == 10
            let outputLength = isNewline ? newline.count : 1
            guard outputLength <= limits.maximumOutputUTF16Units - output.count else {
                throw NewlineConversionError.outputLimitExceeded(limit: limits.maximumOutputUTF16Units)
            }
            if isNewline {
                let original: Target = isCRLF ? .crlf : (unit == 13 ? .cr : .lf)
                if original != target { changedCount += 1 }
                if isCRLF {
                    mapBoundary(offset + 1, to: output.count + (target == .crlf ? 1 : newline.count))
                }
                output.append(contentsOf: newline)
            } else { output.append(unit) }
            offset += inputLength
            previous = isCRLF ? 10 : unit
            current = isCRLF ? iterator.next() : following
        }
        mapBoundary(offset, to: output.count)
        let mappedSelection: NSRange?
        if let selection {
            guard selection.location <= offset, let selectionEnd, selectionEnd <= offset,
                  let mappedStart, let mappedEnd else { throw NewlineConversionError.invalidSelection }
            mappedSelection = NSRange(location: mappedStart, length: mappedEnd - mappedStart)
        } else { mappedSelection = nil }
        if isCancelled() { throw CancellationError() }
        // A Swift String already has valid surrogate pairs. Replacing only CR/LF
        // cannot split a pair or require replacement decoding of the retained text.
        let converted = changedCount == 0 ? source : String(decoding: output, as: UTF16.self)
        if isCancelled() { throw CancellationError() }
        return Conversion(text: converted, sourceUTF16Count: offset, selection: mappedSelection,
                          changedNewlineCount: changedCount)
    }
}

public enum NewlineConversionError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidSelection
    case inputLimitExceeded(limit: Int)
    case outputLimitExceeded(limit: Int)
}
