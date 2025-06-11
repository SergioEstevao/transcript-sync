import AVKit

import Speech
import SwiftSubtitles
import NaturalLanguage

class TranscriptSyncModel: ObservableObject {

    struct TimedWord {
        let timeRange: ClosedRange<Double>
        let characterRange: NSRange
    }

    enum Constants {
        static let wordsNeededForMatch = 4
        static let offsetThreadshold: TimeInterval = 5
    }

    @Published var originalTranscript: NSAttributedString = NSAttributedString("Hello")
    @Published var generatedTranscript: String = "Hello"
    @Published var player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 1

    @Published var timedWords: [TimedWord] = []

    @Published var scrollRange: NSRange = NSRange(location: NSNotFound, length: 0)

    private var timeObserverToken: Any?

    let audioURL: URL
    let transcriptURL: URL
    var transcriptModel: TranscriptModel?
    var tokenModel: TranscriptModel?

    let audioQueue = DispatchQueue(label: "audioQueue")
    let transcriptQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(audioURL: URL, transcriptURL: URL) {
        self.audioURL = audioURL
        self.transcriptURL = transcriptURL
    }

    convenience init?(audioString: String, transcriptString: String) {
        guard let audioURL = Bundle.main.url(forResource: audioString, withExtension: nil),
              let transcriptURL = Bundle.main.url(forResource: transcriptString, withExtension: nil)
        else { return nil }
        self.init(audioURL: audioURL, transcriptURL: transcriptURL)
    }

    func load() async -> Void {
        if let transcriptModel = TranscriptModel.makeModel(from: transcriptURL) {
            self.transcriptModel = transcriptModel
            await MainActor.run {
                originalTranscript = styleText(transcript: transcriptModel, highlightRange: nil)
            }
        }
        if let tokenModel = TranscriptModel.makeTokenizedModel(from: transcriptURL) {
            self.tokenModel = tokenModel
        }

        await self.loadAudio()
    }

    func setupAudioPlay() async {
        self.player.replaceCurrentItem(with: AVPlayerItem(url: self.audioURL))

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        // Observe duration
        if let currentItem = player.currentItem {
            let value = (try? await currentItem.asset.load(.duration).seconds) ?? 0.0
            await MainActor.run {
                duration = value
                self.player.play()
            }
        }
        //return
        // Add periodic time observer
        let interval = CMTime(seconds: 0.5,
                              preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: audioQueue) { [weak self] time in
            guard let self,
                  let transcriptModel = self.transcriptModel
            else { return }

            let currentTime = time.seconds

            guard let wordMatch = self.timedWords.first(where: { $0.timeRange.contains(currentTime) }) else { return }

            let newText = styleText(transcript: transcriptModel, highlightRange: wordMatch.characterRange)

            DispatchQueue.main.async {
                self.currentTime = currentTime
                self.originalTranscript = newText
                self.scrollRange = wordMatch.characterRange
            }
        }
    }

    func loadAudio() async {
        allSegments.removeAll()
        offsets.removeAll()

        await setupAudioPlay()

        let sequence = try! await setupSpeechAnalysis(from: player)

        do {
            for try await case let result in sequence {
                let text = result.text
                var locale = Locale(identifier: ("en-us"))
                handleRecognitionResult(result, locale: locale)
            }
        } catch let error {
            print("Error during speech analysis: \(error)")
        }
    }

    private var allSegments: [SpeechTranscriber.Result] = []

    struct Offset {
        let offset: TimeInterval
        let start: TimeInterval
        let end: TimeInterval

        var debugdescription: String {
            return "\(offset): \(start) - \(end)"
        }
    }
    private var offsets: [Offset] = []

    var speechRecognizedText = "" {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else  { return }
                generatedTranscript = speechRecognizedText
            }
        }
    }
    let wordCount = Constants.wordsNeededForMatch
    var currentPosition = 0
    var segmentsPosition = 0

    func setupSpeechRecognition() {
        var localeToUse = Locale(identifier: ("en-us"))
        if let text = transcriptModel?.attributedText.string,
           let nlLanguage = NLLanguageRecognizer.dominantLanguage(for: text) {
            localeToUse = Locale(identifier: nlLanguage.rawValue)
        }

        guard let recognizer = SFSpeechRecognizer(locale: localeToUse),
              recognizer.isAvailable
        else {
            return
        }
        recognizer.queue = transcriptQueue
        recognizer.defaultTaskHint = .dictation
        // Create and execute a speech recognition request for the audio file at the URL.
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.shouldReportPartialResults = !recognizer.supportsOnDeviceRecognition

        let startDate = Date.now
        recognizer.recognitionTask(with: request) { [weak self](result, error) in
            guard let self, let result else {
                if let error = error {
                    print(error)
                }
                return
            }
//            handleRecognitionResult(result, locale: localeToUse)
            if result.isFinal {
                print("Finished: \(startDate.timeIntervalSinceNow)s")
            }
        }
    }

    func setupSpeechAnalysis() async throws -> any AsyncSequence<SpeechTranscriber.Result, any Error> {
        let locale = Locale(identifier: "en-us")
//        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.frequentFinalization], attributeOptions: [.audioTimeRange])
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedLiveCaptioning)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile = try AVAudioFile(forReading: audioURL)

        Task.detached(priority: .userInitiated) {
            let start = Date.now
            print("Start Speech Transcription: \(start)")

            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                print("Analysis failed: \(error)")
            }

            print("End Speech Transcription: \(Date.now) - duration: \(start.timeIntervalSinceNow)")
        }

        return transcriber.results
    }

    func setupSpeechAnalysis(from player: AVPlayer) async throws -> some AsyncSequence<SpeechTranscriber.Result, any Error> {
        let locale = Locale(identifier: "en-us")
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedLiveCaptioning)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // AsyncStream to feed data
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Start analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // Extract audio track from the current item
        guard let currentItem = player.currentItem,
              let assetTrack = try await currentItem.asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "SpeechAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        // Create AVAssetReader to tap into the audio data
        let reader = try await AVAssetReader(asset: currentItem.asset)
        let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format?.sampleRate,
            AVNumberOfChannelsKey: format?.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        reader.startReading()

        Task.detached(priority: .userInitiated) {
            let start = Date.now
            print("Start Buffer Speech Transcription: \(start)")

            defer {
                Task {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                print("End Buffer Speech Transcription: \(Date.now) - duration: \(-start.timeIntervalSinceNow)")
            }

            while reader.status == .reading,
                  let sampleBuffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {

                var lengthAtOffset = 0
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
                      let baseAddress = dataPointer else { continue }

                let data = Data(bytes: baseAddress, count: totalLength)

                guard let pcmBuffer = data.toPCMBuffer(format: format!) else { continue }

                let input = AnalyzerInput(buffer: pcmBuffer)
                inputContinuation.yield(input)
            }

            inputContinuation.finish()
        }

        return transcriber.results
    }

    private(set) var syncOffset: Double? = nil
    private(set) var syncStartTime: TimeInterval? = nil

    func handleRecognitionResult(_ result: SpeechTranscriber.Result, locale: Locale) {
        guard let transcriptModel = self.transcriptModel else { return }

        processRuns(transcriptModel: transcriptModel, result: result, locale: locale)

//        let transcription = result.bestTranscription
        let transcription = result
        // Only when metadata is available this partial transcript is established
//        if let metadata = result.speechRecognitionMetadata {
//            //print("\(metadata.speechStartTimestamp): \(transcription.formattedString)")
//            speechRecognizedText += "\n" + transcription.formattedString
//        }
        speechRecognizedText += "\n" + String(transcription.text.characters[...])
        if result.range.start > .zero && result.range.duration > .zero {
            allSegments.append(result)
        }
//        allSegments.append(contentsOf: transcription.segments.filter({ segment in
//            return segment.timestamp > 0 && segment.duration > 0
//        }))
        // Do we have enough recognized words to try to do a search?
        guard allSegments.count > 0, allSegments.count >= wordCount else {
            return
        }

        let referenceTranscriptText = (transcriptModel.attributedText.string as? NSString) ?? NSString()

        let segment = result
        let recognizedText = String(segment.text.characters[...]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
        let recognizedWords = recognizedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        guard recognizedWords.count >= wordCount else { return }

        let reference = (transcriptModel.attributedText.string as? NSString) ?? NSString()

        // Slide a window of N words over the recognizedWords
        for i in 0..<(recognizedWords.count - wordCount) {
            let wordToSearch = recognizedWords[i..<(i+wordCount)].joined(separator: " ")

            let range = reference.range(
                of: wordToSearch,
                options: [.diacriticInsensitive, .caseInsensitive],
                range: NSRange(location: currentPosition, length: reference.length - currentPosition)
            )

            guard range.location != NSNotFound,
                  let cue = transcriptModel.cues.first(where: { $0.characterRange.intersection(range) != nil }) else {
                continue
            }

            // Approximate offset using the start of the cue
            let calculatedOffset = cue.startTime - segment.range.start.seconds

            // Store if first match or if delta is large
            if self.offsets.isEmpty {
                self.offsets.append(Offset(offset: calculatedOffset, start: 0, end: cue.endTime))
                if self.syncOffset == nil {
                    self.syncOffset = calculatedOffset
                    self.syncStartTime = segment.range.start.seconds
                    print("🟢 Sync established with offset: \(calculatedOffset)s at cue start: \(segment.range.start.seconds)")
                }
            } else if let last = self.offsets.last,
                      abs(last.offset - calculatedOffset) > Constants.offsetThreadshold {
                self.offsets.append(Offset(offset: calculatedOffset, start: cue.startTime, end: cue.endTime))
            } else {
                if let last = self.offsets.popLast() {
                    self.offsets.append(Offset(offset: last.offset, start: last.start, end: cue.endTime))
                }
            }

//            print("Matched `\(wordToSearch)` at \(segment.range.start.seconds) → cue: \(cue.startTime)")
            break // exit loop on first match
        }

        if result.isFinal, let offset = self.offsets.popLast() {
            self.offsets.append(Offset(offset:  offset.offset, start: offset.start, end: result.range.start.seconds + result.range.duration.seconds))
//            printOfssets()
        }
    }

    func processRuns(transcriptModel: TranscriptModel, result: SpeechTranscriber.Result, locale: Locale) {
        let maxCharDistance = 200 // limit how far forward a word match can appear
        var searchStartLocation = 0
        let referenceText = transcriptModel.attributedText.string
        let referenceNSString = referenceText as NSString
        let fullLength = referenceNSString.length
        var lastMatchedRange: NSRange? = nil
        var usedRanges: Set<NSRange> = []

        for run in result.text.runs {
            guard let audioTimeRange = run.audioTimeRange, let syncOffset = self.syncOffset else {
                continue // skip until synced
            }

            let timeRange = audioTimeRange.start.seconds...audioTimeRange.end.seconds

            let adjustedTime = run.audioTimeRange!.start.seconds + syncOffset

            guard let cue = transcriptModel.cues.first(where: { cue in
                cue.startTime <= adjustedTime && adjustedTime <= cue.endTime
            }) else {
                continue // we’re not aligned here, skip word
            }

            let word = String(result.text.characters[run.range])
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))

            guard !word.isEmpty else { continue }

            let cueString = (transcriptModel.attributedText.string as NSString).substring(with: cue.characterRange)
            let wordRangeInCue = (cueString as NSString).range(
                of: word,
                options: [.diacriticInsensitive, .caseInsensitive]
            )

            guard wordRangeInCue.location != NSNotFound else {
                print("Missing word: `\(word)` at time: \(timeRange)")
                continue
            }

            let fullWordRange = NSRange(
                location: cue.characterRange.location + wordRangeInCue.location,
                length: wordRangeInCue.length
            )

            print("Appended word: `\(word)` at time: \(timeRange) with range: \(fullWordRange)")
            timedWords.append(TimedWord(timeRange: timeRange, characterRange: fullWordRange))
        }
    }

    func indexOf(_ toSearch: [String], inside other: [String]) -> Int? {
        var i = 0
        while i < other.count {
            var j = 0
            var match = true
            while j < toSearch.count  && i+j < other.count {
                match = match && (other[i+j] == toSearch[j])
                j += 1
            }
            if match {
                return i
            }
            i += 1
        }
        return nil
    }

    func printOfssets() {
        print("-----> Offsets Start <------")
        offsets.forEach {
            print($0)
        }
        print("-----> Offsets End <------\n")
    }

    var previousRange: NSRange?

//    private func styleText(transcript: TranscriptModel, position: Double = -1) -> NSAttributedString {
//        let formattedText = NSMutableAttributedString(attributedString: transcript.attributedText)
//        formattedText.beginEditing()
//        let normalStyle = makeStyle()
//        var highlightStyle = normalStyle
//        highlightStyle[.foregroundColor] = UIColor.red
//
//        let fullLength = NSRange(location: 0, length: formattedText.length)
//        formattedText.addAttributes(normalStyle, range: fullLength)
//
//        if position > 0, let range = transcript.firstCue(containing: position)?.characterRange ?? previousRange {
//            previousRange = range
//            formattedText.addAttributes(highlightStyle, range: range)
//        }
//
//        let speakerFont = UIFont.preferredFont(forTextStyle: .footnote)
//        formattedText.enumerateAttribute(.transcriptSpeaker, in: fullLength, options: [.reverse, .longestEffectiveRangeNotRequired]) { value, range, _ in
//            if value == nil {
//                return
//            }
//            formattedText.addAttribute(.font, value: speakerFont, range: range)
//        }
//
//        formattedText.endEditing()
//        return formattedText
//    }
    private func styleText(transcript: TranscriptModel, highlightRange: NSRange?) -> NSAttributedString {
        let formattedText = NSMutableAttributedString(attributedString: transcript.attributedText)
        formattedText.beginEditing()

        let normalStyle = makeStyle()
        var highlightStyle = normalStyle
        highlightStyle[.foregroundColor] = UIColor.red

        let fullLength = NSRange(location: 0, length: formattedText.length)
        formattedText.addAttributes(normalStyle, range: fullLength)

        if let range = highlightRange {
            formattedText.addAttributes(highlightStyle, range: range)
            previousRange = range
        }

        formattedText.endEditing()
        return formattedText
    }

    private func makeStyle(alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.2
        paragraphStyle.paragraphSpacing = 10
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = alignment

        var standardFont = UIFont.preferredFont(forTextStyle: .body)

        if let descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: .body)
            .withDesign(.serif) {
            standardFont =  UIFont(descriptor: descriptor, size: 0)
        }


        let normalStyle: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraphStyle,
            .font: standardFont,
            .foregroundColor: UIColor.label
        ]

        return normalStyle
    }
}

extension SpeechTranscriber.Result {
    var substring: String {
        String(text.characters[...])
    }
}

extension Data {
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameLength = UInt32(self.count) / format.streamDescription.pointee.mBytesPerFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        buffer.frameLength = frameLength

        let channels = UnsafeBufferPointer(start: buffer.int16ChannelData, count: Int(format.channelCount))
        self.withUnsafeBytes { rawBufferPointer in
            for channel in 0..<Int(format.channelCount) {
                memcpy(channels[channel], rawBufferPointer.baseAddress! + channel * Int(format.streamDescription.pointee.mBytesPerFrame), Int(self.count) / Int(format.channelCount))
            }
        }

        return buffer
    }
}
