import SwiftUI
import AVKit

struct ContentView: View {

//    @StateObject private var model = TranscriptSyncModel(audioString: "Adidas_v_Puma_Battle.mp3", transcriptString: "Adidas_v_Puma_Battle.vtt")!
    @StateObject private var model = TranscriptSyncModelLocal(audioString: "Adidas_v_Puma_Battle.mp3")!

    var body: some View {
        VStack {
            AttributedTextView(text: $model.highlightedTranscript, scrollRange: $model.scrollRange)
            HStack {
                VideoPlayer(player: model.player)
                    .frame(height: 100)
            }
//            TextField("Generated", text: $model.generatedTranscript, axis: .vertical)
//                .textFieldStyle(.roundedBorder)
//                .frame(height: 200)
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
