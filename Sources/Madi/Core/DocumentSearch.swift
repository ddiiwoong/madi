import Foundation

/// Document search: case-insensitive, non-overlapping substring matching over
/// the whole source, with the two size guards a long document needs.
///
/// Modelled on how Mark.app behaves — plain substring, no regex, no fuzzy
/// matching, every hit highlighted at once rather than stepped through — but
/// written here from that behaviour, not from its code.
public struct DocumentSearch: Sendable {

    /// Above this length the query debounce is relaxed.
    public static let largeDocumentChars = 180_000
    /// Above this length a one-character query is ignored outright: it would
    /// match a sizeable fraction of the document and cost more than it tells.
    public static let bailoutDocumentChars = 250_000
    public static let debounce: TimeInterval = 0.080
    public static let debounceLarge: TimeInterval = 0.180
    public static let minQueryForHugeDocument = 2

    public init() {}

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func debounce(forDocumentLength length: Int) -> TimeInterval {
        length > largeDocumentChars ? debounceLarge : debounce
    }

    public static func shouldSearch(documentLength: Int, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if documentLength > bailoutDocumentChars, query.count < minQueryForHugeDocument {
            return false
        }
        return true
    }

    /// Non-overlapping, case- and diacritic-insensitive matches.
    ///
    /// `NSString.range(of:options:range:)` is used rather than lowercasing both
    /// sides: lowercasing can change a string's LENGTH (Turkish `İ` becomes two
    /// code units), which slides every later index and puts the highlight on
    /// the wrong characters.
    public static func matches(in text: NSString, query rawQuery: String) -> [NSRange] {
        let query = normalize(rawQuery)
        guard shouldSearch(documentLength: text.length, query: query) else { return [] }

        var results: [NSRange] = []
        var searchStart = 0
        while searchStart < text.length {
            let remaining = NSRange(location: searchStart, length: text.length - searchStart)
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            results.append(found)
            searchStart = NSMaxRange(found)
        }
        return results
    }

    /// Index of the first match at or after `location`, for next/previous.
    public static func index(ofMatchAtOrAfter location: Int, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let found = matches.firstIndex(where: { $0.location >= location }) { return found }
        return 0
    }
}
