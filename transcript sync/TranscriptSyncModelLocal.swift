import AVKit
import Speech
import SwiftSubtitles

class TranscriptSyncModelLocal: ObservableObject {

    struct TimedWord {
        let timeRange: CMTimeRange
        let characterRange: NSRange
    }

    @Published var generatedTranscript: String = ""
    @Published var highlightedTranscript: NSAttributedString = NSAttributedString(string: "")
    @Published var player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 1

    @Published var timedWords: [TimedWord] = []
    @Published var scrollRange: NSRange = NSRange(location: NSNotFound, length: 0)

    private var lastHighlightedRange: NSRange?

    private var timeObserverToken: Any?

    let audioURL: URL
    let audioQueue = DispatchQueue(label: "audioQueue")

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    convenience init?(audioString: String) {
        guard let audioURL = Bundle.main.url(forResource: audioString, withExtension: nil) else { return nil }
        self.init(audioURL: audioURL)
    }

    func load() async {
        await loadAudio()
    }

    func setupAudioPlay() async {
        self.player.replaceCurrentItem(with: AVPlayerItem(url: self.audioURL))

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        if let currentItem = player.currentItem {
            let value = (try? await currentItem.asset.load(.duration).seconds) ?? 0.0
            await MainActor.run {
                duration = value
                self.player.play()
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: audioQueue) { [weak self] time in
            guard let self else { return }
            let currentTime = time.seconds

            // Find the index of the word that is currently active
            guard let index = self.timedWords.indices.last(where: { self.timedWords[$0].timeRange.containsTime(self.player.currentTime()) }) else {
                DispatchQueue.main.async {
                    self.currentTime = currentTime
                }
                return
            }

            let currentWord = self.timedWords[index]

            // Stay on this word until the next one starts
            if let range = Range(currentWord.characterRange, in: generatedTranscript) {
                let text = generatedTranscript[range]
                print("Word: \(text) - Time: \(currentTime) - Range: \(self.timedWords[index].timeRange.start.seconds)-\(self.timedWords[index].timeRange.duration.seconds)")
            }

            if self.lastHighlightedRange != currentWord.characterRange {
                DispatchQueue.main.async {
                    self.currentTime = currentTime
                    self.highlightedTranscript = self.styleGeneratedTranscript(highlightRange: currentWord.characterRange)
                    self.scrollRange = currentWord.characterRange
                    self.lastHighlightedRange = currentWord.characterRange
                }
            }
        }
    }

    func loadAudio() async {
        timedWords.removeAll()
        await setupAudioPlay()

        Task.detached(priority: .userInitiated) {
            let sequence = try! await self.setupSpeechAnalysis(from: self.player)

            do {
                for try await result in sequence {
                    self.handleRecognitionResult(result)
                }
            } catch {
                print("Error during speech analysis: \(error)")
            }
        }
    }

    func handleRecognitionResult(_ result: SpeechTranscriber.Result) {
        let newText = result.substring + "\n"
        let currentLength = (generatedTranscript as NSString).length

        var newTimedWords: [TimedWord] = []
        for run in result.text.runs {
            guard let audioTimeRange = run.audioTimeRange else { continue }
            let nsRange = NSRange(run.range, in: result.text)
            let adjustedRange = NSRange(location: currentLength + nsRange.location, length: nsRange.length)
            newTimedWords.append(TimedWord(timeRange: audioTimeRange, characterRange: adjustedRange))
        }

        DispatchQueue.main.async {
            self.generatedTranscript += newText
            self.timedWords.append(contentsOf: newTimedWords)

            if !newTimedWords.isEmpty && self.highlightedTranscript.length == 0 {
                self.highlightedTranscript = self.styleGeneratedTranscript(highlightRange: nil)
            }
        }
    }

    func styleGeneratedTranscript(highlightRange: NSRange?) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: generatedTranscript)
        let fullRange = NSRange(location: 0, length: attributed.length)
        let normalAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label,
            .font: UIFont.preferredFont(forTextStyle: .body)
        ]
        attributed.addAttributes(normalAttributes, range: fullRange)

        if let highlight = highlightRange, NSLocationInRange(highlight.location, fullRange) {
            attributed.addAttributes([.foregroundColor: UIColor.red], range: highlight)
        }

        return attributed
    }

    func setupSpeechAnalysis(from player: AVPlayer) async throws -> some AsyncSequence<SpeechTranscriber.Result, any Error> {
        // I set this up from the player so that the file could be streamed.
        // In theory, if we have the cached download, we could simplify this and not need to do any of the AVAssetReader stuff.

        let locale = Locale(identifier: "en-us")
        var preset: SpeechTranscriber.Preset = .offlineTranscription
        preset.attributeOptions = [.audioTimeRange]
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        guard let currentItem = player.currentItem,
              let assetTrack = try await currentItem.asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "SpeechAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }

        let reader = try await AVAssetReader(asset: currentItem.asset)
        let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format?.sampleRate ?? 44100,
            AVNumberOfChannelsKey: format?.channelCount ?? 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        reader.startReading()

        Task.detached(priority: .userInitiated) {
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

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
}
