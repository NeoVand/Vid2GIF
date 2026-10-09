import Foundation
import AVFoundation
import os
import Darwin

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
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        args += ["-f", "rawvideo", "-pixel_format", "nv12", "-video_size", "\(size.width)x\(size.height)",
                 "-framerate", String(settings.fps), "-i", "pipe:0"]
        if settings.includeAudio {
            args += ["-ss", String(settings.startTime), "-t", String(duration), "-vn", "-i", input.path]
        }
        args += ["-map", "0:v:0", "-map_metadata", "-1"]
        args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(settings.videoQuality.crf),
                 "-deadline", "realtime", "-cpu-used", "6", "-row-mt", "1", "-pix_fmt", "yuv420p",
                 "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        if settings.includeAudio {
            args += ["-map", "1:a:0?", "-af", audioFilter(speed: settings.speed),
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
        let source = try await FrameSource(asset: asset, track: track, settings: settings,
                                           pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let size = source.outputSize
        var encodingSettings = settings
        if settings.includeAudio {
            encodingSettings.includeAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        }

        let process = Process()
        let pipe = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = Self.arguments(input: assetURL, output: outputURL, settings: encodingSettings, size: size, duration: clipDuration)
        process.standardOutput = pipe
        process.standardError = pipe // drain diagnostics too, so neither pipe can fill and deadlock
        process.standardInput = input
        // A cancelled/failed child can close its input during a write. Turn that
        // into a thrown error instead of delivering SIGPIPE to the whole app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try state.withLock {
            if $0.cancelled { throw ExportError.cancelled }
            try process.run()
            $0.process = process
        }
        defer {
            state.withLock { $0.process = nil }
            try? pipe.fileHandleForReading.close()
        }
        let feedTask = Task.detached(priority: .userInitiated) {
            defer {
                source.cancel() // AVAssetReader is touched only by this thread.
                try? input.fileHandleForWriting.close()
            }
            do {
                try self.feed(source: source, to: input.fileHandleForWriting, settings: settings, duration: clipDuration)
            } catch {
                self.state.withLock {
                    if let process = $0.process, process.isRunning { process.terminate() }
                }
                throw error
            }
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
        let feedResult = await feedTask.result
        if state.withLock({ $0.cancelled }) { throw ExportError.cancelled }
        if case .failure(let error as ExportError) = feedResult { throw error }
        guard process.terminationStatus == 0 else {
            let reason = diagnostics.isEmpty ? "Encoder exited with status \(process.terminationStatus)." : diagnostics.joined(separator: "\n")
            throw ExportError.encodingFailed(reason)
        }
        try feedResult.get()
        let bytes = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard frames > 0, bytes > 0 else { throw ExportError.emptyOutput }
        progress(1, "Done")
        return ExportResult(url: outputURL, frames: frames, bytes: bytes,
                            wallTime: Date().timeIntervalSince(started), size: size, format: .webm)
    }

    /// Pack the GPU-composited NV12 planes without row padding. A single reusable
    /// frame buffer and pipe backpressure keep memory bounded for long clips.
    private func feed(source: FrameSource, to input: FileHandle, settings: ExportSettings, duration: Double) throws {
        let (width, height) = source.outputSize
        var bytes = Data(count: width * height * 3 / 2)
        guard var frame = try source.next() else { throw ExportError.emptyOutput }
        var next = try source.next()
        let count = max(1, Int(ceil(duration / settings.speed * settings.fps - 0.000001)))
        // AVAssetReader can return fewer samples than frameDuration requests
        // when slowing a low-frame-rate source. Resample by timestamps, holding
        // frames as needed, so rawvideo always has the exact output cadence.
        for index in 0..<count {
            let time = settings.startTime + Double(index) * settings.speed / settings.fps
            while let upcoming = next, upcoming.time <= time + 0.000001 {
                frame = upcoming
                next = try source.next()
            }
            if state.withLock({ $0.cancelled }) { throw ExportError.cancelled }
            let buffer = frame.pixelBuffer
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw ExportError.readerFailed("Cannot read a decoded frame.")
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard CVPixelBufferGetPlaneCount(buffer) == 2 else {
                throw ExportError.readerFailed("Expected an NV12 video frame.")
            }
            try bytes.withUnsafeMutableBytes { destination in
                var offset = 0
                for plane in 0..<2 {
                    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                        throw ExportError.readerFailed("Missing video frame data.")
                    }
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    for row in 0..<(plane == 0 ? height : height / 2) {
                        memcpy(destination.baseAddress!.advanced(by: offset), base.advanced(by: row * stride), width)
                        offset += width
                    }
                }
            }
            try input.write(contentsOf: bytes)
        }
    }
}
