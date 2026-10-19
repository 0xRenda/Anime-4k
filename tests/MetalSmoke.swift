// Run with the real Metal device when present. Hosted runners may have no GPU;
// shader compilation and Swift typechecking still run on those runners.
import Foundation
import Metal

@main
enum MetalSmoke {
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP GPU parity: runner has no Metal device. Expression checks passed.")
            return
        }
        UserDefaults.standard.set(true, forKey: "RoxyAnime4KEnabled")
        UserDefaults.standard.set("low", forKey: "RoxyAnime4KQuality")
        UserDefaults.standard.set("preset", forKey: "RoxyAnime4KShader")
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
        var command = queue.makeCommandBuffer()!
        var output = try engine.encode(input: input, outputSize: SIMD2(width * 2, height * 2), commandBuffer: command)
        let deadline = Date().addingTimeInterval(90)
        while output === input && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            command = queue.makeCommandBuffer()!
            output = try engine.encode(input: input, outputSize: SIMD2(width * 2, height * 2), commandBuffer: command)
        }
        guard output !== input else { fatalError("Small CNN failed to prepare: \(engine.status)") }
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
        var maximumError = 0.0
        for y in 0..<output.height {
            let row = result.contents().advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<output.width {
                for channel in 0..<3 {
                    let value = Double(Float16(bitPattern: row[x * 4 + channel]))
                    let error = abs(value - expected[y * output.width + x][channel])
                    guard value.isFinite else { fatalError("Non-finite CNN output") }
                    maximumError = max(maximumError, error)
                }
            }
        }
        guard maximumError <= tolerance else { fatalError("CNN GPU/CPU parity failed: \(maximumError) > \(tolerance)") }
        print("PASS: original CNN small CPU/Metal parity; maximum error \(maximumError)")
    }
}
