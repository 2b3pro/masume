import Foundation

/// Empty languages asks Vision to detect the language. Words preserve spelling
/// and order: these are hints supplied by the person, not corrections to OCR.
public struct TextPreferences: Codable, Equatable, Sendable {
    public var languages: [String]
    public var customWords: [String]

    public init(languages: [String] = [], customWords: [String] = []) {
        self.languages = languages
        self.customWords = customWords
    }
}
