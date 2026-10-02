import AVFoundation
import CoreMedia

/// Feeds the console's H.264/HEVC stream to a display layer, which decodes it in hardware and shows each frame at once.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()

    private let hevc: Bool
    private var vps: [UInt8] = []
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var format: CMVideoFormatDescription?
    private var formatStale = false
    private(set) var framesShown = 0

    init(hevc: Bool) {
        self.hevc = hevc
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Returns false when the frame could not be queued, so the caller can ask for a new keyframe.
    func enqueue(_ data: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let sample = makeSample(data) else { return !hasPayload }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            return false
        }
        renderer.enqueue(sample)
        framesShown += 1
        return true
    }

    func testSample(_ data: UnsafeBufferPointer<UInt8>) -> CMSampleBuffer? {
        makeSample(data)
    }

    private var hasPayload = false

    private func makeSample(_ data: UnsafeBufferPointer<UInt8>) -> CMSampleBuffer? {
        var payload = [UInt8]()
        payload.reserveCapacity(data.count + 16)
        Self.forEachUnit(in: data) { unit in
            let type = hevc ? (unit[unit.startIndex] >> 1) & 0x3f : unit[unit.startIndex] & 0x1f
            switch (hevc, type) {
            case (true, 32): store(unit, in: &vps)
            case (true, 33), (false, 7): store(unit, in: &sps)
            case (true, 34), (false, 8): store(unit, in: &pps)
            case (true, 35), (false, 9): break
            default:
                withUnsafeBytes(of: UInt32(unit.count).bigEndian) { payload.append(contentsOf: $0) }
                payload.append(contentsOf: unit)
            }
        }
        if formatStale { rebuildFormat() }
        hasPayload = !payload.isEmpty
        guard hasPayload, let format else { return nil }
        return Self.makeSample(payload, format: format)
    }

    private func store(_ unit: Slice<UnsafeBufferPointer<UInt8>>, in set: inout [UInt8]) {
        guard !unit.elementsEqual(set) else { return }
        set = Array(unit)
        formatStale = true
    }

    private func rebuildFormat() {
        formatStale = false
        let sets = hevc ? [vps, sps, pps] : [sps, pps]
        guard sets.allSatisfy({ !$0.isEmpty }) else { return }
        var created: CMVideoFormatDescription?
        let buffers = sets.map { UnsafeMutableBufferPointer<UInt8>.allocate(capacity: $0.count) }
        defer { buffers.forEach { $0.deallocate() } }
        for (buffer, set) in zip(buffers, sets) { _ = buffer.initialize(from: set) }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = sets.map(\.count)
        if hevc {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &created)
        } else {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &created)
        }
        if let created { format = created }
    }

    private static func makeSample(_ payload: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(with: payload, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) == noErr
        else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(entry,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Calls `body` with each NAL unit of an Annex B buffer, without start codes or trailing zero padding.
    static func forEachUnit(in data: UnsafeBufferPointer<UInt8>, _ body: (Slice<UnsafeBufferPointer<UInt8>>) -> Void) {
        let count = data.count
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1].code : count
            while end > start.payload, data[end - 1] == 0 { end -= 1 }
            if end > start.payload { body(data[start.payload..<end]) }
        }
    }
}
