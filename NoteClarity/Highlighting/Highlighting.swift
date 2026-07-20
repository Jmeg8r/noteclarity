import Foundation

struct HighlightSpan {
    let range: NSRange
    let token: TokenType
}

/// The highlighting contract. Implementations must be pure value computations so
/// they can run off the main thread; results are applied to the text storage on main.
/// A tree-sitter-backed implementation can be swapped in later behind this same
/// protocol without touching the editor.
protocol SyntaxHighlighter {
    var language: Language { get }
    /// Returns colored spans for the full text. Ranges are UTF-16 (NSString) ranges.
    /// Spans are applied in array order: later spans win where they overlap.
    func highlight(_ text: String) -> [HighlightSpan]
}

struct TokenRule {
    let regex: NSRegularExpression
    let group: Int
    let token: TokenType

    init?(_ pattern: String, _ token: TokenType, group: Int = 0) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            assertionFailure("Bad highlight pattern: \(pattern)")
            return nil
        }
        self.regex = re
        self.group = group
        self.token = token
    }
}

/// Rule/regex tokenizer.
///
/// Two-phase model:
/// 1. *Exclusions* — strings and comments — are matched in a single combined
///    alternation so leftmost-match semantics resolve nesting correctly
///    (a quote inside a comment stays a comment, `//` inside a string stays a string).
///    Exclusion matches become spans and "zones".
/// 2. *Rules* — keywords, numbers, types, etc. — only match outside those zones.
struct RegexHighlighter: SyntaxHighlighter {
    let language: Language
    private let exclusionRegex: NSRegularExpression?
    private let exclusionTokens: [TokenType]
    private let exclusionsAreZones: Bool
    private let rules: [TokenRule]

    /// `exclusions` patterns must not contain capture groups (each alternative is
    /// wrapped in one group for classification). `zoned: false` keeps the matches
    /// as spans but lets rules also match inside them (used by JSON key strings).
    init(language: Language, exclusions: [(String, TokenType)], rules: [TokenRule?], zoned: Bool = true) {
        self.language = language
        if exclusions.isEmpty {
            exclusionRegex = nil
            exclusionTokens = []
        } else {
            let pattern = exclusions.map { "(\($0.0))" }.joined(separator: "|")
            exclusionRegex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            exclusionTokens = exclusions.map(\.1)
        }
        exclusionsAreZones = zoned
        self.rules = rules.compactMap { $0 }
    }

    func highlight(_ text: String) -> [HighlightSpan] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }
        var spans: [HighlightSpan] = []
        var zones: [NSRange] = []

        if let ex = exclusionRegex {
            ex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                for gi in 1...exclusionTokens.count {
                    let gr = match.range(at: gi)
                    if gr.location != NSNotFound && gr.length > 0 {
                        spans.append(HighlightSpan(range: gr, token: exclusionTokens[gi - 1]))
                        if exclusionsAreZones { zones.append(gr) }
                        break
                    }
                }
            }
        }

        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let r = match.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0, !Self.intersects(r, zones) else { return }
                spans.append(HighlightSpan(range: r, token: rule.token))
            }
        }
        return spans
    }

    /// Zones arrive in ascending order (regex scans left to right), so binary search.
    static func intersects(_ r: NSRange, _ zones: [NSRange]) -> Bool {
        var lo = 0, hi = zones.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let z = zones[mid]
            if z.location + z.length <= r.location {
                lo = mid + 1
            } else if r.location + r.length <= z.location {
                hi = mid - 1
            } else {
                return true
            }
        }
        return false
    }
}

enum HighlighterRegistry {
    private static let highlighters: [Language: any SyntaxHighlighter] = {
        var map = [Language: any SyntaxHighlighter]()
        for h in LanguageRules.makeHighlighters() { map[h.language] = h }
        return map
    }()

    static func highlighter(for language: Language) -> any SyntaxHighlighter {
        highlighters[language] ?? RegexHighlighter(language: .plaintext, exclusions: [], rules: [])
    }
}
