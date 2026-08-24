import Foundation
import AVFoundation
import CoreImage

/// Hardware-accelerated frame source: VideoToolbox decode + GPU compositing that
/// scales to the target size and resamples to the target frame rate in one pass.
final class FrameSource {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let time: Double
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    let outputSize: (width: Int, height: Int)
    let expectedFrames: Int

    init(asset: AVAsset, track: AVAssetTrack, settings: ExportSettings) async throws {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds

        // Displayed size after orientation.
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let out = settings.outputSize(for: displaySize)
        self.outputSize = out

        let start = max(0, settings.startTime)
        let end = min(settings.endTime, duration)
        let clipDuration = max(0, end - start)

        // At speed S the output lasts clip/S seconds and plays at `fps`, so each
        // output frame covers S/fps of source time → sample the source at fps/S.
        let sourceFPS = settings.fps / max(0.05, settings.speed)
        self.expectedFrames = max(1, Int((clipDuration * sourceFPS).rounded()))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
        )

        // Composition: orientation fix + scale to output size, GPU-composited.
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: out.width, height: out.height)
        composition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(1, Int32(sourceFPS.rounded())))
        )
        if abs(sourceFPS.rounded() - sourceFPS) > 0.01 {
            // Non-integer rate: use a fine timescale for accuracy.
            composition.frameDuration = CMTime(
                value: CMTimeValue((6000.0 / sourceFPS).rounded()), timescale: 6000
            )
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        var t = transform
        // Re-origin the oriented rect at (0,0), then scale to output.
        t = t.concatenating(CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))
        let sx = CGFloat(out.width) / displaySize.width
        let sy = CGFloat(out.height) / displaySize.height
        t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ExportError.readerFailed("cannot attach composition output")
        }
        reader.add(output)
        self.reader = reader
        self.output = output

        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
    }

    /// Pulls the next decoded, scaled frame. Returns nil at end of stream.
    func next() throws -> Frame? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
            }
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return try next() }
        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return Frame(pixelBuffer: pb, time: t)
    }

    func cancel() {
        reader.cancelReading()
    }
}
