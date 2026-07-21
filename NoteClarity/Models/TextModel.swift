import Foundation

// MARK: - File encoding

enum FileEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8, utf8bom, utf16le, utf16be, latin1

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8bom: return "UTF-8 BOM"
        case .utf16le: return "UTF-16 LE"
        case .utf16be: return "UTF-16 BE"
        case .latin1: return "ISO-8859-1"
        }
    }

    /// Decodes file data, returning the text and the detected encoding.
    /// Detection order: BOM sniffing, strict UTF-8, NUL-byte heuristic for
    /// BOM-less UTF-16, then ISO-8859-1 as the never-fails fallback.
    static func decode(_ data: Data) -> (text: String, encoding: FileEncoding) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8bom)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return (String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "", .utf16le)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return (String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "", .utf16be)
        }
        if let s = String(data: data, encoding: .utf8) {
            return (s, .utf8)
        }
        if data.count >= 4 {
            let sample = data.prefix(1024)
            var evenZeros = 0, oddZeros = 0
            for (i, b) in sample.enumerated() where b == 0 {
                if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let quarter = max(1, sample.count / 4)
            if oddZeros >= quarter, let s = String(data: data, encoding: .utf16LittleEndian) {
                return (s, .utf16le)
            }
            if evenZeros >= quarter, let s = String(data: data, encoding: .utf16BigEndian) {
                return (s, .utf16be)
            }
        }
        return (String(data: data, encoding: .isoLatin1) ?? "", .latin1)
    }

    /// Encodes text for writing, prepending the BOM where the encoding requires one.
    /// The LE/BE Foundation encodings do not emit a BOM on their own.
    func encode(_ string: String) -> Data {
        switch self {
        case .utf8:
            return Data(string.utf8)
        case .utf8bom:
            return Data([0xEF, 0xBB, 0xBF]) + Data(string.utf8)
        case .utf16le:
            return Data([0xFF, 0xFE]) + (string.data(using: .utf16LittleEndian) ?? Data())
        case .utf16be:
            return Data([0xFE, 0xFF]) + (string.data(using: .utf16BigEndian) ?? Data())
        case .latin1:
            return string.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(string.utf8)
        }
    }
}

// MARK: - Line endings

enum LineEnding: String, Codable, CaseIterable, Identifiable {
    case lf, crlf, cr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    var menuName: String {
        switch self {
        case .lf: return "LF (macOS / Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (Classic Mac)"
        }
    }

    var terminator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// Majority vote over the raw (pre-normalization) text.
    static func detect(in text: String, default def: LineEnding) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var prevCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if prevCR { crlf += 1 } else { lf += 1 }
                prevCR = false
            } else {
                if prevCR { cr += 1 }
                prevCR = (scalar == "\r")
            }
        }
        if prevCR { cr += 1 }
        if crlf == 0 && lf == 0 && cr == 0 { return def }
        if crlf >= lf && crlf >= cr { return .crlf }
        if lf >= cr { return .lf }
        return .cr
    }

    /// The editor buffer always holds LF internally; the ending is applied at save time.
    static func normalizeToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func serialize(_ lfText: String) -> String {
        self == .lf ? lfText : lfText.replacingOccurrences(of: "\n", with: terminator)
    }
}

// MARK: - Language

enum Language: String, Codable, CaseIterable, Identifiable {
    case plaintext, json, markdown, javascript, typescript, python, swift, xml, html, shell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plaintext: return "Plain Text"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .swift: return "Swift"
        case .xml: return "XML"
        case .html: return "HTML"
        case .shell: return "Shell"
        }
    }

    static func detect(url: URL?, firstLine: String) -> Language {
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty {
            switch ext {
            case "json", "jsonc": return .json
            case "md", "markdown", "mdown": return .markdown
            case "js", "mjs", "cjs", "jsx": return .javascript
            case "ts", "tsx", "mts", "cts": return .typescript
            case "py", "pyw", "pyi": return .python
            case "swift": return .swift
            case "xml", "plist", "svg", "xib", "storyboard", "xsd", "xsl", "entitlements": return .xml
            case "html", "htm", "xhtml": return .html
            case "sh", "bash", "zsh", "command", "zshrc", "bashrc": return .shell
            case "txt", "text", "log": return .plaintext
            default: break
            }
        }
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("node") { return .javascript }
            if firstLine.contains("sh") { return .shell }
        }
        if firstLine.hasPrefix("<?xml") { return .xml }
        if firstLine.lowercased().hasPrefix("<!doctype html") { return .html }
        return .plaintext
    }
}

// MARK: - Debouncer

/// Coalesces bursts of calls (keystrokes) into a single trailing invocation on main.
final class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?

    init(_ delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() { workItem?.cancel() }
}

// MARK: - Word completion matching

/// Anchored case-insensitive prefix matching over a harvested word list.
/// Foundation-only so the standalone swiftc battery can exercise it.
enum WordCompletion {
    static func matches(for partial: String, in cache: [String], cap: Int = 200) -> [String] {
        guard !partial.isEmpty else { return [] }
        let matched = cache.filter {
            $0.count > partial.count
                && $0.range(of: partial, options: [.anchored, .caseInsensitive]) != nil
        }
        return Array(matched.prefix(cap))
    }
}

// MARK: - Line index lookup

/// Binary search over a line-starts table (UTF-16 offsets). Shared by the
/// ruler, status bar, and line-marker bookkeeping; lives here (not in an
/// AppKit type) so Foundation-only code can use it.
enum LineIndex {
    /// Index of the line containing `offset` — the largest start <= offset.
    static func of(_ offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
