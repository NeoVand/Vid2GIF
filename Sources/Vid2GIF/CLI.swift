import Foundation

/// Headless mode: `vid2gif convert input.mov output.gif [options]`
enum CLI {
    static var shouldRun: Bool {
        CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "convert"
    }

    static func run() -> Never {
        var args = Array(CommandLine.arguments.dropFirst(2))
        var positional: [String] = []
        var settings = ExportSettings()

        func popValue(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }

        if let v = popValue("--width"), let n = Int(v) { settings.outputWidth = n }
        if let v = popValue("--fps"), let n = Double(v) { settings.fps = n }
        if let v = popValue("--start"), let n = Double(v) { settings.startTime = n }
        if let v = popValue("--end"), let n = Double(v) { settings.endTime = n }
        if let v = popValue("--speed"), let n = Double(v) { settings.speed = n }
        if let v = popValue("--colors"), let n = Int(v) { settings.maxColors = min(255, max(2, n)) }
        if let v = popValue("--dither") {
            switch v.lowercased() {
            case "bayer": settings.dither = .bayer
            case "fs", "diffusion": settings.dither = .floydSteinberg
            case "none": settings.dither = .none
            default: fail("unknown dither mode '\(v)' (bayer|fs|none)")
            }
        }
        if let i = args.firstIndex(of: "--no-loop") { args.remove(at: i); settings.loopForever = false }
        if let i = args.firstIndex(of: "--no-delta") { args.remove(at: i); settings.useDelta = false }

        positional = args.filter { !$0.hasPrefix("--") }
        guard positional.count == 2 else {
            fail("""
            usage: vid2gif convert <input> <output.gif> [options]
              --width N       output width in px (default 640)
              --fps N         output frame rate (default 15)
              --start S       trim start seconds
              --end S         trim end seconds
              --speed X       playback speed multiplier (default 1)
              --colors N      palette size ≤255 (default 255)
              --dither M      bayer | fs | none (default bayer)
              --no-loop       play once
              --no-delta      disable inter-frame delta encoding
            """)
        }

        let input = URL(fileURLWithPath: positional[0])
        let output = URL(fileURLWithPath: positional[1])

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        let exporter = GIFExporter()

        Task {
            do {
                var lastLine = 0
                let result = try await exporter.export(
                    assetURL: input, to: output, settings: settings
                ) { p, msg in
                    let pct = Int(p * 100)
                    if pct / 10 != lastLine {
                        lastLine = pct / 10
                        FileHandle.standardError.write("[\(pct)%] \(msg)\n".data(using: .utf8)!)
                    }
                }
                let mb = Double(result.bytes) / 1_048_576
                print(String(
                    format: "OK %dx%d, %d frames, %.2f MB, %.2fs",
                    result.size.width, result.size.height, result.frames, mb, result.wallTime
                ))
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(exitCode)
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        exit(2)
    }
}
