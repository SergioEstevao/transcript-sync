import SwiftUI
import AVKit

struct ContentView: View {

//    @StateObject private var model = TranscriptSyncModel(audioString: "Adidas_v_Puma_Battle.mp3", transcriptString: "Adidas_v_Puma_Battle.vtt")!
    @StateObject private var model = TranscriptSyncModelLocal(audioString: "Adidas_v_Puma_Battle.mp3")!

    var body: some View {
        VStack {
            HStack {
                AttributedTextView(text: $model.highlightedTranscript, scrollRange: $model.scrollRange)
                AttributedTextView(text: $model.originalTranscript, scrollRange: Binding.constant(NSRange(location: NSNotFound, length: 0)))
            }
            PlaybackControls(model: model)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
