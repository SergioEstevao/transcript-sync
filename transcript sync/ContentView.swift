import SwiftUI
import Speech
import AVKit
import SwiftSubtitles

class TranscriptSyncModel: ObservableObject {

    enum Constants {
        static let wordsNeededForMatch = 4
        static let offsetThreadshold: TimeInterval = 5
    }

    @Published var originalTranscript: NSAttributedString = NSAttributedString("Hello")
    @Published var generatedTranscript: String = "Hello"
    @Published var player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    var offset: Double = 0
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
                originalTranscript = styleText(transcript: transcriptModel, position: -1)
            }
        }
        if let tokenModel = TranscriptModel.makeTokenizedModel(from: transcriptURL) {
            self.tokenModel = tokenModel
        }
        SFSpeechRecognizer.requestAuthorization { [weak self]status in
            guard let self, status == .authorized else {
                return
            }
            Task {
                await self.loadAudio()
            }
        }
    }

    func setupAudioPlay() async {
        self.player.replaceCurrentItem(with: AVPlayerItem(url: self.audioURL))

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
            let offsetDetected = offsets.first { offset in
                return time.seconds >= offset.start && time.seconds <= offset.end
            } ?? offsets.last
            let adjustedPosition = time.seconds + (offsetDetected?.offset ?? 0)
            let newText = styleText(transcript: transcriptModel, position: adjustedPosition)
            DispatchQueue.main.async {
                self.currentTime = time.seconds
                self.originalTranscript = newText
                if adjustedPosition > 0, let range = transcriptModel.firstCue(containing: adjustedPosition)?.characterRange {
                    self.scrollRange = range
                }
            }
        }
    }

    func loadAudio() async {
        allSegments.removeAll()
        offsets.removeAll()

        await setupAudioPlay()

        setupSpeechRecognition()
    }

    private var allSegments: [SFTranscriptionSegment] = []

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
        let localeToUse = Locale(identifier: ("en-us"))
        guard let recognizer = SFSpeechRecognizer(locale: localeToUse),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            return
        }
        recognizer.queue = transcriptQueue
        recognizer.defaultTaskHint = .dictation
        // Create and execute a speech recognition request for the audio file at the URL.
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.shouldReportPartialResults = false

        let startDate = Date.now
        recognizer.recognitionTask(with: request) { [weak self](result, error) in
            guard let self, let result else {
                if let error = error {
                    print(error)
                }
                return
            }
            handleRecognitionResult(result, locale: localeToUse)
            if result.isFinal {
                print("Finished: \(startDate.timeIntervalSinceNow)s")
            }
        }
    }

    func handleRecognitionResult(_ result: SFSpeechRecognitionResult, locale: Locale) {

        let transcription = result.bestTranscription
        // Only when metadata is available this partial transcript is established
        if let metadata = result.speechRecognitionMetadata {
            print("\(metadata.speechStartTimestamp): \(transcription.formattedString)")
            speechRecognizedText += "\n" + transcription.formattedString
            allSegments.append(contentsOf: transcription.segments)
        }
        // Do we have enough recognized words to try to do a search?
        guard allSegments.count > 0, allSegments.count >= wordCount else {
            return
        }

        let referenceTranscriptText = (transcriptModel?.attributedText.string as? NSString) ?? NSString()

        while segmentsPosition + wordCount < allSegments.count {
            let wordToSearch  = allSegments[segmentsPosition...min(segmentsPosition + wordCount, allSegments.count-1)].map({$0.substring.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)}).joined(separator: " ")

            //Search recognized text inside the original transcript string
            let range = referenceTranscriptText.range(of: wordToSearch, options: [.diacriticInsensitive, .caseInsensitive], range:NSRange(location: currentPosition, length: referenceTranscriptText.length - currentPosition))

            guard range.location != NSNotFound,//Did we found the search words?
                  //we found matching text in the transcript do we have cue for that range
                  let cueInRange = transcriptModel?.cues.first(where: { $0.characterRange.intersection(range) != nil} )
            else {
                segmentsPosition += 1
                continue
            }

            //Advance Search position to beginning of the cue we found
            currentPosition = cueInRange.characterRange.location

            // Find inside the Cue where the match position is located
            let cueWords = referenceTranscriptText.substring(with: cueInRange.characterRange).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            let cueArray = cueWords.components(separatedBy: .whitespacesAndNewlines).map { $0.trimmingCharacters(in: .punctuationCharacters)}.filter { !$0.isEmpty}
            let searchArray = wordToSearch.components(separatedBy: .whitespacesAndNewlines)

            let i = indexOf(searchArray, inside: cueArray)

            let idealPosition = segmentsPosition - i
            var position = segmentsPosition
            if idealPosition >= 0 && idealPosition < allSegments.count {
                position = idealPosition
            }
            let adjustShift = position - idealPosition
            // Adjust time where match was done depending of position of first word matched inside the cue
            var cueOffsetTime: Double = 0
            if adjustShift != 0, i != 0, i < cueArray.count {
                cueOffsetTime = (cueInRange.endTime - cueInRange.startTime) * (Double(cueArray.prefix(adjustShift).joined(separator: " ").count) / Double(cueInRange.characterRange.length))
            }
            let calculatedOffset = (cueInRange.startTime + cueOffsetTime) - allSegments[position].timestamp
            //print("Offset at: \(allSegments[position].timestamp) -> \(calculatedOffset)")
            if abs(self.offset - calculatedOffset) > Constants.offsetThreadshold {
                print("Match audio: `\(searchArray)` at: \(allSegments[segmentsPosition].timestamp) in cue: \(cueInRange.startTime) inside cue: `\(cueArray)` position: \(i)")
                self.offset = calculatedOffset
                self.offsets.append(Offset(offset: calculatedOffset, start: cueInRange.startTime, end: cueInRange.endTime))
                print("-----> Offsets Start <------")
                offsets.forEach {
                    print($0)
                }
                print("-----> Offsets End <------\n")
            }
            else {
                //previousStartTime = cueInRange.endTime
                if let offset = self.offsets.popLast() {
                    let newOffset = (calculatedOffset + offset.offset) / 2
                    self.offset = newOffset
                    self.offsets.append(Offset(offset:  newOffset, start: offset.start, end: cueInRange.endTime))
                }
            }
            segmentsPosition += wordCount
        }
    }


    func indexOf(_ toSearch: [String], inside other: [String]) -> Int {
        var i = 0
        while i < toSearch.count {
            var j = 0
            var match = true
            while j < toSearch.count  && i+j < other.count {
                match = match && (other[i+j] == toSearch[j])
                j += 1
            }
            if match {
                break
            }
            i += 1
        }
        return i
    }

    var previousRange: NSRange?

    private func styleText(transcript: TranscriptModel, position: Double = -1) -> NSAttributedString {
        let formattedText = NSMutableAttributedString(attributedString: transcript.attributedText)
        formattedText.beginEditing()
        let normalStyle = makeStyle()
        var highlightStyle = normalStyle
        highlightStyle[.foregroundColor] = UIColor.red

        let fullLength = NSRange(location: 0, length: formattedText.length)
        formattedText.addAttributes(normalStyle, range: fullLength)

        if position > 0, let range = transcript.firstCue(containing: position)?.characterRange ?? previousRange {
            previousRange = range
            formattedText.addAttributes(highlightStyle, range: range)
        }

        let speakerFont = UIFont.preferredFont(forTextStyle: .footnote)
        formattedText.enumerateAttribute(.transcriptSpeaker, in: fullLength, options: [.reverse, .longestEffectiveRangeNotRequired]) { value, range, _ in
            if value == nil {
                return
            }
            formattedText.addAttribute(.font, value: speakerFont, range: range)
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

struct ContentView: View {

    @StateObject private var model = TranscriptSyncModel(audioString: "Adidas_v_Puma_Battle.mp3", transcriptString: "Adidas_v_Puma_Battle.vtt")!

    var body: some View {
        VStack {
            AttributedTextView(text: $model.originalTranscript, scrollRange: $model.scrollRange)
            VideoPlayer(player: model.player)
                .frame(height: 100)
            TextField("Generated", text: $model.generatedTranscript, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .frame(height: 200)
        }
        .padding()
        .task {
            await model.load()
        }
    }
}

#Preview {
    ContentView()
}
