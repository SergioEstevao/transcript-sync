import AVKit
import Speech
import SwiftSubtitles
import NaturalLanguage

// Just do local transcript and do not sync with server model
class TranscriptSyncModelLocal: ObservableObject, TranscriptPlayer  {

    struct TimedWord {
        let timeRange: CMTimeRange
        let characterRange: NSRange
    }

    var transcriptModel: TranscriptModel?

    @Published var generatedTranscript: String = ""
    @Published var highlightedTranscript: NSAttributedString = NSAttributedString(string: "")

    @Published var originalTranscript: NSAttributedString = NSAttributedString(string: "")

    @Published var player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 1

    @Published var timedWords: [TimedWord] = []
    @Published var scrollRange: NSRange = NSRange(location: NSNotFound, length: 0)

    private var lastHighlightedRange: NSRange?

    private var timeObserverToken: Any?

    let audioURL: URL
    let transcriptURL: URL
    let audioQueue = DispatchQueue(label: "audioQueue")

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

    func load() async {
        if let transcriptModel = TranscriptModel.makeModel(from: transcriptURL) {
            DispatchQueue.main.async {
                self.transcriptModel = transcriptModel
                self.originalTranscript = self.styleGeneratedTranscript(original: transcriptModel.attributedText.string, highlightRange: nil)
            }
        }
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
                    self.highlightedTranscript = self.styleGeneratedTranscript(original: self.generatedTranscript, highlightRange: currentWord.characterRange)
                    self.scrollRange = currentWord.characterRange
                    self.lastHighlightedRange = currentWord.characterRange
                }
            }
        }
    }

    func loadAudio() async {
        DispatchQueue.main.async {
            self.timedWords.removeAll()
        }
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
                self.highlightedTranscript = self.styleGeneratedTranscript(original: self.generatedTranscript, highlightRange: nil)
            }
        }
    }

    func styleGeneratedTranscript(original: String, highlightRange: NSRange?) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: original)
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

    func localeToUse() async -> Locale {
        var localeToUse = Locale(identifier: ("en-us"))
        guard let text = transcriptModel?.attributedText.string,
              let nlLanguage = NLLanguageRecognizer.dominantLanguage(for: text) else {
            return localeToUse
        }

        let detectedLocale = Locale(identifier: nlLanguage.rawValue)

        for availableLocale in await SpeechTranscriber.supportedLocales {
            if availableLocale.language.languageCode?.identifier == detectedLocale.language.languageCode?.identifier {
                localeToUse = availableLocale
                break
            }
        }
        return localeToUse
    }

    func setupSpeechAnalysis(from player: AVPlayer) async throws -> some AsyncSequence<SpeechTranscriber.Result, any Error> {
        // I set this up from the player so that the file could be streamed.
        // In theory, if we have the cached download, we could simplify this and not need to do any of the AVAssetReader stuff.

        let locale = await localeToUse()
        var preset: SpeechTranscriber.Preset = .offlineTranscription
        preset.attributeOptions = [.audioTimeRange]
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)

        do {
            try await ensureModel(transcriber: transcriber, locale: locale)
        } catch let error as TranscriptionError {
            print(error)
            throw error
        }

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

extension TranscriptSyncModelLocal {
    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw TranscriptionError.localeNotSupported
        }

        if await installed(locale: locale) {
            return
        } else {
            try await downloadIfNeeded(for: transcriber)
        }
    }

    func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            //self.downloadProgress = downloader.progress
            try await downloader.downloadAndInstall()
        }
    }

    func deallocate() async {
        let allocated = await AssetInventory.allocatedLocales
        for locale in allocated {
            await AssetInventory.deallocate(locale: locale)
        }
    }
}

public enum TranscriptionError: Error {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound

    var descriptionString: String {
        switch self {

            case .couldNotDownloadModel:
                return "Could not download the model."
            case .failedToSetupRecognitionStream:
                return "Could not set up the speech recognition stream."
            case .invalidAudioDataType:
                return "Unsupported audio format."
            case .localeNotSupported:
                return "This locale is not yet supported by SpeechAnalyzer."
            case .noInternetForModelDownload:
                return "The model could not be downloaded because the user is not connected to internet."
            case .audioFilePathNotFound:
                return "Couldn't write audio to file."
        }
    }
}
