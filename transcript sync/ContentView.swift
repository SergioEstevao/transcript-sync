import SwiftUI
import AVKit

struct ContentView: View {

//    @StateObject private var model = TranscriptSyncModel(audioString: "Adidas_v_Puma_Battle.mp3", transcriptString: "Adidas_v_Puma_Battle.vtt")!
    @StateObject private var model = TranscriptSyncModelLocal(audioString: "Adidas_v_Puma_Battle.mp3")!

    var body: some View {
        VStack {
            AttributedTextView(text: $model.highlightedTranscript, scrollRange: $model.scrollRange)
            PlaybackControls(model: model)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
