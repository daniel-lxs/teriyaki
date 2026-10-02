import AVFoundation
import ImageIO
import Metal
import QuartzCore
import VideoToolbox
import os

/// Decodes in hardware and presents each frame through Metal the moment it is ready, without waiting for display sync.
final class MetalRenderer: VideoOutput {
    private let metalLayer = CAMetalLayer()
    private let parser: StreamParser
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMVideoFormatDescription?
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var needsKeyframe = false
        var timings = VideoTimings()
    }

    var layer: CALayer { metalLayer }

    /// Debug aid: when set, the next rendered frame is also written here as a PNG.
    var captureURL: URL? {
        didSet { metalLayer.framebufferOnly = captureURL == nil }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex vertexMain(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Vertex out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }
    fragment float4 fragmentMain(Vertex in [[stage_in]], texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]], sampler s [[sampler(0)]]) {
        float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, in.uv).rg - 0.5) * (255.0 / 224.0);
        return float4(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x, 1.0);
    }
    """

    init?(hevc: Bool, displaySync: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.commands = commands
        self.pipeline = pipeline
        self.sampler = sampler
        parser = StreamParser(hevc: hevc)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = displaySync
        metalLayer.maximumDrawableCount = 2
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        metalLayer.isOpaque = true
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func enqueue(_ data: UnsafeBufferPointer<UInt8>) -> Bool {
        let arrival = CACurrentMediaTime()
        guard let sample = parser.sample(from: data) else { return !parser.lastHadPicture }
        if state.withLock({ state -> Bool in
            defer { state.needsKeyframe = false }
            return state.needsKeyframe
        }) {
            return false
        }
        guard let format = parser.format, let session = decoder(for: format) else { return false }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.state.withLock { $0.needsKeyframe = true }
                return
            }
            let decoded = CACurrentMediaTime() - arrival
            self.state.withLock {
                $0.timings.frames += 1
                $0.timings.decodeTotal += decoded
                $0.timings.decodeMax = max($0.timings.decodeMax, decoded)
            }
            self.present(image, arrival: arrival)
        }
        return status == noErr
    }

    func takeTimings() -> VideoTimings {
        state.withLock { state in
            defer { state.timings = VideoTimings() }
            return state.timings
        }
    }

    private func decoder(for format: CMVideoFormatDescription) -> VTDecompressionSession? {
        if let session, let sessionFormat, CFEqual(sessionFormat, format) { return session }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created) == noErr,
            let created else { return nil }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        sessionFormat = format
        return created
    }

    private func present(_ image: CVPixelBuffer, arrival: CFTimeInterval) {
        guard let textureCache,
              let luma = texture(image, plane: 0, format: .r8Unorm, cache: textureCache),
              let chroma = texture(image, plane: 1, format: .rg8Unorm, cache: textureCache),
              let drawable = metalLayer.nextDrawable(),
              let buffer = commands.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let source = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let scale = min(target.width / source.width, target.height / source.height)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        encoder.setViewport(MTLViewport(
            originX: (target.width - fitted.width) / 2, originY: (target.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        drawable.addPresentedHandler { [weak self] shown in
            guard let self, shown.presentedTime > 0 else { return }
            let delay = shown.presentedTime - arrival
            self.state.withLock {
                $0.timings.presented += 1
                $0.timings.displayTotal += delay
                $0.timings.displayMax = max($0.timings.displayMax, delay)
            }
        }
        if let url = captureURL {
            captureURL = nil
            buffer.commit()
            buffer.waitUntilCompleted()
            Self.write(drawable.texture, to: url)
            drawable.present()
            return
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private static func write(_ texture: MTLTexture, to url: URL) {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func texture(_ image: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> MTLTexture? {
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, image, nil, format,
            CVPixelBufferGetWidthOfPlane(image, plane), CVPixelBufferGetHeightOfPlane(image, plane), plane, &wrapped)
        return wrapped.flatMap(CVMetalTextureGetTexture)
    }
}
