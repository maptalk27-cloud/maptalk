import Foundation

/// A caption is authored text, never a generated media or visibility label.
enum PostCaption {
    static func visibleText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
