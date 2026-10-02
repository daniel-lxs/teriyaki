import AVFoundation
import os

/// Plays the decoded audio through a small jitter buffer that never lets a backlog add delay.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let state: OSAllocatedUnfairLock<Ring>

    private struct Ring {
        var samples: [Int16] = []
        var read = 0
        var fill = 0
        var channels = 2
        var targetFrames = 960
        var playing = false

        var capacityFrames: Int { samples.count / max(channels, 1) }
    }

    init(bufferMilliseconds: Int) {
        var ring = Ring()
        ring.targetFrames = max(240, 48 * bufferMilliseconds)
        state = OSAllocatedUnfairLock(initialState: ring)
    }

    func configure(channels: Int, rate: Double) {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else { return }
        state.withLock { ring in
            ring.channels = channels
            ring.samples = [Int16](repeating: 0, count: Int(rate) * channels)
            ring.read = 0
            ring.fill = 0
            ring.playing = false
        }
        let state = self.state
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            state.withLock { ring in
                if !ring.playing, ring.fill >= ring.targetFrames { ring.playing = true }
                let available = ring.playing ? min(frames, ring.fill) : 0
                let capacity = ring.capacityFrames
                for (channel, buffer) in buffers.enumerated() {
                    guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let source = min(channel, ring.channels - 1)
                    for frame in 0..<available {
                        out[frame] = Float(ring.samples[((ring.read + frame) % capacity) * ring.channels + source]) / 32768
                    }
                    for frame in available..<frames { out[frame] = 0 }
                }
                if available > 0 {
                    ring.read = (ring.read + available) % capacity
                    ring.fill -= available
                }
                if ring.playing, available < frames { ring.playing = false }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        if let unit = engine.outputNode.audioUnit {
            var frames: UInt32 = 256
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        try? engine.start()
    }

    func push(_ samples: UnsafePointer<Int16>, frames: Int) {
        state.withLock { ring in
            let capacity = ring.capacityFrames
            guard capacity > 0, frames <= capacity else { return }
            if ring.fill + frames > ring.targetFrames * 3 {
                let drop = ring.fill - ring.targetFrames
                ring.read = (ring.read + drop) % capacity
                ring.fill -= drop
            }
            let write = (ring.read + ring.fill) % capacity
            for frame in 0..<frames {
                let slot = ((write + frame) % capacity) * ring.channels
                for channel in 0..<ring.channels {
                    ring.samples[slot + channel] = samples[frame * ring.channels + channel]
                }
            }
            ring.fill += frames
        }
    }

    func stop() {
        engine.stop()
        if let source {
            engine.detach(source)
            self.source = nil
        }
    }
}
