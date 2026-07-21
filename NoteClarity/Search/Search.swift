import Foundation
import AppKit

struct SearchOptions {
    var useRegex = false
    var caseSensitive = false
    var wholeWord = false
    var inSelection = false
}

final class FindState: ObservableObject {
    @Published var query = "" { didSet { lastZeroLengthMatchLocation = nil } }
    @Published var replacement = ""
    @Published var options = SearchOptions() { didSet { lastZeroLengthMatchLocation = nil } }
    @Published var message = ""
    /// Captured when "in selection" is enabled; kept in sync across replace-all.
    var scopeRange: NSRange?
    /// Location of the zero-length match Find Next selected last time. Anchors
    /// and lookarounds (`^`, `$`, `\b`, …) leave the caret exactly on their
    /// match, which would re-match forever without this breadcrumb (P2-06).
    var lastZeroLengthMatchLocation: Int?
}

enum SearchEngine {
    static func regex(for query: String, options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = #"(?<!\w)(?:"# + pattern + #")(?!\w)"#
        }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    /// Pure next/previous-match selection over precomputed match ranges, with
    /// wrap-around. `afterZeroLengthAt` is where the caller last selected a
    /// zero-length match; forward search steps at least one composed character
    /// past it (never splitting a surrogate pair) instead of re-matching.
    static func nextMatch(in matches: [NSRange], caret: NSRange, backwards: Bool,
                          afterZeroLengthAt: Int?, text: NSString) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        if backwards {
            return matches.last { $0.location < caret.location } ?? matches.last!
        }
        var from = caret.location
        if caret.length > 0 {
            from += 1
        } else if let zero = afterZeroLengthAt, zero == caret.location {
            guard from < text.length else { return matches.first }   // wrap from EOF
            from = NSMaxRange(text.rangeOfComposedCharacterSequence(at: from))
        }
        return matches.first { $0.location >= from } ?? matches.first!
    }
}

extension AppState {

    private func searchScope(in controller: EditorController) -> NSRange {
        let full = NSRange(location: 0, length: controller.utf16Length)
        guard findState.options.inSelection, let scope = findState.scopeRange else { return full }
        return NSIntersectionRange(scope, full)
    }

    private func allMatches() -> (regex: NSRegularExpression, matches: [NSTextCheckingResult], scope: NSRange)? {
        guard let c = activeController, !findState.query.isEmpty else { return nil }
        do {
            let regex = try SearchEngine.regex(for: findState.query, options: findState.options)
            let scope = searchScope(in: c)
            let matches = regex.matches(in: c.text, options: [], range: scope)
                .filter { $0.range.length > 0 || findState.options.useRegex }
            return (regex, matches, scope)
        } catch {
            findState.message = "Invalid pattern"
            return nil
        }
    }

    func setFindInSelection(_ on: Bool) {
        if on {
            guard let c = activeController, c.textView.selectedRange().length > 0 else {
                findState.options.inSelection = false
                findState.message = "Select text first"
                return
            }
            findState.scopeRange = c.textView.selectedRange()
            findState.options.inSelection = true
        } else {
            findState.scopeRange = nil
            findState.options.inSelection = false
        }
    }

    func findNext(backwards: Bool = false) {
        guard let c = activeController else { return }
        guard let (_, matches, _) = allMatches() else { return }
        guard !matches.isEmpty else {
            findState.message = "No matches"
            return
        }
        let caret = c.textView.selectedRange()
        guard let target = SearchEngine.nextMatch(in: matches.map(\.range),
                                                  caret: caret,
                                                  backwards: backwards,
                                                  afterZeroLengthAt: findState.lastZeroLengthMatchLocation,
                                                  text: c.text as NSString) else { return }
        findState.lastZeroLengthMatchLocation = target.length == 0 ? target.location : nil
        c.jump(to: target.location, length: target.length)
        let index = matches.firstIndex { $0.range == target } ?? 0
        findState.message = "\(index + 1) of \(matches.count)"
    }

    /// Selects every match at once (NSTextView multi-selection) and reports the count.
    func findAll() {
        guard let c = activeController else { return }
        guard let (_, matches, _) = allMatches() else { return }
        guard !matches.isEmpty else {
            findState.message = "No matches"
            return
        }
        c.textView.selectedRanges = matches.map { NSValue(range: $0.range) }
        c.textView.scrollRangeToVisible(matches[0].range)
        c.textView.window?.makeFirstResponder(c.textView)
        findState.message = "\(matches.count) match\(matches.count == 1 ? "" : "es") selected"
    }

    func replaceCurrent() {
        guard let c = activeController else { return }
        guard let (regex, matches, _) = allMatches() else { return }
        let sel = c.textView.selectedRange()
        if let m = matches.first(where: { $0.range == sel }) {
            let replacement = replacementText(for: m, regex: regex, in: c.text)
            c.replaceRangeUndoable(m.range, with: replacement)
            c.jump(to: m.range.location + (replacement as NSString).length)
        }
        findNext()
    }

    func replaceAll() {
        guard let c = activeController else { return }
        guard let (regex, matches, scope) = allMatches() else { return }
        guard !matches.isEmpty else {
            findState.message = "No matches"
            return
        }
        let ns = c.text as NSString
        var result = ""
        var cursor = scope.location
        for m in matches {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            result += replacementText(for: m, regex: regex, in: c.text)
            cursor = NSMaxRange(m.range)
        }
        result += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(scope) - cursor))
        c.replaceRangeUndoable(scope, with: result)
        if findState.options.inSelection {
            findState.scopeRange = NSRange(location: scope.location, length: (result as NSString).length)
        }
        findState.message = "Replaced \(matches.count)"
    }

    private func replacementText(for match: NSTextCheckingResult,
                                 regex: NSRegularExpression,
                                 in text: String) -> String {
        guard findState.options.useRegex else { return findState.replacement }
        // Template form supports $1…$n capture references.
        return regex.replacementString(for: match, in: text, offset: 0, template: findState.replacement)
    }
}
