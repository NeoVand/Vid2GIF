import Foundation

enum DitherMode: String, CaseIterable, Identifiable, Codable {
    case bayer = "Bayer"            // ordered; deterministic per-pixel → best delta compression
    case floydSteinberg = "Diffusion" // error diffusion; best for gradients/live video
    case none = "None"

    var id: String { rawValue }
    var help: String {
        switch self {
        case .bayer: return "Ordered dither — crisp, small files, ideal for screen recordings"
        case .floydSteinberg: return "Error diffusion — smoothest gradients, best for camera video"
        case .none: return "No dithering — smallest files, may band on gradients"
        }
    }
}

/// Converts BGRA frames into palette-indexed frames.
struct Quantizer {
    let palette: Palette
    let mode: DitherMode

    // 8×8 Bayer matrix, values 0...63.
    private static let bayer8: [Int] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Quantizes a BGRA buffer (with row stride `bytesPerRow`) into palette indices.
    func indexFrame(
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        switch mode {
        case .none:
            out.withUnsafeMutableBufferPointer { dst in
                let d = dst.baseAddress!
                for y in 0..<height {
                    let row = bgra + y * bytesPerRow
                    let orow = y * width
                    for x in 0..<width {
                        let p = row + x * 4
                        d[orow + x] = UInt8(palette.nearestIndex(r: Int(p[2]), g: Int(p[1]), b: Int(p[0])))
                    }
                }
            }
        case .bayer:
            let strength = 24 // dither amplitude in 0...255 space
            Self.bayer8.withUnsafeBufferPointer { bay in
                out.withUnsafeMutableBufferPointer { dst in
                    let d = dst.baseAddress!
                    for y in 0..<height {
                        let row = bgra + y * bytesPerRow
                        let orow = y * width
                        let byOff = (y & 7) << 3
                        for x in 0..<width {
                            let p = row + x * 4
                            let t = ((bay[byOff | (x & 7)] << 1) - 63) * strength >> 6 // ≈ ±strength
                            let r = clamp255(Int(p[2]) + t)
                            let g = clamp255(Int(p[1]) + t)
                            let b = clamp255(Int(p[0]) + t)
                            d[orow + x] = UInt8(palette.nearestIndex(r: r, g: g, b: b))
                        }
                    }
                }
            }
        case .floydSteinberg:
            // Two-row error buffers, 3 channels each.
            var errCur = [Int](repeating: 0, count: (width + 2) * 3)
            var errNext = [Int](repeating: 0, count: (width + 2) * 3)
            let colors = palette.colors
            out.withUnsafeMutableBufferPointer { dst in
                let d = dst.baseAddress!
                for y in 0..<height {
                    let row = bgra + y * bytesPerRow
                    let orow = y * width
                    for i in 0..<errNext.count { errNext[i] = 0 }
                    errCur.withUnsafeMutableBufferPointer { ec in
                        errNext.withUnsafeMutableBufferPointer { en in
                            for x in 0..<width {
                                let p = row + x * 4
                                let ei = (x + 1) * 3
                                let r = clamp255(Int(p[2]) + ec[ei] / 16)
                                let g = clamp255(Int(p[1]) + ec[ei + 1] / 16)
                                let b = clamp255(Int(p[0]) + ec[ei + 2] / 16)
                                let idx = palette.nearestIndex(r: r, g: g, b: b)
                                d[orow + x] = UInt8(idx)
                                let c = colors[idx]
                                let er = r - Int(c.r), eg = g - Int(c.g), eb = b - Int(c.b)
                                // Distribute: right 7/16, below-left 3/16, below 5/16, below-right 1/16
                                ec[ei + 3] += er * 7; ec[ei + 4] += eg * 7; ec[ei + 5] += eb * 7
                                en[ei - 3] += er * 3; en[ei - 2] += eg * 3; en[ei - 1] += eb * 3
                                en[ei] += er * 5; en[ei + 1] += eg * 5; en[ei + 2] += eb * 5
                                en[ei + 3] += er; en[ei + 4] += eg; en[ei + 5] += eb
                            }
                        }
                    }
                    swap(&errCur, &errNext)
                }
            }
        }
        return out
    }

    @inline(__always)
    private func clamp255(_ v: Int) -> Int { v < 0 ? 0 : (v > 255 ? 255 : v) }
}
