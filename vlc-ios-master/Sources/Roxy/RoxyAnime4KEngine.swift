// Roxy Player. Anime4K shader weights: Copyright (c) 2019-2021 bloc97, MIT.
import Foundation
import Metal

struct RoxyShaderPass: Decodable {
    let description: String
    let hook: String
    let binds: [String]
    let save: String?
    let width: String?
    let height: String?
    let when: String?
    let components: Int?
    let function: String
}

struct RoxyShader: Decodable {
    let name: String
    let passes: [RoxyShaderPass]
}

struct RoxyShaderManifest: Decodable {
    let schema: Int
    let shaders: [RoxyShader]
    let presets: [String: [String]]
}

enum RoxyShaderError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

// mpv WIDTH, HEIGHT and WHEN expressions use reverse Polish notation. Reject
// malformed stacks and missing textures instead of force-unwrapping them.
enum RoxyExpression {
    static func evaluate(_ expression: String, sizes: [String: SIMD2<Int>]) throws -> Double {
        var stack: [Double] = []
        for token in expression.split(separator: " ").map(String.init) {
            if let number = Double(token) { stack.append(number); continue }
            let parts = token.split(separator: ".")
            if parts.count == 2, let size = sizes[String(parts[0])] {
                if parts[1] == "w" { stack.append(Double(size.x)); continue }
                if parts[1] == "h" { stack.append(Double(size.y)); continue }
            }
            guard stack.count >= 2 else { throw RoxyShaderError.invalid("Invalid expression: \(expression)") }
            let rhs = stack.removeLast(), lhs = stack.removeLast()
            switch token {
            case "+": stack.append(lhs + rhs)
            case "-": stack.append(lhs - rhs)
            case "*": stack.append(lhs * rhs)
            case "/":
                guard rhs != 0 else { throw RoxyShaderError.invalid("Division by zero") }
                stack.append(lhs / rhs)
            case ">": stack.append(lhs > rhs ? 1 : 0)
            case "<": stack.append(lhs < rhs ? 1 : 0)
            default: throw RoxyShaderError.invalid("Unknown expression token: \(token)")
            }
        }
        guard stack.count == 1, let result = stack.first, result.isFinite else {
            throw RoxyShaderError.invalid("Invalid expression result: \(expression)")
        }
        return result
    }
}

enum RoxyQuality: Int, CaseIterable {
    case low, medium, high
    var name: String { ["low", "medium", "high"][rawValue] }
    var memoryLimit: Int { [192, 320, 640][rawValue] * 1024 * 1024 }

    func memoryLimit(device: MTLDevice) -> Int {
        // A second restoration at 4K needs more working textures. Larger
        // unified-memory devices can afford it without raising old-device
        // limits. These are allocation ceilings, never preallocated reserves.
        if device.supportsFamily(.apple7), ProcessInfo.processInfo.physicalMemory >= 8 * 1024 * 1024 * 1024 {
            return [192, 384, 1024][rawValue] * 1024 * 1024
        }
        return memoryLimit
    }

    static func recommended(device: MTLDevice) -> RoxyQuality {
        // GPU families include new iPads automatically. No device model allowlist.
        // High is intentionally reserved for recent GPU families with >= 8 GiB.
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            if device.supportsFamily(.apple9) && ProcessInfo.processInfo.physicalMemory >= 8 * 1024 * 1024 * 1024 {
                return .high
            }
        }
        if device.supportsFamily(.apple7) { return .medium }
        return .low
    }
}

// Auto uses sustained GPU load, rather than one expensive frame or UI redraw,
// and can recover after a demanding scene. Manual presets are never timing
// throttled. Thermal and allocation limits are applied separately by the engine.
struct RoxyQualityBudget {
    private(set) var quality: RoxyQuality
    private var averageLoad: Double?
    private var expensiveTime = 0.0
    private var spareTime = 0.0

    init(quality: RoxyQuality) { self.quality = quality }

    @discardableResult
    mutating func observe(gpuTime: Double, frameBudget: Double, maximum: RoxyQuality) -> Bool {
        guard gpuTime.isFinite, frameBudget.isFinite, gpuTime > 0,
              frameBudget >= 1.0 / 240, frameBudget <= 0.25 else { return false }
        let load = gpuTime / frameBudget
        let average = averageLoad.map { $0 * 0.9 + load * 0.1 } ?? load
        averageLoad = average
        expensiveTime = average > 0.85 ? expensiveTime + frameBudget : max(0, expensiveTime - frameBudget * 2)
        spareTime = average < 0.4 ? spareTime + frameBudget : 0
        let next: RoxyQuality?
        if expensiveTime >= 1.5, quality != .low {
            next = RoxyQuality(rawValue: quality.rawValue - 1)
        } else if spareTime >= 8, quality.rawValue < maximum.rawValue {
            next = RoxyQuality(rawValue: quality.rawValue + 1)
        } else { next = nil }
        guard let value = next else { return false }
        quality = value
        averageLoad = nil
        expensiveTime = 0
        spareTime = 0
        return true
    }
}

// Confined to the renderer's main thread after construction. Pipelines compile
// on a separate serial queue and are published only when the complete chain is
// ready. The original frame remains visible while compilation is in progress.
final class RoxyAnime4KEngine {
    private struct CompiledPass {
        let shader: RoxyShaderPass
        let pipeline: MTLComputePipelineState
    }
    private final class CompiledShader {
        let passes: [CompiledPass]
        init(_ passes: [CompiledPass]) { self.passes = passes }
    }
    private struct Operation {
        let pass: CompiledPass
        let inputs: [Int]
        let output: Int
        let size: SIMD2<Int>
        let format: MTLPixelFormat
    }

    let device: MTLDevice
    let manifest: RoxyShaderManifest
    private let root: URL
    private let sampler: MTLSamplerState
    private static let compiler = DispatchQueue(label: "player.roxy.anime4k.compiler", qos: .userInitiated)
    // State creation is expensive even with precompiled metallibs. Reopening a
    // movie reuses a bounded, thread-safe cache; pressure may evict it at will.
    private static let pipelineCache: NSCache<NSString, CompiledShader> = {
        let cache = NSCache<NSString, CompiledShader>()
        cache.countLimit = 8
        return cache
    }()
    private let shadersByName: [String: RoxyShader]
    private var compiled: [String: [CompiledPass]] = [:]
    private var compiling = Set<String>()
    private var failed = Set<String>()
    private var rejectedPlans = Set<String>()
    private var textures: [Int: MTLTexture] = [:]
    private var planKey = ""
    private var operations: [Operation] = []
    private var finalVersion = 0
    private var frameBudget: RoxyQualityBudget
    private var memoryQuality = RoxyQuality.high
    private var strongMemoryFallback = false
    private var adaptationKey = ""
    private var activeQuality = RoxyQuality.low
    var onChange: (() -> Void)?
    private(set) var status = "Preparing Anime4K"
    private(set) var encodedPassCount = 0
    private var hasTimingSample = false
    var selectedQuality: String { activeQuality.name }
    private(set) var selectedMode = "standard"
    private(set) var selectionReason = ""

    init(device: MTLDevice, root: URL) throws {
        self.device = device
        self.root = root
        manifest = try JSONDecoder().decode(RoxyShaderManifest.self,
                                            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schema == 1 else { throw RoxyShaderError.invalid("Unsupported Anime4K manifest") }
        shadersByName = Dictionary(manifest.shaders.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        frameBudget = RoxyQualityBudget(quality: .recommended(device: device))
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let state = device.makeSamplerState(descriptor: descriptor) else {
            throw RoxyShaderError.invalid("Cannot create Metal sampler")
        }
        sampler = state
    }

    func resetMemory() {
        textures.removeAll()
        planKey = ""
    }

    func reportFrameTime(_ seconds: Double, budget: Double) {
        let defaults = UserDefaults.standard
        guard (defaults.string(forKey: "RoxyAnime4KQuality") ?? "automatic") == "automatic",
              (defaults.string(forKey: "RoxyAnime4KShader") ?? "preset") == "preset",
              hasTimingSample, ProcessInfo.processInfo.thermalState == .nominal,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if frameBudget.observe(gpuTime: seconds, frameBudget: budget, maximum: .recommended(device: device)) {
            // Keep the current frame's resources alive until its command has
            // completed. This callback is delivered after GPU completion.
            resetMemory()
            onChange?()
        }
    }

    private func requestedQuality() -> RoxyQuality {
        let stored = UserDefaults.standard.string(forKey: "RoxyAnime4KQuality") ?? "automatic"
        var quality = RoxyQuality.allCases.first(where: { $0.name == stored }) ?? frameBudget.quality
        let process = ProcessInfo.processInfo
        if process.thermalState == .serious || process.isLowPowerModeEnabled { quality = .low }
        return RoxyQuality(rawValue: min(quality.rawValue, memoryQuality.rawValue)) ?? .low
    }

    private func load(_ shader: RoxyShader) {
        guard compiled[shader.name] == nil, !compiling.contains(shader.name), !failed.contains(shader.name) else { return }
        let key = "\(device.registryID):\(root.standardizedFileURL.path):\(shader.name)" as NSString
        if let cached = Self.pipelineCache.object(forKey: key) {
            compiled[shader.name] = cached.passes
            return
        }
        compiling.insert(shader.name)
        Self.compiler.async { [weak self] in
            guard let self = self else { return }
            do {
                let binary = self.root.appendingPathComponent(shader.name + ".metallib")
                func pipelines(_ library: MTLLibrary) throws -> [CompiledPass] {
                    try shader.passes.map { pass in
                        guard let function = library.makeFunction(name: pass.function) else {
                            throw RoxyShaderError.invalid("Missing Metal function: \(pass.function)")
                        }
                        return CompiledPass(shader: pass, pipeline: try self.device.makeComputePipelineState(function: function))
                    }
                }
                let passes: [CompiledPass]
                // A library can load successfully and reject its target OS
                // only when creating a pipeline. Validate the complete chain.
                if let cached = Self.pipelineCache.object(forKey: key) {
                    passes = cached.passes
                } else if FileManager.default.fileExists(atPath: binary.path),
                   let library = try? self.device.makeLibrary(URL: binary),
                   let ready = try? pipelines(library) {
                    passes = ready
                } else {
                    let source = try String(contentsOf: self.root.appendingPathComponent(shader.name + ".metal"), encoding: .utf8)
                    let options = MTLCompileOptions()
                    options.fastMathEnabled = false
                    options.languageVersion = .version2_3
                    passes = try pipelines(self.device.makeLibrary(source: source, options: options))
                }
                Self.pipelineCache.setObject(CompiledShader(passes), forKey: key)
                DispatchQueue.main.async {
                    self.compiled[shader.name] = passes
                    self.compiling.remove(shader.name)
                    self.planKey = ""
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.failed.insert(shader.name)
                    self.compiling.remove(shader.name)
                    self.status = "Anime4K unavailable: \(error.localizedDescription)"
                    NSLog("Roxy Anime4K: %@", self.status)
                    self.onChange?()
                }
            }
        }
    }

    func encode(input: MTLTexture, outputSize: SIMD2<Int>, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        encodedPassCount = 0
        hasTimingSample = false
        let defaults = UserDefaults.standard
        if (defaults.object(forKey: "RoxyAnime4KEnabled") as? Bool) == false || defaults.bool(forKey: "RoxyAnime4KPreviewOriginal") {
            status = "Anime4K off"
            // Retain the prepared plan when comparing the same paused frame.
            // Memory pressure still releases it through resetMemory().
            return input
        }
        if ProcessInfo.processInfo.thermalState == .critical {
            status = "Anime4K paused: device temperature"
            resetMemory()
            return input
        }
        let custom = defaults.string(forKey: "RoxyAnime4KShader") ?? "preset"
        let storedQuality = defaults.string(forKey: "RoxyAnime4KQuality") ?? "automatic"
        let mode = defaults.string(forKey: "RoxyAnime4KMode") ?? "standard"
        let configuration = "\(input.width)x\(input.height):\(outputSize):\(storedQuality):\(custom):\(mode)"
        if configuration != adaptationKey {
            adaptationKey = configuration
            frameBudget = RoxyQualityBudget(quality: .recommended(device: device))
            memoryQuality = .high
            strongMemoryFallback = false
            rejectedPlans.removeAll()
        }
        let quality = requestedQuality()
        activeQuality = quality
        selectionReason = ""
        if ProcessInfo.processInfo.thermalState == .serious { selectionReason = "Reduced for device temperature" }
        else if ProcessInfo.processInfo.isLowPowerModeEnabled { selectionReason = "Reduced for Low Power Mode" }
        else if memoryQuality.rawValue < (RoxyQuality.allCases.first(where: { $0.name == storedQuality }) ?? frameBudget.quality).rawValue {
            selectionReason = "Reduced to fit video memory"
        } else if storedQuality == "automatic", quality != .recommended(device: device) {
            selectionReason = "Auto is balancing playback; quality recovers with GPU headroom"
        }
        var names = custom == "preset" ? (manifest.presets[quality.name] ?? []) : [custom]
        selectedMode = custom == "preset" && ["soft", "strong"].contains(mode) ? mode : "standard"
        if custom == "preset", selectedMode == "soft" {
            names = names.map { name in
                if name.hasPrefix("Anime4K_Restore_CNN_") {
                    return name.replacingOccurrences(of: "Anime4K_Restore_CNN_", with: "Anime4K_Restore_CNN_Soft_")
                }
                return quality == .low ? name.replacingOccurrences(of: "Anime4K_Upscale_CNN_", with: "Anime4K_Upscale_Denoise_CNN_") : name
            }
        } else if custom == "preset", selectedMode == "strong" {
            if !strongMemoryFallback, quality != .low, outputSize.x >= input.width * 2 && outputSize.y >= input.height * 2 {
                // Upstream Mode A+A: restore at source resolution, upscale,
                // restore with a smaller model, then upscale only when needed.
                // Different model variants preserve each shader's local SAVE
                // namespace and avoid reusing the same shader twice.
                if quality == .medium {
                    names = names.map { $0 == "Anime4K_Restore_CNN_S" ? "Anime4K_Restore_CNN_M" : $0 }
                }
                names.append(quality == .high ? "Anime4K_Restore_CNN_M" : "Anime4K_Restore_CNN_S")
                names.append("Anime4K_AutoDownscalePre_x4")
                names.append(quality == .high ? "Anime4K_Upscale_CNN_x2_M" : "Anime4K_Upscale_CNN_x2_S")
            } else {
                selectedMode = "standard"
                let explanation: String
                if strongMemoryFallback { explanation = "Strong exceeds video memory; using Standard" }
                else if quality == .low { explanation = "Strong requires Medium or High; using Standard" }
                else { explanation = "Strong requires at least 2× display scaling; using Standard" }
                selectionReason = selectionReason.isEmpty ? explanation : selectionReason + "; " + explanation
            }
        }
        guard !names.isEmpty, names.allSatisfy({ shadersByName[$0] != nil }) else {
            throw RoxyShaderError.invalid("Unknown Anime4K shader selection")
        }
        for name in names {
            if let shader = shadersByName[name] { load(shader) }
        }
        guard names.allSatisfy({ compiled[$0] != nil }) else {
            status = failed.isDisjoint(with: names) ? "Preparing Anime4K" : "Anime4K shader failed; original video"
            return input
        }
        let key = "\(names.joined(separator: ",")):\(input.width)x\(input.height):\(outputSize):\(quality.rawValue)"
        if rejectedPlans.contains(key) {
            status = "Anime4K: memory limit — original video"
            return input
        }
        if key != planKey {
            resetMemory()
            do {
                try makePlan(names: names, inputSize: SIMD2(input.width, input.height),
                             outputSize: outputSize, memoryLimit: quality.memoryLimit(device: device))
            } catch {
                // A failed device allocation may leave earlier slots alive.
                // Release the incomplete plan before showing the original.
                resetMemory()
                rejectedPlans.insert(key)
                if custom == "preset", selectedMode == "strong" {
                    // Retain the selected model size before reducing its
                    // quality: a second restoration is optional extra work.
                    strongMemoryFallback = true
                    selectionReason = "Strong exceeds video memory; using Standard"
                } else if custom == "preset", quality != .low {
                    memoryQuality = quality == .high ? .medium : .low
                    selectionReason = "Reduced to fit video memory"
                }
                status = error.localizedDescription
                onChange?()
                throw error
            }
            planKey = key
        }
        var versions: [Int: MTLTexture] = [0: input]
        for operation in operations {
            guard let destination = textures[operation.output],
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RoxyShaderError.invalid("Metal encoder allocation failed")
            }
            encoder.label = operation.pass.shader.description
            encoder.setComputePipelineState(operation.pass.pipeline)
            encoder.setSamplerState(sampler, index: 0)
            for (index, version) in operation.inputs.enumerated() {
                guard let texture = versions[version] else { encoder.endEncoding(); throw RoxyShaderError.invalid("Missing pass input") }
                encoder.setTexture(texture, index: index)
            }
            encoder.setTexture(destination, index: operation.inputs.count)
            let width = operation.pass.pipeline.threadExecutionWidth
            let height = max(1, min(8, operation.pass.pipeline.maxTotalThreadsPerThreadgroup / width))
            let group = MTLSize(width: width, height: height, depth: 1)
            // Uniform groups work on older Apple GPUs, including A9/A10.
            encoder.dispatchThreadgroups(MTLSize(width: (operation.size.x + width - 1) / width,
                                                 height: (operation.size.y + height - 1) / height, depth: 1),
                                         threadsPerThreadgroup: group)
            encoder.endEncoding()
            versions[operation.output] = destination
        }
        status = "Anime4K \(custom == "preset" ? quality.name.capitalized : custom)"
        if custom == "preset", selectedMode != "standard" { status += " · \(selectedMode.capitalized)" }
        if operations.isEmpty { status += " · Native resolution" }
        else if (textures[finalVersion]?.width ?? input.width) <= input.width { status += " · Restoring" }
        if !selectionReason.isEmpty { status += " · \(selectionReason)" }
        encodedPassCount = operations.count
        // Native Low has no CNN passes. Its real presentation cost can still
        // establish headroom for Auto to probe restoration again after 8s.
        hasTimingSample = true
        return versions[finalVersion] ?? input
    }

    private func makePlan(names: [String], inputSize: SIMD2<Int>, outputSize: SIMD2<Int>, memoryLimit: Int) throws {
        operations = []
        finalVersion = 0
        var nextVersion = 1
        var mainSize = inputSize
        var deferred: [(pass: CompiledPass, mapping: [String: Int], sizes: [String: SIMD2<Int>])] = []
        func append(_ pass: CompiledPass, mapping: inout [String: Int], sizes: inout [String: SIMD2<Int>]) throws {
            mapping["HOOKED"] = mapping["MAIN"]
            sizes["HOOKED"] = sizes["MAIN"]
            // mpv skips a hook if an earlier conditional pass did not produce
            // one of its BIND textures (notably DTD at native resolution).
            if pass.shader.binds.contains(where: { mapping[$0] == nil }) { return }
            if let condition = pass.shader.when,
               try RoxyExpression.evaluate(condition, sizes: sizes) == 0 { return }
            let width = try pass.shader.width.map { try RoxyExpression.evaluate($0, sizes: sizes) } ?? Double(sizes["MAIN"]!.x)
            let height = try pass.shader.height.map { try RoxyExpression.evaluate($0, sizes: sizes) } ?? Double(sizes["MAIN"]!.y)
            guard width >= 1, height >= 1, width <= 16384, height <= 16384 else {
                throw RoxyShaderError.invalid("Anime4K texture dimensions exceed device limits")
            }
            let size = SIMD2(Int(width.rounded()), Int(height.rounded()))
            let inputs = try pass.shader.binds.map { bind -> Int in
                guard let version = mapping[bind] else { throw RoxyShaderError.invalid("Unbound texture: \(bind)") }
                return version
            }
            let components = pass.shader.components ?? 4
            let format: MTLPixelFormat = components == 1 ? .r16Float : (components == 2 ? .rg16Float : .rgba16Float)
            operations.append(Operation(pass: pass, inputs: inputs, output: nextVersion, size: size, format: format))
            let saved = pass.shader.save ?? "MAIN"
            mapping[saved] = nextVersion
            sizes[saved] = size
            nextVersion += 1
        }
        for name in names {
            // Temporary SAVE names belong to one shader file. MAIN is the
            // previous file's final output, never an obsolete intermediate.
            var mapping = ["MAIN": finalVersion, "HOOKED": finalVersion, "NATIVE": 0]
            var sizes = ["MAIN": mainSize, "HOOKED": mainSize, "NATIVE": inputSize, "OUTPUT": outputSize]
            for pass in compiled[name] ?? [] {
                if pass.shader.hook == "PREKERNEL" {
                    // Clamp_Highlights samples source statistics at MAIN but
                    // clamps only after every restore/upscale stage. Retain its
                    // file-local SAVE bindings until that final hook.
                    deferred.append((pass, mapping, sizes))
                } else {
                    try append(pass, mapping: &mapping, sizes: &sizes)
                }
            }
            finalVersion = mapping["MAIN"] ?? finalVersion
            mainSize = sizes["MAIN"] ?? mainSize
        }
        for item in deferred {
            var mapping = item.mapping
            var sizes = item.sizes
            mapping["MAIN"] = finalVersion
            sizes["MAIN"] = mainSize
            try append(item.pass, mapping: &mapping, sizes: &sizes)
            finalVersion = mapping["MAIN"] ?? finalVersion
            mainSize = sizes["MAIN"] ?? mainSize
        }
        // Allocate by liveness. Reuse a texture only after its final reader.
        // Metal command ordering and tracked resource hazards serialize reuse.
        var lastUse: [Int: Int] = [finalVersion: operations.count]
        for (index, operation) in operations.enumerated() {
            for input in operation.inputs { lastUse[input] = max(lastUse[input] ?? 0, index) }
        }
        var slots: [(texture: MTLTexture, availableAfter: Int)] = []
        var bytes = 0
        for (index, operation) in operations.enumerated() {
            let reusable = slots.indices.first { slot in
                let value = slots[slot]
                return value.availableAfter < index && value.texture.width == operation.size.x &&
                    value.texture.height == operation.size.y && value.texture.pixelFormat == operation.format
            }
            let texture: MTLTexture
            if let slot = reusable {
                texture = slots[slot].texture
                slots[slot].availableAfter = lastUse[operation.output] ?? index
            } else {
                let channels = operation.format == .r16Float ? 1 : (operation.format == .rg16Float ? 2 : 4)
                bytes += operation.size.x * operation.size.y * channels * 2
                guard bytes <= memoryLimit else {
                    textures.removeAll()
                    throw RoxyShaderError.invalid("Anime4K memory budget exceeded; reducing quality")
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: operation.format,
                                                                          width: operation.size.x,
                                                                          height: operation.size.y, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                guard let created = device.makeTexture(descriptor: descriptor) else {
                    throw RoxyShaderError.invalid("Cannot allocate Anime4K intermediate texture")
                }
                texture = created
                slots.append((texture, lastUse[operation.output] ?? index))
            }
            textures[operation.output] = texture
        }
    }
}
