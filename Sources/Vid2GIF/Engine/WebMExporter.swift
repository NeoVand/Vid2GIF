import Foundation
import AVFoundation
import os

/// VP9 video + optional Opus audio. Arguments are passed directly to Process;
/// filenames and settings never go through a shell.
final class WebMExporter {
    private struct State {
        var cancelled = false
        var process: Process?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    static var executableURL: URL? {
        let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path
        let path = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":").map { String($0) + "/ffmpeg" }
        let candidates = [bundled].compactMap { $0 } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] + path
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            if let process = $0.process, process.isRunning { process.terminate() }
        }
    }

    /// Multiple atempo stages preserve pitch and avoid the sample-skipping path
    /// above 2×; every stage stays inside 0.5...2, including quarter speed.
    static func audioFilter(speed: Double) -> String {
        var remaining = speed
        var stages: [String] = []
        while remaining < 0.5 { stages.append("atempo=0.5"); remaining /= 0.5 }
        while remaining > 2 { stages.append("atempo=2"); remaining /= 2 }
        stages.append("atempo=\(remaining)")
        return (["asetpts=PTS-STARTPTS"] + stages).joined(separator: ",")
    }

    static func arguments(
        input: URL, output: URL, settings: ExportSettings,
        size: (width: Int, height: Int), duration: Double
    ) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-ss", String(settings.startTime), "-t", String(duration), "-i", input.path,
                    "-map", "0:v:0", "-map_metadata", "-1",
                    "-vf", "setpts=(PTS-STARTPTS)/\(settings.speed),fps=\(settings.fps),scale=\(size.width):\(size.height):flags=lanczos,setsar=1",
                    "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(settings.videoQuality.crf),
                    "-deadline", "good", "-cpu-used", "4", "-row-mt", "1",
                    "-pix_fmt", "yuv420p"]
        if settings.includeAudio {
            args += ["-map", "0:a:0?", "-af", audioFilter(speed: settings.speed),
                     "-c:a", "libopus", "-b:a", "128k"]
        } else {
            args += ["-an"]
        }
        args += ["-t", String(duration / settings.speed), "-progress", "pipe:1", "-nostats", "-f", "webm", output.path]
        return args
    }

    func export(
        assetURL: URL, to outputURL: URL, settings: ExportSettings,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ExportResult {
        let started = Date()
        guard let executable = Self.executableURL else { throw ExportError.encoderUnavailable }
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let clipDuration = min(settings.endTime, duration) - settings.startTime
        guard clipDuration.isFinite, clipDuration > 0 else { throw ExportError.emptyOutput }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let size = settings.outputSize(for: CGSize(width: abs(rect.width), height: abs(rect.height)))

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = Self.arguments(input: assetURL, output: outputURL, settings: settings, size: size, duration: clipDuration)
        process.standardOutput = pipe
        process.standardError = pipe // drain diagnostics too, so neither pipe can fill and deadlock
        process.standardInput = FileHandle.nullDevice
        try state.withLock {
            if $0.cancelled { throw ExportError.cancelled }
            try process.run()
            $0.process = process
        }
        defer {
            state.withLock { $0.process = nil }
            try? pipe.fileHandleForReading.close()
        }
        progress(0, "Encoding WebM…")
        var pending = Data()
        var diagnostics: [String] = []
        var frames = 0
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "frame", let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    frames = n
                } else if parts.count == 2, parts[0] == "out_time_us", let us = Double(parts[1]) {
                    let fraction = us / 1_000_000 / (clipDuration / settings.speed)
                    progress(min(0.99, max(0, fraction)), "Encoding WebM · \(frames) frames…")
                } else if parts.count != 2 {
                    diagnostics.append(line)
                    diagnostics = Array(diagnostics.suffix(12))
                }
            }
        }
        process.waitUntilExit()
        if state.withLock({ $0.cancelled }) { throw ExportError.cancelled }
        guard process.terminationStatus == 0 else {
            throw ExportError.encodingFailed(diagnostics.joined(separator: "\n"))
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard frames > 0, bytes > 0 else { throw ExportError.emptyOutput }
        progress(1, "Done")
        return ExportResult(url: outputURL, frames: frames, bytes: bytes,
                            wallTime: Date().timeIntervalSince(started), size: size, format: .webm)
    }
}
