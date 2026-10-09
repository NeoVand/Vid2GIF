import Foundation

/// Includes source-file identity so editing/replacing a movie invalidates its
/// cached encodes, even when the URL and export settings remain unchanged.
struct ExportRequest: Equatable {
    let source: URL
    let settings: ExportSettings
    private let modified: Date?
    private let fileSize: Int?
    private let fileID: UInt64?

    init(source: URL, settings: ExportSettings) {
        self.source = source.resolvingSymlinksInPath().standardizedFileURL
        var normalized = settings
        if settings.format == .webm {
            normalized.maxColors = 255
            normalized.dither = .bayer
            normalized.loopForever = true
            normalized.useDelta = true
        } else {
            normalized.videoQuality = .balanced
            normalized.includeAudio = true
        }
        self.settings = normalized
        // URL.resourceValues caches metadata on the URL instance, which can
        // conceal changes to a file we're keeping open in the editor.
        let values = try? FileManager.default.attributesOfItem(atPath: self.source.path)
        modified = values?[.modificationDate] as? Date
        fileSize = (values?[.size] as? NSNumber)?.intValue
        fileID = (values?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

/// One owned file per format bounds disk usage. Only the main actor mutates the
/// cache; encoders write to unique paths before their results are installed.
@MainActor
final class ExportCache {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vid2GIF-cache-\(UUID().uuidString)", isDirectory: true)
    private var entries: [ExportFormat: (request: ExportRequest, result: ExportResult)] = [:]

    func makeURL(format: ExportFormat) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(format.rawValue)")
    }

    func result(for request: ExportRequest) -> ExportResult? {
        guard let entry = entries[request.settings.format], entry.request == request,
              FileManager.default.fileExists(atPath: entry.result.url.path) else { return nil }
        return entry.result
    }

    func store(_ result: ExportResult, for request: ExportRequest) {
        let old = entries.updateValue((request, result), forKey: request.settings.format)
        if let old, old.result.url != result.url { try? FileManager.default.removeItem(at: old.result.url) }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
