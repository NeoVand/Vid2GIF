import Foundation
import CoreGraphics

struct ExportSettings {
    var outputWidth: Int = 640        // pixels; height follows aspect ratio
    var fps: Double = 15
    var startTime: Double = 0         // seconds in source timeline
    var endTime: Double = .infinity
    var speed: Double = 1.0           // playback speed multiplier
    var maxColors: Int = 255          // ≤ 255 (one slot reserved for transparency)
    var dither: DitherMode = .bayer
    var loopForever: Bool = true
    var useDelta: Bool = true

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
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case cancelled
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file contains no video track."
        case .readerFailed(let why): return "Video decoding failed: \(why)"
        case .cancelled: return "Export cancelled."
        case .emptyOutput: return "No frames were produced for the selected range."
        }
    }
}
