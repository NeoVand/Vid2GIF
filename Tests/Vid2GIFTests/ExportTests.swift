import XCTest
@testable import Vid2GIF

final class ExportTests: XCTestCase {
    func testCLISelectsFormatAndVideoSettings() throws {
        let (_, output, settings) = try CLI.parse([
            "input with spaces.mov", "output.WEBM", "--width", "480", "--fps", "24",
            "--start", "1", "--end", "5", "--speed", "2", "--quality", "high", "--no-audio"
        ])
        XCTAssertEqual(output.pathExtension, "WEBM")
        XCTAssertEqual(settings.format, .webm)
        XCTAssertEqual(settings.outputWidth, 480)
        XCTAssertEqual(settings.fps, 24)
        XCTAssertEqual(settings.speed, 2)
        XCTAssertEqual(settings.videoQuality, .high)
        XCTAssertFalse(settings.includeAudio)
        XCTAssertEqual(try CLI.parse(["input.mov", "output.gif"]).2.format, .gif)
    }

    func testInvalidCLISettingsAreRejected() {
        for args in [
            ["input.mov", "output.mp4"],
            ["input.mov", "output.webm", "--speed", "0"],
            ["input.mov", "output.webm", "--fps", "nan"],
            ["input.mov", "output.webm", "--width", "-5"],
            ["input.mov", "output.webm", "--start", "4", "--end", "2"],
            ["input.mov", "output.webm", "--quality", "unknown"],
            ["input.mov", "output.webm", "--quality"],
            ["input.mov", "output.webm", "--unknown"]
        ] {
            XCTAssertThrowsError(try CLI.parse(args), "Expected rejection: \(args)")
        }
    }

    func testAudioSpeedStagesStayInPitchPreservingRange() {
        for speed in [0.25, 0.4, 1, 1.75, 2, 3, 4] {
            let stages = WebMExporter.audioFilter(speed: speed).split(separator: ",").dropFirst()
            let rates = stages.compactMap { Double($0.split(separator: "=")[1]) }
            XCTAssertTrue(rates.allSatisfy { (0.5...2).contains($0) })
            XCTAssertEqual(rates.reduce(1, *), speed, accuracy: 0.00001)
        }
    }

    func testCancellationPreservesExistingFile() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for format in ExportFormat.allCases {
            let output = dir.appendingPathComponent("existing.\(format.rawValue)")
            let original = Data("existing user file".utf8)
            try original.write(to: output)
            var settings = ExportSettings()
            settings.format = format
            let exporter = MediaExporter()
            exporter.cancel()
            do {
                _ = try await exporter.export(assetURL: dir.appendingPathComponent("source.mov"), to: output, settings: settings) { _, _ in }
                XCTFail("Cancelled export succeeded")
            } catch ExportError.cancelled {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".vid2gif-") })
    }

    func testFailedExportPreservesExistingFile() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("existing.webm")
        let original = Data("existing user file".utf8)
        try original.write(to: output)
        var settings = ExportSettings()
        settings.format = .webm
        do {
            _ = try await MediaExporter().export(assetURL: dir.appendingPathComponent("missing.mov"), to: output, settings: settings) { _, _ in }
            XCTFail("Missing input succeeded")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["existing.webm"])
    }

    func testWebMEncodingHonorsTimingSizeAudioAndQuality() async throws {
        guard let ffmpeg = WebMExporter.executableURL else { throw XCTSkip("FFmpeg is not installed") }
        let probe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { throw XCTSkip("ffprobe is not installed") }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("test source.mp4")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=3", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-c:a", "aac", "-shortest", input.path])
        var settings = ExportSettings()
        settings.format = .webm
        settings.outputWidth = 160
        settings.fps = 12
        settings.startTime = 0.5
        settings.endTime = 2.5
        settings.speed = 2
        settings.videoQuality = .high
        let output = dir.appendingPathComponent("test output.webm")
        // Also exercise successful replacement of an existing destination.
        try Data("old".utf8).write(to: output)
        let result = try await MediaExporter().export(assetURL: input, to: output, settings: settings) { _, _ in }
        let metadata = try inspect(probe, output)
        let video = try XCTUnwrap(metadata.streams.first { $0.codec_type == "video" })
        XCTAssertEqual(video.codec_name, "vp9")
        XCTAssertEqual(video.width, 160)
        XCTAssertEqual(video.height, 120)
        XCTAssertEqual(video.r_frame_rate, "12/1")
        XCTAssertEqual(video.nb_read_frames, "12")
        XCTAssertEqual(metadata.streams.first { $0.codec_type == "audio" }?.codec_name, "opus")
        XCTAssertEqual(try XCTUnwrap(Double(metadata.format.duration)), 1, accuracy: 0.1)
        XCTAssertEqual(result.frames, 12)
        XCTAssertEqual(result.format, .webm)
        XCTAssertEqual(result.bytes, try Data(contentsOf: output).count)

        settings.videoQuality = .compact
        let compact = try await MediaExporter().export(assetURL: input, to: dir.appendingPathComponent("compact.webm"), settings: settings) { _, _ in }
        XCTAssertLessThan(compact.bytes, result.bytes)

        settings.speed = 0.25
        settings.includeAudio = false
        let slow = try await MediaExporter().export(assetURL: input, to: dir.appendingPathComponent("slow.webm"), settings: settings) { _, _ in }
        let slowMetadata = try inspect(probe, slow.url)
        XCTAssertEqual(slow.frames, 96)
        XCTAssertEqual(try XCTUnwrap(Double(slowMetadata.format.duration)), 8, accuracy: 0.1)
        XCTAssertFalse(slowMetadata.streams.contains { $0.codec_type == "audio" })

        // Silent sources remain exportable with Include audio enabled.
        let silent = dir.appendingPathComponent("silent.mp4")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-i", input.path, "-c:v", "copy", "-an", silent.path])
        settings.speed = 4
        settings.includeAudio = true
        let silentResult = try await MediaExporter().export(assetURL: silent, to: dir.appendingPathComponent("silent.webm"), settings: settings) { _, _ in }
        XCTAssertEqual(silentResult.frames, 6)
        XCTAssertFalse(try inspect(probe, silentResult.url).streams.contains { $0.codec_type == "audio" })

        // Existing GIF path remains functional through the shared exporter.
        settings.format = .gif
        settings.speed = 1
        let gif = try await MediaExporter().export(assetURL: input, to: dir.appendingPathComponent("regression.gif"), settings: settings) { _, _ in }
        XCTAssertEqual(gif.format, .gif)
        XCTAssertGreaterThan(gif.frames, 0)
        XCTAssertEqual(String(decoding: try Data(contentsOf: gif.url).prefix(6), as: UTF8.self), "GIF89a")

        // Cancel after the encoder process has actually launched.
        settings.format = .webm
        let cancelledOutput = dir.appendingPathComponent("cancelled.webm")
        let original = Data("keep this file".utf8)
        try original.write(to: cancelledOutput)
        let cancelledExporter = MediaExporter()
        do {
            _ = try await cancelledExporter.export(assetURL: input, to: cancelledOutput, settings: settings) { p, _ in
                if p == 0 { cancelledExporter.cancel() }
            }
            XCTFail("Running export ignored cancellation")
        } catch ExportError.cancelled {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: cancelledOutput), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".vid2gif-") })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Vid2GIF-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    private struct Metadata: Decodable {
        struct Stream: Decodable {
            let codec_type: String
            let codec_name: String
            let width: Int?
            let height: Int?
            let r_frame_rate: String?
            let nb_read_frames: String?
        }
        struct Format: Decodable { let duration: String }
        let streams: [Stream]
        let format: Format
    }

    private func inspect(_ probe: URL, _ file: URL) throws -> Metadata {
        let data = try run(probe, ["-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", file.path])
        return try JSONDecoder().decode(Metadata.self, from: data)
    }
}
