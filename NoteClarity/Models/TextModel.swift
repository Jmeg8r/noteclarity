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

    /// One decoded file plus everything the caller needs to be honest about it.
    /// This layer never hides a problem (P1-04): replacement/fallback decoding
    /// is reported, not silently returned as clean text.
    struct DecodedFile {
        var text: String
        var encoding: FileEncoding
        /// The bytes broke the encoding they declared (bad BOM body, malformed
        /// sequences). The text was recovered via a byte-preserving fallback or
        /// replacement characters — the caller must warn before any save.
        var hadDecodingErrors: Bool
        /// NUL/control-density heuristic: probably not a text file at all.
        var looksBinary: Bool
    }

    /// Decodes file data with full diagnostics.
    /// Detection order: BOM sniffing, strict UTF-8, NUL-byte heuristic for
    /// BOM-less UTF-16, then ISO-8859-1 as the never-fails fallback.
    ///
    /// Failure semantics: when a BOM promises an encoding the bytes then break,
    /// the payload is decoded as ISO-8859-1 (a bijective byte↔char mapping, so
    /// an untouched buffer still round-trips the original bytes exactly) and
    /// `hadDecodingErrors` is set. Nothing is ever returned as an empty string
    /// because decoding failed.
    static func decode(_ data: Data) -> DecodedFile {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            if let s = String(data: body, encoding: .utf8) {
                return DecodedFile(text: s, encoding: .utf8bom,
                                   hadDecodingErrors: false, looksBinary: looksBinary(data))
            }
            return DecodedFile(text: String(decoding: body, as: UTF8.self), encoding: .utf8bom,
                               hadDecodingErrors: true, looksBinary: looksBinary(data))
        }
        if data.starts(with: [0xFF, 0xFE]) {
            // Foundation's UTF-16 decoder is lenient (odd-length bodies, lone
            // surrogates); requiring a byte-identical re-encode is what makes
            // "decoded cleanly" actually mean the save will round-trip.
            let body = data.dropFirst(2)
            if let s = String(data: body, encoding: .utf16LittleEndian),
               s.data(using: .utf16LittleEndian) == body {
                return DecodedFile(text: s, encoding: .utf16le,
                                   hadDecodingErrors: false, looksBinary: false)
            }
            return latin1Fallback(data, hadDecodingErrors: true)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            let body = data.dropFirst(2)
            if let s = String(data: body, encoding: .utf16BigEndian),
               s.data(using: .utf16BigEndian) == body {
                return DecodedFile(text: s, encoding: .utf16be,
                                   hadDecodingErrors: false, looksBinary: false)
            }
            return latin1Fallback(data, hadDecodingErrors: true)
        }
        // The NUL-parity heuristic must run BEFORE the strict-UTF-8 check:
        // BOM-less UTF-16 ASCII ("h\0e\0l\0…") is byte-valid UTF-8, so the
        // other order silently opened such files as NUL-riddled UTF-8 and the
        // next save rewrote them in the wrong encoding (P1-04-class).
        if data.count >= 4 {
            let sample = data.prefix(1024)
            var evenZeros = 0, oddZeros = 0
            for (i, b) in sample.enumerated() where b == 0 {
                if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let quarter = max(1, sample.count / 4)
            if oddZeros >= quarter, let s = String(data: data, encoding: .utf16LittleEndian),
               s.data(using: .utf16LittleEndian) == data {
                return DecodedFile(text: s, encoding: .utf16le,
                                   hadDecodingErrors: false, looksBinary: false)
            }
            if evenZeros >= quarter, let s = String(data: data, encoding: .utf16BigEndian),
               s.data(using: .utf16BigEndian) == data {
                return DecodedFile(text: s, encoding: .utf16be,
                                   hadDecodingErrors: false, looksBinary: false)
            }
        }
        if let s = String(data: data, encoding: .utf8) {
            return DecodedFile(text: s, encoding: .utf8,
                               hadDecodingErrors: false, looksBinary: looksBinary(data))
        }
        return latin1Fallback(data, hadDecodingErrors: false)
    }

    private static func latin1Fallback(_ data: Data, hadDecodingErrors: Bool) -> DecodedFile {
        DecodedFile(text: String(data: data, encoding: .isoLatin1) ?? "",
                    encoding: .latin1,
                    hadDecodingErrors: hadDecodingErrors,
                    looksBinary: looksBinary(data))
    }

    /// Text-vs-binary heuristic over the leading bytes: any NUL, or a dense run
    /// of non-whitespace C0 control bytes, reads as binary. Only meaningful for
    /// byte-oriented encodings — UTF-16 legitimately contains NULs.
    static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(8192)
        var controls = 0
        for byte in sample {
            if byte == 0 { return true }
            // Tab/LF/CR/FF and ESC (ANSI logs) are ordinary in text files.
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C, byte != 0x1B {
                controls += 1
            }
        }
        return controls * 10 > sample.count
    }

    /// Exact encoding or nil — this layer is never silently lossy (P1-04).
    /// The BOM is prepended where the encoding requires one; the LE/BE
    /// Foundation encodings do not emit a BOM on their own.
    func encodeExact(_ string: String) -> Data? {
        switch self {
        case .utf8:
            return Data(string.utf8)
        case .utf8bom:
            return Data([0xEF, 0xBB, 0xBF]) + Data(string.utf8)
        case .utf16le:
            guard let body = string.data(using: .utf16LittleEndian) else { return nil }
            return Data([0xFF, 0xFE]) + body
        case .utf16be:
            guard let body = string.data(using: .utf16BigEndian) else { return nil }
            return Data([0xFE, 0xFF]) + body
        case .latin1:
            return string.data(using: .isoLatin1, allowLossyConversion: false)
        }
    }

    /// Lossy fallback for when the user has explicitly confirmed the
    /// substitution of unmappable characters.
    func encodeLossy(_ string: String) -> Data {
        switch self {
        case .latin1:
            return string.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(string.utf8)
        default:
            return encodeExact(string) ?? Data(string.utf8)
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

// MARK: - Semantic version comparison

/// Three-component numeric comparison for release tags. Foundation-only for
/// the standalone battery.
enum SemVer {
    /// Parses "v2.1.0", "2.1", "2.1.0-beta+5" → [2,1,0] (missing components
    /// are 0; prerelease/build suffixes ignored). Nil if the first component
    /// isn't numeric.
    static func parse(_ tag: String) -> [Int]? {
        var s = Substring(tag)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let core = s.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let major = Int(first) else { return nil }
        var out = [major]
        for p in parts.dropFirst().prefix(2) { out.append(Int(p) ?? 0) }
        while out.count < 3 { out.append(0) }
        return out
    }

    /// True only when `remote` is strictly newer than `local`; unparsable
    /// input is never "newer".
    static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let r = parse(remote), let l = parse(local) else { return false }
        for (a, b) in zip(r, l) where a != b { return a > b }
        return false
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
