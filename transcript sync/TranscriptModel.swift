import Foundation
import SwiftSubtitles
import NaturalLanguage

struct TranscriptCue: Sendable {
    let startTime: Double
    let endTime: Double
    let characterRange: NSRange

    @inlinable public func contains(timeInSeconds seconds: Double) -> Bool {
        seconds >= self.startTime && seconds <= self.endTime
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {

}

struct TranscriptModel: Sendable {

    let attributedText: NSAttributedString
    let cues: [TranscriptCue]
    let type: String
    let hasJavascript: Bool

    static func makeModel(from url: URL) -> TranscriptModel? {
        let subtitles: Subtitles? = {
            do {
                return try Subtitles(fileURL: url, encoding: .utf8)
            }
            catch {
                print("Transcripts Parsing:\(error)")
                return nil
            }
        }()
        guard let subtitles else {
            return nil
        }

        let resultText = NSMutableAttributedString()
        var cues = [TranscriptCue]()
        for cue in subtitles.cues {
            let text = cue.text

            let filteredText: String = ComposeFilter.transcriptFilter.filter(text)
            if filteredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let attributedText = NSAttributedString(string: filteredText)
            let startPosition = resultText.length
            let endPosition = attributedText.length
            let range = NSRange(location: startPosition, length: endPosition)
            resultText.append(attributedText)
            let entry = TranscriptCue(startTime: cue.startTimeInSeconds, endTime: cue.endTimeInSeconds, characterRange: range)
            cues.append(entry)
        }

        return TranscriptModel(attributedText: resultText, cues: cues, type: url.pathExtension, hasJavascript: false)
    }

    static func makeTokenizedModel(from url: URL) -> TranscriptModel? {
        let subtitles: Subtitles? = {
            do {
                return try Subtitles(fileURL: url, encoding: .utf8)
            }
            catch {
                print("Transcripts Parsing:\(error)")
                return nil
            }
        }()
        guard let subtitles else {
            return nil
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.english)
        let resultText = NSMutableAttributedString()
        var cues = [TranscriptCue]()
        for cue in subtitles.cues {
            let text = cue.text

            let filteredText: String = ComposeFilter.transcriptFilter.filter(text)
            if filteredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            var tokens: [String] = []
            tokenizer.string = filteredText
            tokenizer.enumerateTokens(in: filteredText.startIndex..<filteredText.endIndex) { tokenRange, _ in
                tokens.append(String(filteredText[tokenRange]))
                return true
            }
            tokens.append(" ")
            let attributedText = NSAttributedString(string: tokens.joined(separator: " "))
            let startPosition = resultText.length
            let endPosition = attributedText.length
            let range = NSRange(location: startPosition, length: endPosition)
            resultText.append(attributedText)
            let entry = TranscriptCue(startTime: cue.startTimeInSeconds, endTime: cue.endTimeInSeconds, characterRange: range)
            cues.append(entry)
        }

        return TranscriptModel(attributedText: resultText, cues: cues, type: url.pathExtension, hasJavascript: false)
    }

    @inlinable public func firstCue(containing secondsValue: Double) -> TranscriptCue? {
        self.cues.first { $0.contains(timeInSeconds: secondsValue) }
    }

    var isEmtpy: Bool {
        return attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func regexMatch(input: String, pattern: String, position: Int = 0) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            let range = NSRange(input.startIndex..., in: input)
            let results = regex.matches(in: input, range: range)
            if let result = results.first, result.range.location != NSNotFound, position <= result.numberOfRanges {
                if let range = Range(result.range(at: position), in: input) {
                    return String(input[range])
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

extension NSAttributedString.Key {

    static var transcriptSpeaker = NSAttributedString.Key("TranscriptSpeaker")
}
