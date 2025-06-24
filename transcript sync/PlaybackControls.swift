import SwiftUI
import AVFoundation

protocol TranscriptPlayer {
    func load() async
    var player: AVPlayer { get }
}

struct PlaybackControls: View {
    var model: TranscriptPlayer

    @State private var currentTime: Double = 0
    @State private var duration: Double = 1 // Default to avoid division by zero
    @State private var isDragging = false
    @State var isPlaying = false

    var body: some View {
        HStack {
            Button(action: {
                if isPlaying {
                    model.player.pause()
                } else {
                    model.player.play()
                }
            }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .imageScale(.large)
                    .padding()
            }

            // Scrubber
            Slider(value: $currentTime, in: 0...duration, onEditingChanged: { editing in
                isDragging = editing
                if !editing {
                    let newTime = CMTime(seconds: currentTime, preferredTimescale: 600)
                    model.player.seek(to: newTime)
                }
            })
        }
        .task {
            await model.load()
            duration = model.player.currentItem?.duration.seconds ?? 1
            if duration.isNaN {
                duration = 1 // Fallback to avoid division by zero
            }
            addPeriodicTimeObserver()
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        model.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            self.isPlaying = model.player.rate != 0
            guard !isDragging else { return }
            currentTime = time.seconds
        }
    }
}
