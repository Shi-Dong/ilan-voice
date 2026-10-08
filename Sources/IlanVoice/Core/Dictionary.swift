import Foundation

/// The user's personal dictionary: names, jargon and acronyms that speech
/// recognition tends to get wrong. Stored one term per line in
/// `dictionary.txt`; lines starting with `#` are comments.
///
/// It grounds two things: the transcription model (as a prompt, plus
/// keywords for models that take them) and GPT-Realtime itself (as a
/// vocabulary list in its instructions), so both hear and spell the terms
/// the way the user does.
enum UserDictionary {
    static var file: URL { Paths.root.appendingPathComponent("dictionary.txt") }

    static let template = """
    # One word or phrase per line, spelled exactly the way you want it written.
    # Lines starting with # are ignored. For example:
    # Ilan
    # Kubernetes
    # SGLang
    """

    static func loadText() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? template
    }

    static func save(_ text: String) {
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes the list back, one term per line.
    static func save(terms: [String]) {
        save(terms.joined(separator: "\n") + (terms.isEmpty ? "" : "\n"))
    }

    /// Adds terms that aren't already there (case-insensitive), keeping the
    /// existing order. Returns how many were new.
    @discardableResult
    static func add(_ newTerms: [String]) -> Int {
        let current = terms()
        let merged = terms(from: (current + newTerms).joined(separator: "\n"))
        save(terms: merged)
        return merged.count - current.count
    }

    static func remove(_ term: String) {
        save(terms: terms().filter { $0.caseInsensitiveCompare(term) != .orderedSame })
    }

    /// Adds every line of a text file. Returns (new, total lines read).
    static func importFile(_ url: URL) throws -> (added: Int, read: Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = terms(from: text)
        return (add(lines), lines.count)
    }

    /// Clean terms: trimmed, no comments or blanks, no characters the
    /// Realtime API rejects in keywords (`<`, `>`), de-duplicated in order.
    static func terms(from text: String = loadText()) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Transcription prompts have a length limit; keep the hint well under it.
    static func transcriptionPrompt(_ terms: [String], maxCharacters: Int = 800) -> String? {
        guard !terms.isEmpty else { return nil }
        var prompt = "Vocabulary that may appear, with its exact spelling: "
        var added = 0
        for term in terms {
            let piece = (added == 0 ? "" : ", ") + term
            if prompt.count + piece.count > maxCharacters { break }
            prompt += piece
            added += 1
        }
        return prompt + "."
    }

    static func instructions(_ terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return """
        The user's personal dictionary. When something the user says sounds like one of these, \
        it is that term; use this exact spelling in your replies and tool calls: \
        \(terms.joined(separator: "; ")).
        """
    }
}
