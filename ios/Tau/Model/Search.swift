import Foundation

/// A query's words as the server compiled them (server/src/search/match.ts), so a chat can mark them in its messages by
/// the same rules: each term is one word or a phrase of words, the last of which may begin a longer word, or a word
/// one typo away.
struct SearchTerm: Equatable {
    var tokens: [String]
    var prefix: Bool
    var variants: [String]
}

/// One conversation's best match: an excerpt of a message, with the matched words.
struct SearchMatch: Equatable {
    enum Kind: String {
        case user
        case assistant
        case reasoning
        case title
    }

    var conversationId: Int
    /// The message's entry; nil when the title matched.
    var entryId: Int?
    var kind: Kind
    var text: String
    /// The matched words in `text`, in UTF-16.
    var ranges: [NSRange]
    var date: Date
    /// The excerpt was cut before or after.
    var before: Bool
    var after: Bool
    /// Parts of the conversation matching every word.
    var matches: Int
    var score: Double
}

struct SearchPage: Equatable {
    var matches: [SearchMatch]
    /// More may come after these, for the next page.
    var hasMore: Bool
    var terms: [SearchTerm]
}

/// A message a chat opens at, found by search, with the words to mark in it.
struct ChatFocus: Equatable {
    var entryId: Int
    var kind: SearchMatch.Kind = .assistant
    var terms: [SearchTerm]
}

/// A chat's own search: its matching messages, newest first.
struct ChatSearchResult: Equatable {
    var entryIds: [Int]
    var terms: [SearchTerm]
}

enum SearchText {
    /// Where the terms match in `text`: words compared as the server compares them (lowercased, without diacritics),
    /// phrases as consecutive words; CJK characters as a substring.
    static func ranges(in text: String, terms: [SearchTerm]) -> [NSRange] {
        let string = text as NSString
        var words: [(text: String, range: NSRange)] = []
        var index = 0
        let length = string.length
        let letters = CharacterSet.alphanumerics
        while index < length {
            let char = string.character(at: index)
            if let scalar = UnicodeScalar(char), letters.contains(scalar), !isCJK(scalar) {
                var end = index + 1
                while end < length, let next = UnicodeScalar(string.character(at: end)), letters.contains(next), !isCJK(next) {
                    end += 1
                }
                let range = NSRange(location: index, length: end - index)
                words.append((normalize(string.substring(with: range)), range))
                index = end
            } else {
                index += 1
            }
        }
        var result: [NSRange] = []
        for term in terms {
            guard let first = term.tokens.first else {
                continue
            }
            if term.tokens.allSatisfy({ $0.unicodeScalars.allSatisfy(isCJK) }) {
                // CJK: the characters in a row.
                let needle = term.tokens.joined()
                var search = NSRange(location: 0, length: length)
                while true {
                    let found = string.range(of: needle, options: [.caseInsensitive], range: search)
                    if found.location == NSNotFound {
                        break
                    }
                    result.append(found)
                    search = NSRange(location: found.location + found.length, length: length - found.location - found.length)
                }
                continue
            }
            if term.tokens.count == 1 {
                for word in words where word.text == first || term.variants.contains(word.text) || (term.prefix && word.text.hasPrefix(first)) {
                    let matched = term.prefix && word.text != first && !term.variants.contains(word.text) ? NSRange(location: word.range.location, length: min(word.range.length, (first as NSString).length)) : word.range
                    result.append(matched)
                }
                continue
            }
            guard words.count >= term.tokens.count else {
                continue
            }
            for start in 0 ... (words.count - term.tokens.count) {
                var ok = true
                for (k, token) in term.tokens.enumerated() {
                    let word = words[start + k].text
                    let isLast = k == term.tokens.count - 1
                    if !(word == token || (isLast && term.prefix && word.hasPrefix(token))) {
                        ok = false
                        break
                    }
                }
                if ok {
                    let lower = words[start].range.location
                    let upper = words[start + term.tokens.count - 1].range.upperBound
                    result.append(NSRange(location: lower, length: upper - lower))
                }
            }
        }
        return result.sorted { $0.location < $1.location }
    }

    private static func normalize(_ word: String) -> String {
        return word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FFFF:
            return true
        default:
            return false
        }
    }
}
