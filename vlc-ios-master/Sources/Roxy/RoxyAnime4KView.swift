#if os(iOS)
import UIKit
import MetalKit
import CoreVideo

// Pipeline creation can stall for seconds on a cold driver. Never do it on
// UIKit's thread, and reuse the immutable state when another video is opened.
private enum RoxyPresentationPipeline {
    private static let queue = DispatchQueue(label: "player.roxy.presentation", qos: .userInitiated)
    private static var states: [UInt64: MTLRenderPipelineState] = [:]

    static func load(device: MTLDevice, completion: @escaping (Result<MTLRenderPipelineState, Error>) -> Void) {
        queue.async {
            let result: Result<MTLRenderPipelineState, Error> = Result {
                if let state = states[device.registryID] { return state }
                let options = MTLCompileOptions()
                options.languageVersion = .version2_3
                let library = try device.makeLibrary(source: shader, options: options)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "roxy_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "roxy_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                let state = try device.makeRenderPipelineState(descriptor: descriptor)
                states[device.registryID] = state
                return state
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static let shader = """
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

private struct RoxyRenderSettings: Equatable {
    var enabled = (UserDefaults.standard.object(forKey: "RoxyAnime4KEnabled") as? Bool) != false
    var quality = UserDefaults.standard.string(forKey: "RoxyAnime4KQuality") ?? "automatic"
    var mode = UserDefaults.standard.string(forKey: "RoxyAnime4KMode") ?? "standard"
    var shader = UserDefaults.standard.string(forKey: "RoxyAnime4KShader") ?? "preset"
}

// This object has no UIKit state and may be called from VLC's video thread.
// Keep the callback boundary outside UIView's main-actor isolation.
@objc(RoxyVideoFrameQueue)
final class RoxyVideoFrameQueue: NSObject {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var active = true
    private var arrival: CFTimeInterval = 0
    private var interval = 1.0 / 30.0

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
        if active {
            let now = CACurrentMediaTime()
            let delta = now - arrival
            if arrival > 0, delta >= 1.0 / 121.0, delta < 0.25 {
                interval = interval * 0.9 + delta * 0.1
            }
            arrival = now
            frame = pixelBuffer
            sequence &+= 1
        }
        lock.unlock()
    }

    func snapshot() -> (CVPixelBuffer?, UInt64, Double) {
        lock.lock()
        defer { lock.unlock() }
        return (frame, sequence, interval)
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        // A paused video must survive a view transition or foreground return.
        // Keep one bounded latest frame; inactive queues still reject new ones.
        lock.unlock()
    }
}

@objc(RoxyAnime4KView)
final class RoxyAnime4KView: UIView, MTKViewDelegate {
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private var blitPipeline: MTLRenderPipelineState?
    private let engine: RoxyAnime4KEngine
    private var textureCache: CVMetalTextureCache?
    @objc let frames = RoxyVideoFrameQueue()
    private var renderedSequence: UInt64 = UInt64.max
    private var inFlight = false
    private var active = true
    private var settings = RoxyRenderSettings()
    private var previewOriginal = UserDefaults.standard.bool(forKey: "RoxyAnime4KPreviewOriginal")
    private var engineRevision: UInt64 = 0
    private var thermalLimit = ProcessInfo.processInfo.thermalState == .critical ? 2 :
        (ProcessInfo.processInfo.thermalState == .serious ? 1 : 0)
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var lastInputSequence: UInt64 = 0
    private var skippedFrames: UInt64 = 0
    private struct CachedFrame {
        let sequence: UInt64
        let target: SIMD2<Int>
        let revision: UInt64
        let texture: MTLTexture
        let status: String
        let quality: String
        let mode: String
        let passes: Int
        let gpuMilliseconds: Double
    }
    private var cachedFrame: CachedFrame?
    private let badge = UILabel()
    private var settingsObserver: NSObjectProtocol?
    private var captureCompletion: ((UIImage?) -> Void)?
    @objc private(set) var renderMetrics: [String: Any] = ["status": "Waiting for video"]
    @objc private(set) var renderedFrameCount: UInt64 = 0
    @objc private(set) var cnnFrameCount: UInt64 = 0
    @objc private(set) var presentationFailed = false
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
        // Layout below is the sole authority for Retina drawable dimensions.
        // MTKView's automatic resize can otherwise replace them during a
        // subsequent UIKit layout, unnecessarily rebuilding a paused CNN.
        metalView.autoResizeDrawable = false
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
        engine.onChange = { [weak self] in
            self?.engineRevision &+= 1
            self?.renderedSequence = UInt64.max
        }
        RoxyPresentationPipeline.load(device: device) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let state): self.blitPipeline = state; self.renderedSequence = UInt64.max
            case .failure(let error):
                self.presentationFailed = true
                self.renderMetrics = ["status": "Metal unavailable; returning to original playback"]
                NSLog("Roxy presentation pipeline failed: %@", error.localizedDescription)
                UserDefaults.standard.set(false, forKey: "RoxyAnime4KEnabled")
                self.updateBadge()
                PlaybackService.sharedInstance().applyAnime4KSettings()
            }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(background), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.addObserver(self, selector: #selector(powerChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        settingsObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        }
        updateBadge()
    }

    required init?(coder: NSCoder) { return nil }
    deinit {
        frames.setActive(false)
        NotificationCenter.default.removeObserver(self)
        if let observer = settingsObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if metalView.frame != bounds { metalView.frame = bounds }
        // MTKView must target display PIXELS, including iPad Retina/external
        // screens. A point-sized target silently skips the upstream >1.2x hooks.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if metalView.contentScaleFactor != max(1, scale) { metalView.contentScaleFactor = max(1, scale) }
        let size = CGSize(width: bounds.width * max(1, scale), height: bounds.height * max(1, scale))
        if metalView.drawableSize != size {
            metalView.drawableSize = size
            renderedSequence = UInt64.max
        }
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
        cachedFrame = nil
        engineRevision &+= 1
        engine.resetMemory()
        renderedSequence = UInt64.max
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    @objc private func powerChanged() {
        // ProcessInfo notifications may originate on a non-UI thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let process = ProcessInfo.processInfo
            let limit = process.thermalState == .critical ? 2 : (process.thermalState == .serious ? 1 : 0)
            guard self.thermalLimit != limit || self.lowPowerMode != process.isLowPowerModeEnabled else { return }
            self.thermalLimit = limit
            self.lowPowerMode = process.isLowPowerModeEnabled
            self.cachedFrame = nil
            self.engineRevision &+= 1
            self.renderedSequence = UInt64.max
        }
    }

    private func settingsChanged() {
        let updated = RoxyRenderSettings()
        if settings != updated {
            settings = updated
            cachedFrame = nil
            engineRevision &+= 1
            renderedSequence = UInt64.max
            if !settings.enabled { engine.resetMemory() }
        }
        let original = UserDefaults.standard.bool(forKey: "RoxyAnime4KPreviewOriginal")
        if previewOriginal != original {
            previewOriginal = original
            renderedSequence = UInt64.max
        }
        updateBadge()
    }

    private func updateBadge() {
        badge.isHidden = !UserDefaults.standard.bool(forKey: "RoxyAnime4KShowStatus")
        guard !badge.isHidden else { return }
        let status = renderMetrics["status"] as? String ?? engine.status
        let text: String
        if let width = renderMetrics["inputWidth"], let output = renderMetrics["outputWidth"] {
            let time = (renderMetrics["gpuMilliseconds"] as? Double) ?? 0
            text = "  \(status) · \(width) → \(output) · \(String(format: "%.1f", time)) ms"
        } else { text = "  " + status }
        if badge.text != text { badge.text = text }
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
        guard let blitPipeline = blitPipeline,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
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
        guard active, !inFlight, blitPipeline != nil,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let (frame, currentSequence, frameInterval) = frames.snapshot()
        guard let pixelBuffer = frame, currentSequence != renderedSequence, let cache = textureCache else { return }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
                                                       width, height, 0, &cvTexture) == kCVReturnSuccess,
              let image = cvTexture, let source = CVMetalTextureGetTexture(image),
              let command = commandQueue.makeCommandBuffer(), let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor else { return }
        let ratio = aspectRatio > 0 ? aspectRatio : Double(width) / Double(height)
        let displayRatio = Double(view.drawableSize.width / view.drawableSize.height)
        var scale = SIMD2<Float>(1, 1)
        if (ratio > displayRatio) != fillVideo { scale.y = Float(displayRatio / ratio) }
        else { scale.x = Float(ratio / displayRatio) }
        let target = SIMD2(max(1, min(16384, Int(Double(view.drawableSize.width) * Double(scale.x)))),
                           max(1, min(16384, Int(Double(view.drawableSize.height) * Double(scale.y)))))
        let revision = engineRevision
        let newInput = currentSequence != lastInputSequence
        let cached = cachedFrame.flatMap { value -> CachedFrame? in
            value.sequence == currentSequence && value.target == target && value.revision == revision ? value : nil
        }
        let cacheMiss: String
        if let value = cachedFrame {
            if value.sequence != currentSequence { cacheMiss = "New decoded frame" }
            else if value.target != target { cacheMiss = "Display size changed" }
            else if value.revision != revision { cacheMiss = "Processing configuration changed" }
            else { cacheMiss = "None" }
        } else { cacheMiss = "No completed enhanced frame" }
        var filtered = source
        var status = "Original video"
        var quality = engine.selectedQuality
        var mode = engine.selectedMode
        var passes = 0
        var reused = false
        var cachedGPUTime = 0.0
        if settings.enabled && !previewOriginal {
            if let value = cached {
                filtered = value.texture
                status = value.status
                quality = value.quality
                mode = value.mode
                passes = value.passes
                reused = true
                cachedGPUTime = value.gpuMilliseconds
            } else {
                // The engine reuses its working textures. Release an obsolete
                // snapshot before rebuilding a plan for another frame or size.
                cachedFrame = nil
                do { filtered = try engine.encode(input: source, outputSize: target, commandBuffer: command) }
                catch { status = "Anime4K: " + error.localizedDescription }
                if status == "Original video" { status = engine.status }
                quality = engine.selectedQuality
                mode = engine.selectedMode
                passes = engine.encodedPassCount
            }
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
        let computed = passes > 0 && !reused
        if computed { cnnFrameCount &+= 1 }
        if lastInputSequence > 0, currentSequence > lastInputSequence + 1 {
            skippedFrames &+= currentSequence - lastInputSequence - 1
        }
        lastInputSequence = currentSequence
        let metrics: [String: Any] = ["status": status, "quality": quality, "mode": mode,
            "inputWidth": width, "inputHeight": height, "outputWidth": filtered.width, "outputHeight": filtered.height,
            "displayWidth": Int(view.drawableSize.width), "displayHeight": Int(view.drawableSize.height),
            "passes": passes, "upscaled": filtered.width > width && filtered.height > height,
            "inputSequence": currentSequence, "cnnFrameCount": cnnFrameCount, "computationReused": reused,
            "engineRevision": revision, "targetWidth": target.x, "targetHeight": target.y, "cacheMissReason": cacheMiss,
            "thermalLimit": thermalLimit, "lowPowerMode": lowPowerMode,
            "sourceFPS": 1.0 / frameInterval, "skippedFrames": skippedFrames]
        command.present(drawable)
        inFlight = true
        renderedSequence = currentSequence
        let budget = frameInterval
        // Capture immutable values before leaving the renderer's UI thread.
        let resultStatus = status, resultQuality = quality, resultMode = mode, resultPasses = passes
        let resultReused = reused
        let resultTexture = filtered, previousGPUTime = cachedGPUTime
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
                self.renderMetrics = metrics.merging(["gpuMilliseconds": resultReused ? previousGPUTime : duration * 1000]) { _, new in new }
                if computed, buffer.status == .completed, self.engineRevision == revision {
                    self.cachedFrame = CachedFrame(sequence: currentSequence, target: target, revision: revision,
                        texture: resultTexture, status: resultStatus, quality: resultQuality, mode: resultMode,
                        passes: resultPasses, gpuMilliseconds: duration * 1000)
                }
                capture?(snapshot)
                if buffer.status == .error {
                    self.renderMetrics["status"] = "Metal error; retrying the frame"
                    self.cachedFrame = nil
                    self.engine.resetMemory()
                    self.engineRevision &+= 1
                } else if !resultReused && newInput && resultStatus != "Original video" && capture == nil && duration > 0 {
                    self.engine.reportFrameTime(duration, budget: budget)
                }
                if self.engineRevision != revision { self.renderedSequence = UInt64.max }
                self.updateBadge()
            }
        }
        command.commit()
    }

}
#endif
