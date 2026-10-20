#if os(iOS)
import UIKit
import MetalKit
import CoreVideo

// This object has no UIKit state and may be called from VLC's video thread.
// Keep the callback boundary outside UIView's main-actor isolation.
@objc(RoxyVideoFrameQueue)
final class RoxyVideoFrameQueue: NSObject {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var active = true

    @objc var acceptingFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    @objc var receivedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    @objc(submitPixelBuffer:)
    func submit(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if active { frame = pixelBuffer; sequence &+= 1 }
        lock.unlock()
    }

    func snapshot() -> (CVPixelBuffer?, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (frame, sequence)
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        if !value { frame = nil }
        lock.unlock()
    }
}

@objc(RoxyAnime4KView)
final class RoxyAnime4KView: UIView, MTKViewDelegate {
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private let blitPipeline: MTLRenderPipelineState
    private let engine: RoxyAnime4KEngine
    private var textureCache: CVMetalTextureCache?
    @objc let frames = RoxyVideoFrameQueue()
    private var renderedSequence: UInt64 = UInt64.max
    private var inFlight = false
    private var active = true
    private var frameInterval = 1.0 / 30.0
    private var previousArrival: CFTimeInterval = 0
    private let badge = UILabel()
    private var settingsObserver: NSObjectProtocol?
    private var captureCompletion: ((UIImage?) -> Void)?
    @objc private(set) var renderMetrics: [String: Any] = ["status": "Waiting for video"]
    @objc private(set) var renderedFrameCount: UInt64 = 0
    @objc var fillVideo = false { didSet { renderedSequence = UInt64.max } }
    @objc var aspectRatio: Double = 0 { didSet { renderedSequence = UInt64.max } }

    @objc static var supported: Bool { MTLCreateSystemDefaultDevice() != nil }

    @objc(makeViewWithFrame:)
    static func makeView(frame: CGRect) -> RoxyAnime4KView? {
        do { return try RoxyAnime4KView(validatedFrame: frame) }
        catch { NSLog("Roxy Metal initialization failed: %@", error.localizedDescription); return nil }
    }

    private init(validatedFrame frame: CGRect) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let root = Bundle.main.resourceURL?.appendingPathComponent("RoxyAnime4K") else {
            throw RoxyShaderError.invalid("Metal is unavailable")
        }
        commandQueue = queue
        engine = try RoxyAnime4KEngine(device: device, root: root)
        metalView = MTKView(frame: .zero, device: device)
        let options = MTLCompileOptions()
        options.languageVersion = .version2_3
        let library = try device.makeLibrary(source: Self.presentationShader, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "roxy_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "roxy_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init(frame: frame)
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            throw RoxyShaderError.invalid("Cannot create video texture cache")
        }
        backgroundColor = .black
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.delegate = self
        metalView.isUserInteractionEnabled = false
        addSubview(metalView)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        badge.layer.cornerRadius = 5
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        badge.accessibilityIdentifier = "roxy.anime4k.status"
        addSubview(badge)
        engine.onChange = { [weak self] in self?.renderedSequence = UInt64.max }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(background), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        settingsObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.renderedSequence = UInt64.max
        }
    }

    required init?(coder: NSCoder) { return nil }
    deinit {
        frames.setActive(false)
        NotificationCenter.default.removeObserver(self)
        if let observer = settingsObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        // MTKView must target display PIXELS, including iPad Retina/external
        // screens. A point-sized target silently skips the upstream >1.2x hooks.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalView.contentScaleFactor = max(1, scale)
        metalView.drawableSize = CGSize(width: bounds.width * max(1, scale), height: bounds.height * max(1, scale))
        renderedSequence = UInt64.max
        badge.frame = CGRect(x: safeAreaInsets.left + 16, y: safeAreaInsets.top + 116,
                             width: max(0, min(bounds.width - 20, 420)), height: 24)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        metalView.isPaused = window == nil || !active
        frames.setActive(window != nil && active)
    }

    @objc private func background() {
        active = false
        frames.setActive(false)
        metalView.isPaused = true
    }

    @objc private func foreground() {
        active = true
        frames.setActive(window != nil)
        metalView.isPaused = window == nil
        renderedSequence = UInt64.max
    }

    @objc private func memoryWarning() {
        engine.resetMemory()
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderedSequence = UInt64.max }

    // Used by image validation and frame export. Render the SAME presentation
    // pipeline to a readable target without changing the fast drawable surface.
    @objc(captureNextFrame:)
    func captureNextFrame(_ completion: @escaping (UIImage?) -> Void) {
        captureCompletion?(nil)
        captureCompletion = completion
        renderedSequence = UInt64.max
    }

    private func present(_ texture: MTLTexture, scale: SIMD2<Float>, pass: MTLRenderPassDescriptor,
                         command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var scale = scale
        encoder.setRenderPipelineState(blitPipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private static func image(from texture: MTLTexture) -> UIImage? {
        let rowBytes = texture.width * 4
        var bytes = Data(count: rowBytes * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    func draw(in view: MTKView) {
        badge.isHidden = !UserDefaults.standard.bool(forKey: "RoxyAnime4KShowStatus")
        if let width = renderMetrics["inputWidth"], let output = renderMetrics["outputWidth"] {
            let time = (renderMetrics["gpuMilliseconds"] as? Double) ?? 0
            badge.text = "  \(engine.status) · \(width) → \(output) · \(String(format: "%.1f", time)) ms"
        } else { badge.text = "  " + engine.status }
        guard active, !inFlight, view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let (frame, currentSequence) = frames.snapshot()
        guard let pixelBuffer = frame, currentSequence != renderedSequence, let cache = textureCache else { return }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
                                                       width, height, 0, &cvTexture) == kCVReturnSuccess,
              let image = cvTexture, let source = CVMetalTextureGetTexture(image),
              let command = commandQueue.makeCommandBuffer(), let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor else { return }
        let now = CACurrentMediaTime()
        if previousArrival > 0, currentSequence != renderedSequence {
            let delta = now - previousArrival
            if delta > 1.0 / 121 && delta < 0.25 { frameInterval = frameInterval * 0.9 + delta * 0.1 }
        }
        previousArrival = now
        let ratio = aspectRatio > 0 ? aspectRatio : Double(width) / Double(height)
        let displayRatio = Double(view.drawableSize.width / view.drawableSize.height)
        var scale = SIMD2<Float>(1, 1)
        if (ratio > displayRatio) != fillVideo { scale.y = Float(displayRatio / ratio) }
        else { scale.x = Float(ratio / displayRatio) }
        let target = SIMD2(max(1, min(16384, Int(Double(view.drawableSize.width) * Double(scale.x)))),
                           max(1, min(16384, Int(Double(view.drawableSize.height) * Double(scale.y)))))
        let filtered: MTLTexture
        do { filtered = try engine.encode(input: source, outputSize: target, commandBuffer: command) }
        catch {
            filtered = source
            badge.text = "  Anime4K: " + error.localizedDescription
        }
        guard present(filtered, scale: scale, pass: renderPass, command: command) else { return }
        let capture = captureCompletion
        captureCompletion = nil
        var captureTexture: MTLTexture?
        if capture != nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: drawable.texture.width, height: drawable.texture.height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            if let texture = metalView.device?.makeTexture(descriptor: descriptor) {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                if present(filtered, scale: scale, pass: pass, command: command) { captureTexture = texture }
            }
        }
        let metrics: [String: Any] = ["status": engine.status, "quality": engine.selectedQuality,
            "inputWidth": width, "inputHeight": height, "outputWidth": filtered.width, "outputHeight": filtered.height,
            "displayWidth": Int(view.drawableSize.width), "displayHeight": Int(view.drawableSize.height),
            "passes": engine.encodedPassCount, "upscaled": filtered.width > width && filtered.height > height]
        command.present(drawable)
        inFlight = true
        renderedSequence = currentSequence
        let budget = frameInterval
        command.addCompletedHandler { [weak self, pixelBuffer, image, captureTexture] buffer in
            // Retain the CVPixelBuffer AND CVMetalTexture until GPU completion.
            _ = pixelBuffer
            _ = image
            let duration = buffer.gpuEndTime - buffer.gpuStartTime
            let snapshot = buffer.status == .completed ? captureTexture.flatMap { Self.image(from: $0) } : nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                self.renderedFrameCount &+= 1
                self.renderMetrics = metrics.merging(["gpuMilliseconds": duration * 1000]) { _, new in new }
                capture?(snapshot)
                if buffer.status == .error {
                    self.badge.text = "  Metal error; select a lower Anime4K quality"
                    self.engine.resetMemory()
                } else if duration > 0 { self.engine.reportFrameTime(duration, budget: budget) }
            }
        }
        command.commit()
    }

    private static let presentationShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex roxy_vertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        float2 uv = float2(id & 1, (id >> 1) & 1);
        Vertex value;
        value.position = float4((uv * 2.0 - 1.0) * scale, 0.0, 1.0);
        value.uv = float2(uv.x, 1.0 - uv.y);
        return value;
    }
    fragment float4 roxy_fragment(Vertex value [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return float4(clamp(image.sample(linearSampler, value.uv).rgb, 0.0, 1.0), 1.0);
    }
    """
}
#endif
