import Foundation
import Darwin
import os

/// Shared entry point for previews, GUI exports and the CLI. Stage output beside
/// its destination so failure/cancellation can never damage an existing file.
final class MediaExporter {
    private let gif = GIFExporter()
    private let webm = WebMExporter()
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { $0 = true }
        gif.cancel()
        webm.cancel()
    }

    func export(
        assetURL: URL, to outputURL: URL, settings: ExportSettings,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ExportResult {
        try settings.validate()
        guard assetURL.resolvingSymlinksInPath().standardizedFileURL != outputURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw ExportError.readerFailed("Choose an output file different from the source video.")
        }
        let staged = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".vid2gif-\(UUID().uuidString).\(settings.format.rawValue)")
        defer { try? FileManager.default.removeItem(at: staged) }
        if cancelled.withLock({ $0 }) { throw ExportError.cancelled }

        let result: ExportResult
        switch settings.format {
        case .gif:
            result = try await gif.export(assetURL: assetURL, to: staged, settings: settings, progress: progress)
        case .webm:
            result = try await webm.export(assetURL: assetURL, to: staged, settings: settings, progress: progress)
        }
        // Commit and cancellation are serialized: once committed the export is done.
        try cancelled.withLock { isCancelled in
            if isCancelled { throw ExportError.cancelled }
            guard rename(staged.path, outputURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return ExportResult(url: outputURL, frames: result.frames, bytes: result.bytes,
                            wallTime: result.wallTime, size: result.size, format: settings.format)
    }
}
