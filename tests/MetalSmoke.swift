// Run with the real Metal device when present. Hosted runners may have no GPU;
// shader compilation and Swift typechecking still run on those runners.
import Foundation
import Metal

@main
enum MetalSmoke {
    static func validateQualityBudget() {
        let frameBudget = 1.0 / 24.0
        var budget = RoxyQualityBudget(quality: .high)
        guard !budget.observe(gpuTime: frameBudget, frameBudget: frameBudget, maximum: .high),
              budget.quality == .high else { fatalError("One slow frame must not lower Auto quality") }
        for _ in 0..<240 { _ = budget.observe(gpuTime: frameBudget, frameBudget: frameBudget, maximum: .high) }
        guard budget.quality == .low else { fatalError("Sustained overload must lower Auto quality") }
        for _ in 0..<1_000 { _ = budget.observe(gpuTime: 0.001, frameBudget: frameBudget, maximum: .high) }
        guard budget.quality == .high else { fatalError("Auto quality must recover after sustained headroom") }
        budget = RoxyQualityBudget(quality: .low)
        for _ in 0..<1_000 { _ = budget.observe(gpuTime: 0.001, frameBudget: frameBudget, maximum: .medium) }
        guard budget.quality == .medium else { fatalError("Auto recovery must respect the device maximum") }
        for sample in [0.0, Double.nan, Double.infinity] {
            guard !budget.observe(gpuTime: sample, frameBudget: frameBudget, maximum: .high) else {
                fatalError("Invalid GPU measurements must not change quality")
            }
        }
        print("PASS: deterministic Auto quality overload, recovery and device ceiling")
    }

    static func readyOutput(engine: RoxyAnime4KEngine, input: MTLTexture,
                            target: SIMD2<Int>, queue: MTLCommandQueue) throws -> (MTLTexture, MTLCommandBuffer) {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            let command = queue.makeCommandBuffer()!
            let output = try engine.encode(input: input, outputSize: target, commandBuffer: command)
            if engine.encodedPassCount > 0 { return (output, command) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        fatalError("CNN failed to prepare: \(engine.status)")
    }

    static func readRGB(_ output: MTLTexture, command: MTLCommandBuffer, device: MTLDevice) -> [[Double]] {
        guard output.pixelFormat == .rgba16Float else { fatalError("Expected a four-channel CNN output") }
        let rowBytes = ((output.width * 8 + 255) / 256) * 256
        let result = device.makeBuffer(length: rowBytes * output.height, options: .storageModeShared)!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                  to: result, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * output.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { fatalError("Metal command failed: \(String(describing: command.error))") }
        return (0..<output.height).flatMap { y in
            let row = result.contents().advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            return (0..<output.width).map { x in
                (0..<3).map { channel in
                    let value = Double(Float16(bitPattern: row[x * 4 + channel]))
                    guard value.isFinite else { fatalError("Non-finite CNN output") }
                    return value
                }
            }
        }
    }

    static func validateHighlightLimits(_ output: [[Double]], width: Int, height: Int,
                                         input: [[Double]], inputWidth: Int, inputHeight: Int) {
        let weights = [0.299, 0.587, 0.114]
        let luminance = input.map { pixel in zip(pixel.prefix(3), weights).map { $0.0 * $0.1 }.reduce(0, +) }
        // Independent CPU version of the upstream 5x5 source maximum. The two
        // r16Float statistics passes round the same maximum to half precision.
        let statistics = (0..<inputHeight).flatMap { y in
            (0..<inputWidth).map { x in
                var maximum = 0.0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let sx = min(inputWidth - 1, max(0, x + dx))
                        let sy = min(inputHeight - 1, max(0, y + dy))
                        maximum = max(maximum, luminance[sy * inputWidth + sx])
                    }
                }
                return Double(Float16(maximum))
            }
        }
        func value(_ x: Int, _ y: Int) -> Double {
            statistics[min(inputHeight - 1, max(0, y)) * inputWidth + min(inputWidth - 1, max(0, x))]
        }
        for y in 0..<height {
            for x in 0..<width {
                let sx = (Double(x) + 0.5) * Double(inputWidth) / Double(width) - 0.5
                let sy = (Double(y) + 0.5) * Double(inputHeight) / Double(height) - 0.5
                let ix = Int(floor(sx)), iy = Int(floor(sy))
                let fx = sx - floor(sx), fy = sy - floor(sy)
                let top = value(ix, iy) * (1 - fx) + value(ix + 1, iy) * fx
                let bottom = value(ix, iy + 1) * (1 - fx) + value(ix + 1, iy + 1) * fx
                let limit = top * (1 - fy) + bottom * fy
                let actual = zip(output[y * width + x], weights).map { $0.0 * $0.1 }.reduce(0, +)
                guard actual <= limit + 0.003 else {
                    fatalError("PREKERNEL highlight clamp exceeded original local source maximum: \(actual) > \(limit)")
                }
            }
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resource = root.appendingPathComponent("vlc-ios-master/Resources/RoxyAnime4K")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tests/fixtures/cnn_s_reference.json"))) as! [String: Any]
        let width = fixture["width"] as! Int, height = fixture["height"] as! Int
        let expected = fixture["expectedRGB"] as! [[Double]]
        let tolerance = fixture["tolerance"] as! Double
        let sizes: [String: SIMD2<Int>] = ["MAIN": SIMD2(640, 360), "OUTPUT": SIMD2(1280, 720)]
        guard try RoxyExpression.evaluate("OUTPUT.w MAIN.w / 1.2 >", sizes: sizes) == 1 else { fatalError("Expression evaluation failed") }
        do {
            _ = try RoxyExpression.evaluate("MAIN.w 0 /", sizes: sizes)
            fatalError("Invalid expression was accepted")
        } catch RoxyShaderError.invalid { }
        validateQualityBudget()
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP GPU parity: runner has no Metal device. Expression checks passed.")
            return
        }
        UserDefaults.standard.set(true, forKey: "RoxyAnime4KEnabled")
        UserDefaults.standard.set("low", forKey: "RoxyAnime4KQuality")
        UserDefaults.standard.set("preset", forKey: "RoxyAnime4KShader")
        UserDefaults.standard.set("standard", forKey: "RoxyAnime4KMode")
        UserDefaults.standard.set(false, forKey: "RoxyAnime4KPreviewOriginal")
        let engine = try RoxyAnime4KEngine(device: device, root: resource)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let input = device.makeTexture(descriptor: descriptor)!
        let values = fixture["input"] as! [[Double]]
        let bytes = values.flatMap { pixel in pixel.map { UInt8(($0 * 255).rounded()) } }
        bytes.withUnsafeBytes { data in
            input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: data.baseAddress!, bytesPerRow: width * 4)
        }
        let queue = device.makeCommandQueue()!
        let (output, command) = try readyOutput(engine: engine, input: input,
                                                target: SIMD2(width * 2, height * 2), queue: queue)
        let actual = readRGB(output, command: command, device: device)
        var maximumError = 0.0
        for pixel in actual.indices {
            for channel in 0..<3 { maximumError = max(maximumError, abs(actual[pixel][channel] - expected[pixel][channel])) }
        }
        guard maximumError <= tolerance else { fatalError("CNN GPU/CPU parity failed: \(maximumError) > \(tolerance)") }
        print("PASS: original CNN small CPU/Metal parity; maximum error \(maximumError)")

        // Manual High must remain the user's choice after a demanding scene.
        // Synthetic timing samples make this deterministic on any Metal host.
        UserDefaults.standard.set("high", forKey: "RoxyAnime4KQuality")
        let (high, highCommand) = try readyOutput(engine: engine, input: input,
                                                  target: SIMD2(width * 2, height * 2), queue: queue)
        let highRGB = readRGB(high, command: highCommand, device: device)
        validateHighlightLimits(highRGB, width: high.width, height: high.height,
                                input: values, inputWidth: width, inputHeight: height)
        for _ in 0..<240 { engine.reportFrameTime(0.2, budget: 1.0 / 24.0) }
        let (afterLoad, afterLoadCommand) = try readyOutput(engine: engine, input: input,
                                                            target: SIMD2(width * 2, height * 2), queue: queue)
        guard engine.selectedQuality == "high" else { fatalError("Manual High was silently timing-demoted") }
        _ = readRGB(afterLoad, command: afterLoadCommand, device: device)
        print("PASS: manual High survives sustained synthetic GPU overload")

        // At native size High must still restore lines, rather than bypassing
        // every CNN. Read the real texture and prove it changes this nonflat input.
        let (native, nativeCommand) = try readyOutput(engine: engine, input: input,
                                                      target: SIMD2(width, height), queue: queue)
        guard native.width == width, native.height == height, native !== input else {
            fatalError("Native High must restore at the source resolution")
        }
        let restored = readRGB(native, command: nativeCommand, device: device)
        var restorationDelta = 0.0
        for pixel in restored.indices {
            for channel in 0..<3 { restorationDelta = max(restorationDelta, abs(restored[pixel][channel] - values[pixel][channel])) }
        }
        guard restorationDelta > 0.0001 else { fatalError("Native High produced no measurable enhancement") }
        print("PASS: native-size High runs restoration; maximum source difference \(restorationDelta)")

        if RoxyQuality.recommended(device: device) != .low {
            UserDefaults.standard.set("automatic", forKey: "RoxyAnime4KQuality")
            let (nativeAuto, nativeAutoCommand) = try readyOutput(engine: engine, input: input,
                                                                  target: SIMD2(width, height), queue: queue)
            guard nativeAuto !== input, nativeAuto.width == width, nativeAuto.height == height else {
                fatalError("Auto must retain native-size restoration on a capable GPU")
            }
            _ = readRGB(nativeAuto, command: nativeAutoCommand, device: device)
            print("PASS: Auto retains native-size restoration on a capable GPU")
            UserDefaults.standard.set("high", forKey: "RoxyAnime4KQuality")
        }

        var standardRGB: [[Double]] = []
        for mode in ["standard", "soft", "strong"] {
            UserDefaults.standard.set(mode, forKey: "RoxyAnime4KMode")
            let (texture, commands) = try readyOutput(engine: engine, input: input,
                                                      target: SIMD2(width * 4, height * 4), queue: queue)
            guard engine.selectedMode == mode else { fatalError("High \(mode) mode failed to become active") }
            let samples = readRGB(texture, command: commands, device: device)
            validateHighlightLimits(samples, width: texture.width, height: texture.height,
                                    input: values, inputWidth: width, inputHeight: height)
            if mode == "standard" { standardRGB = samples }
            else if mode == "soft" {
                guard samples.count == standardRGB.count else { fatalError("Soft must preserve Standard output size") }
                let difference = zip(samples, standardRGB).flatMap { pair in
                    zip(pair.0, pair.1).map { abs($0.0 - $0.1) }
                }.max() ?? 0
                guard difference > 0.0001 else { fatalError("Soft and Standard used identical mathematical processing") }
            } else {
                guard texture.width == width * 4, texture.height == height * 4 else {
                    fatalError("Strong must run the second upstream upscale at 4x display size")
                }
            }
            print("PASS: High \(mode) produces finite enhanced pixels and respects original highlight statistics")
        }
    }
}
