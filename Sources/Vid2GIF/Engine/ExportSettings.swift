import Foundation
import CoreGraphics
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case gif, webm

    var title: String { self == .gif ? "GIF" : "WebM" }
    var contentType: UTType {
        self == .gif ? .gif : (UTType(filenameExtension: "webm") ?? UTType(exportedAs: "org.webmproject.webm", conformingTo: .movie))
    }
}

enum VideoQuality: String, CaseIterable {
    case compact, balanced, high

    var title: String { rawValue.capitalized }
    var crf: Int {
        switch self {
        case .compact: return 42
        case .balanced: return 32
        case .high: return 22
        }
    }
    var help: String {
        switch self {
        case .compact: return "Smaller files, with some loss of detail."
        case .balanced: return "A balance of detail and file size."
        case .high: return "Sharper detail, with larger files."
        }
    }
}

struct ExportSettings: Equatable {
    var format: ExportFormat = .gif
    var videoQuality: VideoQuality = .balanced
    var includeAudio: Bool = true
    var outputWidth: Int = 640        // pixels; height follows aspect ratio
    var fps: Double = 15
    var startTime: Double = 0         // seconds in source timeline
    var endTime: Double = .infinity
    var speed: Double = 1.0           // playback speed multiplier
    var maxColors: Int = 255          // ≤ 255 (one slot reserved for transparency)
    var dither: DitherMode = .bayer
    var loopForever: Bool = true
    var useDelta: Bool = true

    func validate() throws {
        guard (2...32768).contains(outputWidth), fps.isFinite, (1...60).contains(fps),
              speed.isFinite, (0.25...4).contains(speed), startTime.isFinite, startTime >= 0,
              endTime > startTime, (2...255).contains(maxColors) else {
            throw ExportError.invalidSettings
        }
    }

    func outputSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        let w = min(Double(outputWidth), sourceSize.width)
        let h = (w * sourceSize.height / sourceSize.width).rounded()
        // Even dimensions keep every downstream consumer happy.
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }
}

struct ExportResult {
    let url: URL
    let frames: Int
    let bytes: Int
    let wallTime: Double
    let size: (width: Int, height: Int)
    var format: ExportFormat = .gif
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case cancelled
    case emptyOutput
    case invalidSettings
    case encoderUnavailable
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file contains no video track."
        case .readerFailed(let why): return "Video decoding failed: \(why)"
        case .cancelled: return "Export cancelled."
        case .emptyOutput: return "No frames were produced for the selected range."
        case .invalidSettings: return "Choose a valid trim range, a width of at least 2 pixels, 1–60 fps, and a speed between 0.25× and 4×."
        case .encoderUnavailable: return "WebM export needs FFmpeg with VP9 and Opus support. Install it with ‘brew install ffmpeg’, then try again. GIF export is always available."
        case .encodingFailed(let why): return "WebM encoding failed: \(why)"
        }
    }
}
