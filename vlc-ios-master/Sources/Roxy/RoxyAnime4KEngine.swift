// Roxy Player. Anime4K shader weights: Copyright (c) 2019-2021 bloc97, MIT.
import Foundation
import Metal

struct RoxyShaderPass: Decodable {
    let description: String
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

// Confined to the renderer's main thread after construction. Pipelines compile
// on a separate serial queue and are published only when the complete chain is
// ready. The original frame remains visible while compilation is in progress.
final class RoxyAnime4KEngine {
    private struct CompiledPass {
        let shader: RoxyShaderPass
        let pipeline: MTLComputePipelineState
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
    private let compiler = DispatchQueue(label: "player.roxy.anime4k.compiler", qos: .utility)
    private var compiled: [String: [CompiledPass]] = [:]
    private var compiling = Set<String>()
    private var failed = Set<String>()
    private var rejectedPlans = Set<String>()
    private var textures: [Int: MTLTexture] = [:]
    private var planKey = ""
    private var operations: [Operation] = []
    private var finalVersion = 0
    private var budgetQuality = RoxyQuality.high
    private var activeQuality = RoxyQuality.low
    private var expensiveFrames = 0
    var onChange: (() -> Void)?
    private(set) var status = "Preparing Anime4K"

    init(device: MTLDevice, root: URL) throws {
        self.device = device
        self.root = root
        manifest = try JSONDecoder().decode(RoxyShaderManifest.self,
                                            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schema == 1 else { throw RoxyShaderError.invalid("Unsupported Anime4K manifest") }
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
        expensiveFrames = seconds > budget * 0.85 ? expensiveFrames + 1 : max(0, expensiveFrames - 1)
        if expensiveFrames >= 30 {
            expensiveFrames = 0
            if activeQuality == .high { budgetQuality = .medium }
            else if activeQuality == .medium { budgetQuality = .low }
            else { return }
            resetMemory()
        }
    }

    private func requestedQuality() -> RoxyQuality {
        let stored = UserDefaults.standard.string(forKey: "RoxyAnime4KQuality") ?? "automatic"
        var quality = RoxyQuality.allCases.first(where: { $0.name == stored }) ?? .recommended(device: device)
        let process = ProcessInfo.processInfo
        if process.thermalState == .serious || process.isLowPowerModeEnabled { quality = .low }
        return RoxyQuality(rawValue: min(quality.rawValue, budgetQuality.rawValue)) ?? .low
    }

    private func load(_ shader: RoxyShader) {
        guard compiled[shader.name] == nil, !compiling.contains(shader.name), !failed.contains(shader.name) else { return }
        compiling.insert(shader.name)
        compiler.async { [weak self] in
            guard let self = self else { return }
            do {
                let binary = self.root.appendingPathComponent(shader.name + ".metallib")
                let library: MTLLibrary
                if FileManager.default.fileExists(atPath: binary.path),
                   let precompiled = try? self.device.makeLibrary(URL: binary) {
                    library = precompiled
                } else {
                    let source = try String(contentsOf: self.root.appendingPathComponent(shader.name + ".metal"), encoding: .utf8)
                    let options = MTLCompileOptions()
                    options.fastMathEnabled = false
                    options.languageVersion = .version2_3
                    library = try self.device.makeLibrary(source: source, options: options)
                }
                let passes = try shader.passes.map { pass -> CompiledPass in
                    guard let function = library.makeFunction(name: pass.function) else {
                        throw RoxyShaderError.invalid("Missing Metal function: \(pass.function)")
                    }
                    return CompiledPass(shader: pass, pipeline: try self.device.makeComputePipelineState(function: function))
                }
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
        let defaults = UserDefaults.standard
        if (defaults.object(forKey: "RoxyAnime4KEnabled") as? Bool) == false {
            status = "Anime4K off"
            return input
        }
        if ProcessInfo.processInfo.thermalState == .critical {
            status = "Anime4K paused: device temperature"
            resetMemory()
            return input
        }
        let quality = requestedQuality()
        activeQuality = quality
        let custom = defaults.string(forKey: "RoxyAnime4KShader") ?? "preset"
        let names = custom == "preset" ? (manifest.presets[quality.name] ?? []) : [custom]
        guard !names.isEmpty, names.allSatisfy({ name in manifest.shaders.contains { $0.name == name } }) else {
            throw RoxyShaderError.invalid("Unknown Anime4K shader selection")
        }
        for name in names {
            if let shader = manifest.shaders.first(where: { $0.name == name }) { load(shader) }
        }
        guard names.allSatisfy({ compiled[$0] != nil }) else {
            status = failed.isDisjoint(with: names) ? "Preparing Anime4K" : "Anime4K shader failed; original video"
            return input
        }
        let key = "\(names.joined(separator: ",")):\(input.width)x\(input.height):\(outputSize):\(quality.rawValue)"
        if rejectedPlans.contains(key) { return input }
        if key != planKey {
            resetMemory()
            do {
                try makePlan(names: names, inputSize: SIMD2(input.width, input.height),
                             outputSize: outputSize, memoryLimit: quality.memoryLimit)
            } catch {
                rejectedPlans.insert(key)
                budgetQuality = quality == .high ? .medium : .low
                status = error.localizedDescription
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
        return versions[finalVersion] ?? input
    }

    private func makePlan(names: [String], inputSize: SIMD2<Int>, outputSize: SIMD2<Int>, memoryLimit: Int) throws {
        operations = []
        finalVersion = 0
        var nextVersion = 1
        var mainSize = inputSize
        for name in names {
            // Temporary SAVE names belong to one shader file. MAIN is the
            // previous file's final output, never an obsolete intermediate.
            var mapping = ["MAIN": finalVersion, "HOOKED": finalVersion, "NATIVE": 0]
            var sizes = ["MAIN": mainSize, "HOOKED": mainSize, "NATIVE": inputSize, "OUTPUT": outputSize]
            for pass in compiled[name] ?? [] {
                mapping["HOOKED"] = mapping["MAIN"]
                sizes["HOOKED"] = sizes["MAIN"]
                // mpv skips a hook if an earlier conditional pass did not
                // produce one of its BIND textures (notably DTD at 1x).
                if pass.shader.binds.contains(where: { mapping[$0] == nil }) { continue }
                if let condition = pass.shader.when,
                   try RoxyExpression.evaluate(condition, sizes: sizes) == 0 { continue }
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
