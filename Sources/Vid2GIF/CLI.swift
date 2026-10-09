import Foundation

/// Headless mode: `vid2gif convert input.mov output.gif|output.webm [options]`
enum CLI {
    static var shouldRun: Bool {
        CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "convert"
    }

    static func run() -> Never {
        let input: URL
        let output: URL
        let settings: ExportSettings
        do {
            (input, output, settings) = try parse(Array(CommandLine.arguments.dropFirst(2)))
        } catch {
            fail(error.localizedDescription + "\n" + usage)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        let exporter = MediaExporter()

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

    private static let usage = """
    usage: vid2gif convert <input> <output.gif|output.webm> [options]
      --width N       output width in px (default 640)
      --fps N         output frame rate, 1–60 (default 15)
      --start S       trim start seconds
      --end S         trim end seconds
      --speed X       playback speed, 0.25–4 (default 1)
      --quality Q     WebM: compact | balanced | high (default balanced)
      --no-audio      WebM: omit source audio
      --colors N      GIF: palette size, 2–256 (default 256)
      --dither M      GIF: bayer | fs | none (default bayer)
      --no-loop       GIF: play once
      --no-delta      GIF: disable inter-frame delta encoding
    """

    struct ArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ args: [String]) throws -> (URL, URL, ExportSettings) {
        var settings = ExportSettings()
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let flag = args[index]
            index += 1
            if !flag.hasPrefix("--") { positional.append(flag); continue }
            switch flag {
            case "--no-loop": settings.loopForever = false; continue
            case "--no-delta": settings.useDelta = false; continue
            case "--no-audio": settings.includeAudio = false; continue
            default: break
            }
            guard ["--width", "--fps", "--start", "--end", "--speed", "--quality", "--colors", "--dither"].contains(flag) else {
                throw ArgumentError(message: "Unknown option: \(flag)")
            }
            guard index < args.count else { throw ArgumentError(message: "Missing value for \(flag)") }
            let value = args[index]
            index += 1
            func number() throws -> Double {
                guard let n = Double(value), n.isFinite else { throw ArgumentError(message: "Invalid number for \(flag): \(value)") }
                return n
            }
            func integer() throws -> Int {
                guard let n = Int(value) else { throw ArgumentError(message: "Invalid integer for \(flag): \(value)") }
                return n
            }
            switch flag {
            case "--width": settings.outputWidth = try integer()
            case "--fps": settings.fps = try number()
            case "--start": settings.startTime = try number()
            case "--end": settings.endTime = try number()
            case "--speed": settings.speed = try number()
            case "--colors": settings.maxColors = min(255, try integer())
            case "--quality":
                guard let quality = VideoQuality(rawValue: value.lowercased()) else {
                    throw ArgumentError(message: "Unknown quality: \(value) (compact|balanced|high)")
                }
                settings.videoQuality = quality
            case "--dither":
                switch value.lowercased() {
                case "bayer": settings.dither = .bayer
                case "fs", "diffusion": settings.dither = .floydSteinberg
                case "none": settings.dither = .none
                default: throw ArgumentError(message: "Unknown dither mode: \(value) (bayer|fs|none)")
                }
            default: break
            }
        }
        guard positional.count == 2 else { throw ArgumentError(message: "Specify an input video and an output file.") }
        let input = URL(fileURLWithPath: positional[0])
        let output = URL(fileURLWithPath: positional[1])
        guard let format = ExportFormat(rawValue: output.pathExtension.lowercased()) else {
            throw ArgumentError(message: "Output must have a .gif or .webm extension.")
        }
        settings.format = format
        try settings.validate()
        return (input, output, settings)
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        exit(2)
    }
}
