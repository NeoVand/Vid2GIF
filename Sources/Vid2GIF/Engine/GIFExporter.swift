import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import os

/// Orchestrates the export: pass 1 builds a global palette from sampled frames,
/// pass 2 streams hardware-decoded frames through the quantizer into the writer.
final class GIFExporter {
    // Cancellation is a flag only. AVAssetReader is not safe to touch from a
    // second thread while the export task is reading — cancelReading() must be
    // issued by the reading thread itself when it observes the flag.
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    private var isCancelled: Bool { cancelFlag.withLock { $0 } }

    func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    func export(
        assetURL: URL,
        to outputURL: URL,
        settings: ExportSettings,
        progress: @escaping (Double, String) -> Void
    ) async throws -> ExportResult {
        let t0 = Date()
        let asset = AVURLAsset(url: assetURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let start = max(0, settings.startTime)
        let end = min(settings.endTime, duration)

        // ---- Pass 1: sample frames → global palette --------------------------
        progress(0, "Analyzing colors…")
        let samples = try await samplePixels(
            asset: asset, track: track, settings: settings, start: start, end: end
        )
        if isCancelled { throw ExportError.cancelled }
        let palette = PaletteBuilder.build(samples: samples, maxColors: settings.maxColors)

        // ---- Pass 2: decode, quantize, write --------------------------------
        progress(0.05, "Encoding frames…")
        let source = try await FrameSource(asset: asset, track: track, settings: settings)

        let quantizer = Quantizer(palette: palette, mode: settings.dither)
        let writer = try GIFWriter(
            url: outputURL,
            width: source.outputSize.width,
            height: source.outputSize.height,
            palette: palette,
            loopForever: settings.loopForever,
            useDelta: settings.useDelta
        )

        var frameIndex = 0
        let expected = source.expectedFrames
        do {
            while let frame = try source.next() {
                if isCancelled {
                    source.cancel() // safe: we are the reading thread
                    throw ExportError.cancelled
                }
                let pb = frame.pixelBuffer
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let indices: [UInt8]
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    indices = quantizer.indexFrame(
                        bgra: base.assumingMemoryBound(to: UInt8.self),
                        width: source.outputSize.width,
                        height: source.outputSize.height,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb)
                    )
                } else {
                    indices = []
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                guard !indices.isEmpty else { continue }

                // Output timeline delay: frame i displays for [i, i+1] / fps.
                let csNow = (Double(frameIndex) * 100.0 / settings.fps).rounded()
                let csNext = (Double(frameIndex + 1) * 100.0 / settings.fps).rounded()
                try writer.addFrame(indices: indices, delayCS: max(2, Int(csNext - csNow)))

                frameIndex += 1
                if frameIndex % 5 == 0 {
                    let p = 0.05 + 0.95 * min(1.0, Double(frameIndex) / Double(expected))
                    progress(p, "Encoding frame \(frameIndex)…")
                }
            }
        } catch {
            writer.abort()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        guard writer.framesWritten > 0 else {
            writer.abort()
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.emptyOutput
        }
        try writer.finish()
        progress(1.0, "Done")

        return ExportResult(
            url: outputURL,
            frames: writer.framesWritten,
            bytes: writer.bytesWritten,
            wallTime: Date().timeIntervalSince(t0),
            size: source.outputSize
        )
    }

    /// Samples pixels from up to 24 frames spread across the clip using
    /// AVAssetImageGenerator (keyframe-fast seeking, GPU decode).
    private func samplePixels(
        asset: AVAsset, track: AVAssetTrack, settings: ExportSettings,
        start: Double, end: Double
    ) async throws -> [(UInt8, UInt8, UInt8)] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let clip = max(0.01, end - start)
        let frameCount = min(24, max(4, Int(clip * 2)))
        gen.maximumSize = CGSize(width: 640, height: 640) // palette doesn't need full res
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var samples: [(UInt8, UInt8, UInt8)] = []
        samples.reserveCapacity(200_000)
        let perFrameBudget = 200_000 / frameCount

        for i in 0..<frameCount {
            if isCancelled { throw ExportError.cancelled }
            let t = start + clip * (Double(i) + 0.5) / Double(frameCount)
            guard let cg = try? await gen.image(
                at: CMTime(seconds: t, preferredTimescale: 600)
            ).image else { continue }
            appendSamples(from: cg, budget: perFrameBudget, into: &samples)
        }

        // Fallback: single frame at the start if everything above failed.
        if samples.isEmpty {
            if let cg = try? await gen.image(
                at: CMTime(seconds: start, preferredTimescale: 600)
            ).image {
                appendSamples(from: cg, budget: 200_000, into: &samples)
            }
        }
        return samples
    }

    private func appendSamples(
        from image: CGImage, budget: Int, into samples: inout [(UInt8, UInt8, UInt8)]
    ) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return }
        let p = data.assumingMemoryBound(to: UInt8.self)

        let total = w * h
        let stride = max(1, total / budget)
        var i = 0
        while i < total {
            let o = i * 4
            samples.append((p[o + 2], p[o + 1], p[o]))
            i += stride
        }
    }
}
