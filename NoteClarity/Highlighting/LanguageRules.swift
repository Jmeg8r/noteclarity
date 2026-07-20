import Foundation

/// Token rules + Function List symbol rules for every built-in language.
/// Patterns use raw strings so regex escapes read literally.
enum LanguageRules {

    // MARK: Highlighter definitions

    static func makeHighlighters() -> [any SyntaxHighlighter] {
        var list: [any SyntaxHighlighter] = []

        list.append(RegexHighlighter(language: .plaintext, exclusions: [], rules: []))

        // JSON: key strings vs value strings distinguished by a lookahead for ":".
        // Exclusions are non-zoned spans here; numbers/keywords can't occur inside
        // strings anyway because the string alternation consumes them first? No —
        // rules run over the whole text, so keep strings zoned and classify keys
        // in the exclusion alternation itself (leftmost alternative wins).
        list.append(RegexHighlighter(
            language: .json,
            exclusions: [
                (#""(?:[^"\\]|\\.)*"(?=\s*:)"#, .key),
                (#""(?:[^"\\]|\\.)*""#, .string),
            ],
            rules: [
                TokenRule(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number),
                TokenRule(#"\b(?:true|false|null)\b"#, .keyword),
            ]))

        list.append(RegexHighlighter(
            language: .markdown,
            exclusions: [
                (#"```[\s\S]*?(?:```|\z)"#, .string),
                (#"`[^`\n]+`"#, .string),
            ],
            rules: [
                TokenRule(#"^#{1,6}[ \t][^\n]*"#, .keyword),
                TokenRule(#"^[ \t]*>[^\n]*"#, .comment),
                TokenRule(#"^(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, .comment),
                TokenRule(#"^[ \t]*(?:[-*+]|\d+\.)[ \t]"#, .number),
                TokenRule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type),
                TokenRule(#"!?\[[^\]\n]*\]\([^)\n]*\)"#, .function),
            ]))

        let jsExclusions: [(String, TokenType)] = [
            (#"//[^\n]*"#, .comment),
            (#"/\*[\s\S]*?(?:\*/|\z)"#, .comment),
            (#"'(?:[^'\\\n]|\\.)*'"#, .string),
            (#""(?:[^"\\\n]|\\.)*""#, .string),
            (#"`(?:[^`\\]|\\[\s\S])*`"#, .string),
        ]
        let jsKeywords = #"\b(?:abstract|any|as|async|await|boolean|break|case|catch|class|const|continue|debugger|declare|default|delete|do|else|enum|export|extends|false|finally|for|from|function|get|if|implements|import|in|infer|instanceof|interface|is|keyof|let|namespace|never|new|null|number|object|of|private|protected|public|readonly|return|satisfies|set|static|string|super|switch|symbol|this|throw|true|try|type|typeof|undefined|unknown|var|void|while|with|yield)\b"#
        let jsRules: [TokenRule?] = [
            TokenRule(#"\b([A-Za-z_$][\w$]*)\s*\("#, .function, group: 1),
            TokenRule(#"\b[A-Z][\w$]*\b"#, .type),
            TokenRule(#"\b(?:0[xXbBoO][\da-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?n?)\b"#, .number),
            TokenRule(jsKeywords, .keyword),
            TokenRule(#"@[A-Za-z_$][\w$]*"#, .key),
        ]
        list.append(RegexHighlighter(language: .javascript, exclusions: jsExclusions, rules: jsRules))
        list.append(RegexHighlighter(language: .typescript, exclusions: jsExclusions, rules: jsRules))

        list.append(RegexHighlighter(
            language: .python,
            exclusions: [
                (#"#[^\n]*"#, .comment),
                (#"(?:[rRbBuUfF]{1,2})?'''[\s\S]*?(?:'''|\z)"#, .string),
                (#"(?:[rRbBuUfF]{1,2})?"""[\s\S]*?(?:"""|\z)"#, .string),
                (#"(?:[rRbBuUfF]{1,2})?'(?:[^'\\\n]|\\.)*'"#, .string),
                (#"(?:[rRbBuUfF]{1,2})?"(?:[^"\\\n]|\\.)*""#, .string),
            ],
            rules: [
                TokenRule(#"\b(?:def|class)\s+([A-Za-z_]\w*)"#, .function, group: 1),
                TokenRule(#"\b([A-Za-z_]\w*)\s*\("#, .function, group: 1),
                TokenRule(#"\b[A-Z]\w*\b"#, .type),
                TokenRule(#"\b(?:0[xXbBoO][\da-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?[jJ]?)\b"#, .number),
                TokenRule(#"\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|self|cls|try|while|with|yield)\b"#, .keyword),
                TokenRule(#"^\s*@[\w.]+"#, .key),
            ]))

        list.append(RegexHighlighter(
            language: .swift,
            exclusions: [
                (#"//[^\n]*"#, .comment),
                (#"/\*[\s\S]*?(?:\*/|\z)"#, .comment),
                (#""{3}[\s\S]*?(?:"{3}|\z)"#, .string),
                (#""(?:[^"\\\n]|\\.)*""#, .string),
            ],
            rules: [
                TokenRule(#"\b([A-Za-z_][\w]*)\s*\("#, .function, group: 1),
                TokenRule(#"\b[A-Z][\w]*\b"#, .type),
                TokenRule(#"\b(?:0[xXbBoO][\da-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b"#, .number),
                TokenRule(#"\b(?:actor|any|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|didSet|do|dynamic|else|enum|extension|fallthrough|false|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|lazy|let|mutating|nil|nonisolated|nonmutating|open|operator|optional|override|postfix|precedencegroup|prefix|private|protocol|public|repeat|required|rethrows|return|self|Self|set|some|static|struct|subscript|super|switch|throw|throws|true|try|typealias|unowned|var|weak|where|while|willSet)\b"#, .keyword),
                TokenRule(#"@\w+"#, .key),
                TokenRule(#"(?<![\w#])#\w+"#, .key),
            ]))

        let markupExclusions: [(String, TokenType)] = [
            (#"<!--[\s\S]*?(?:-->|\z)"#, .comment),
            (#"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"#, .string),
        ]
        let markupRules: [TokenRule?] = [
            TokenRule(#"</?[A-Za-z][-\w.:]*"#, .tag),
            TokenRule(#"/?>|\?>"#, .tag),
            TokenRule(#"<\?[A-Za-z-]*|<![A-Z]+"#, .keyword),
            TokenRule(#"&#?\w+;"#, .number),
            TokenRule(#"[A-Za-z_][-\w.:]*(?=\s*=\s*["'])"#, .key),
            TokenRule(#""[^"<>\n]*"|'[^'<>\n]*'"#, .string),
        ]
        list.append(RegexHighlighter(language: .xml, exclusions: markupExclusions, rules: markupRules))
        list.append(RegexHighlighter(language: .html, exclusions: markupExclusions, rules: markupRules))

        list.append(RegexHighlighter(
            language: .shell,
            exclusions: [
                (#"(?:^|\s)#[^\n]*"#, .comment),
                (#"'[^'\n]*'"#, .string),
                (#""(?:[^"\\\n]|\\.)*""#, .string),
            ],
            rules: [
                TokenRule(#"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[@#?$!*0-9-]"#, .key),
                TokenRule(#"\b(?:alias|bg|cd|declare|echo|eval|exec|exit|export|fg|hash|help|history|jobs|kill|let|local|popd|printf|pushd|pwd|read|readonly|set|shift|source|test|trap|type|umask|unalias|unset|wait)\b"#, .function),
                TokenRule(#"\b(?:break|case|continue|coproc|do|done|elif|else|esac|fi|for|function|if|in|return|select|then|time|until|while)\b"#, .keyword),
                TokenRule(#"\b\d+\b"#, .number),
            ]))

        return list
    }

    // MARK: Function List symbol extraction

    struct SymbolRule {
        let regex: NSRegularExpression
        let nameGroup: Int
        let kindGroup: Int?
        let fixedKind: SymbolKind

        init?(_ pattern: String, nameGroup: Int, kindGroup: Int? = nil, fixedKind: SymbolKind = .function) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                assertionFailure("Bad symbol pattern: \(pattern)")
                return nil
            }
            self.regex = re
            self.nameGroup = nameGroup
            self.kindGroup = kindGroup
            self.fixedKind = fixedKind
        }
    }

    /// Symbol rules are looked up by language, so adding Function List support for a
    /// new language is a single entry here.
    static func symbolRules(for language: Language) -> [SymbolRule] {
        let swiftModifiers = #"(?:@\w+(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|private|internal|fileprivate|open|final|static|class|override|convenience|required|mutating|nonisolated|dynamic|indirect|nonmutating|prefix|postfix|infix)[ \t]+)*"#
        switch language {
        case .swift:
            return [
                SymbolRule(#"^[ \t]*"# + swiftModifiers + #"(func|class|struct|enum|protocol|extension|actor|typealias)[ \t]+([A-Za-z_][\w.]*)"#, nameGroup: 2, kindGroup: 1),
                SymbolRule(#"^[ \t]*"# + swiftModifiers + #"(init[?]?)[ \t]*\("#, nameGroup: 1, fixedKind: .initializer),
            ].compactMap { $0 }
        case .python:
            return [
                SymbolRule(#"^[ \t]*(?:async[ \t]+)?(def|class)[ \t]+([A-Za-z_]\w*)"#, nameGroup: 2, kindGroup: 1),
            ].compactMap { $0 }
        case .javascript, .typescript:
            return [
                SymbolRule(#"^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?function[ \t*]+([A-Za-z_$][\w$]*)"#, nameGroup: 1, fixedKind: .function),
                SymbolRule(#"^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:abstract[ \t]+)?(class)[ \t]+([A-Za-z_$][\w$]*)"#, nameGroup: 2, kindGroup: 1),
                SymbolRule(#"^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:\([^)\n]*\)|[A-Za-z_$][\w$]*)[ \t]*=>"#, nameGroup: 1, fixedKind: .function),
                SymbolRule(#"^[ \t]+(?:(?:public|private|protected|static|readonly|async|get|set|override)[ \t]+)*([A-Za-z_$][\w$]*)[ \t]*\([^)\n]*\)[ \t]*(?::[^{;\n]*)?\{"#, nameGroup: 1, fixedKind: .method),
            ].compactMap { $0 }
        default:
            return []
        }
    }

    private static let symbolNameBlocklist: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "function", "else",
        "do", "try", "new", "typeof", "await", "yield", "constructor",
    ]

    static func extractSymbols(from text: String, language: Language) -> [Symbol] {
        let rules = symbolRules(for: language)
        guard !rules.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [Symbol] = []
        var seenOffsets = Set<Int>()

        // Line starts for offset→line mapping, computed locally so this runs off-main.
        var lineStarts: [Int] = [0]
        var search = full
        while true {
            let r = ns.range(of: "\n", options: [], range: search)
            if r.location == NSNotFound { break }
            lineStarts.append(r.location + 1)
            search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
        }

        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let nr = match.range(at: rule.nameGroup)
                guard nr.location != NSNotFound, nr.length > 0 else { return }
                let name = ns.substring(with: nr)
                if rule.fixedKind == .method && symbolNameBlocklist.contains(name) { return }
                guard !seenOffsets.contains(nr.location) else { return }
                seenOffsets.insert(nr.location)
                var kind = rule.fixedKind
                if let kg = rule.kindGroup {
                    let kr = match.range(at: kg)
                    if kr.location != NSNotFound {
                        kind = SymbolKind.from(keyword: ns.substring(with: kr))
                    }
                }
                var lo = 0, hi = lineStarts.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if lineStarts[mid] <= nr.location { lo = mid } else { hi = mid - 1 }
                }
                found.append(Symbol(name: name, kind: kind, offset: nr.location, length: nr.length, line: lo + 1))
            }
        }
        return found.sorted { $0.offset < $1.offset }
    }
}

enum SymbolKind: String {
    case function, method, initializer
    case classKind = "class"
    case structKind = "struct"
    case enumKind = "enum"
    case protocolKind = "protocol"
    case extensionKind = "extension"
    case typealiasKind = "typealias"

    static func from(keyword: String) -> SymbolKind {
        switch keyword {
        case "func", "def", "function": return .function
        case "class": return .classKind
        case "struct": return .structKind
        case "enum": return .enumKind
        case "protocol": return .protocolKind
        case "extension": return .extensionKind
        case "actor": return .classKind
        case "typealias": return .typealiasKind
        default: return keyword.hasPrefix("init") ? .initializer : .function
        }
    }

    var systemImage: String {
        switch self {
        case .function, .method, .initializer: return "function"
        case .classKind: return "cube"
        case .structKind: return "shippingbox"
        case .enumKind: return "list.number"
        case .protocolKind: return "puzzlepiece"
        case .extensionKind: return "plus.square.on.square"
        case .typealiasKind: return "equal.square"
        }
    }
}

struct Symbol: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let kind: SymbolKind
    let offset: Int
    let length: Int
    let line: Int
}
