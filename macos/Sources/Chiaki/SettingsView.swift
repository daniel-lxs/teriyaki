import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            VideoSettings()
                .tabItem { Label("Video", systemImage: "display") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .frame(width: 480)
    }
}

private struct VideoSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $prefs.resolution) {
                    Text("1080p").tag("1080p")
                    Text("720p").tag("720p")
                    Text("540p").tag("540p")
                    Text("360p").tag("360p")
                }
                Picker("Frame Rate", selection: $prefs.frameRate) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                Picker("Codec", selection: $prefs.codec) {
                    Text("HEVC").tag("h265")
                    Text("H.264").tag("h264")
                }
                LabeledContent("Bitrate") {
                    HStack {
                        Slider(value: $prefs.bitrate, in: 2...100)
                        Text("\(Int(prefs.bitrate)) Mbps")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Higher bitrates look sharper and need a stronger network connection.")
            }

            Section {
                Toggle("Start in Full Screen", isOn: $prefs.startFullScreen)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AudioSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Picker("Buffer", selection: $prefs.audioBufferBytes) {
                    Text("Shortest Delay (10 ms)").tag(1920)
                    Text("Balanced (20 ms)").tag(3840)
                    Text("Most Stable (50 ms)").tag(9600)
                }
            } footer: {
                Text("A shorter buffer reduces audio delay but can crackle on a busy network.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
