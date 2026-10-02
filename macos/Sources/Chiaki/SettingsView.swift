import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            VideoSettings()
                .tabItem { Label("Video", systemImage: "display") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 480)
    }
}

private struct VideoSettings: View {
    @ObservedObject private var prefs = EnginePrefs.shared

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
                    Text("HEVC (HDR)").tag("h265_hdr")
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
                Picker("Scaling Quality", selection: $prefs.scalingQuality) {
                    Text("Fast").tag("fast")
                    Text("Balanced").tag("default")
                    Text("High Quality").tag("high_quality")
                }
                Toggle("Start in Full Screen", isOn: $prefs.startFullScreen)
                Toggle("Show Performance Statistics", isOn: $prefs.showStatistics)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @ObservedObject private var prefs = EnginePrefs.shared

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
    }
}

private struct AdvancedSettings: View {
    @ObservedObject private var prefs = EnginePrefs.shared

    var body: some View {
        Form {
            Section {
                Picker("Renderer", selection: $prefs.renderer) {
                    Text("Vulkan").tag("vulkan")
                    Text("OpenGL").tag("opengl")
                }
                Toggle("Pace Frames Evenly", isOn: $prefs.framePacing)
            } footer: {
                Text("Pacing smooths motion and adds 5–10 ms of delay.")
            }

            Section {
                Toggle("Log Frame Timing", isOn: $prefs.logFrameTiming)
            } footer: {
                Text("Writes per-stage timing to the session log every 5 seconds.")
            }
        }
        .formStyle(.grouped)
    }
}
