import Foundation

/// A global color palette plus a 15-bit RGB → index lookup table for fast mapping.
struct Palette {
    /// Palette colors as (r, g, b), at most 255 entries (index 255 is reserved
    /// for transparency when delta encoding is enabled).
    let colors: [(r: UInt8, g: UInt8, b: UInt8)]
    /// 32768-entry table mapping RGB555 to nearest palette index.
    let lookup: [UInt8]
    /// Index reserved for transparent pixels (always colors.count if < 256).
    let transparentIndex: Int

    /// GIF global color table: 256 entries × 3 bytes, padded with black.
    var colorTableData: Data {
        var d = Data(capacity: 256 * 3)
        for c in colors {
            d.append(c.r); d.append(c.g); d.append(c.b)
        }
        while d.count < 256 * 3 { d.append(0) }
        return d
    }

    @inline(__always)
    func nearestIndex(r: Int, g: Int, b: Int) -> Int {
        Int(lookup[((r & 0xF8) << 7) | ((g & 0xF8) << 2) | (b >> 3)])
    }
}

/// Median-cut quantizer over sampled pixels.
enum PaletteBuilder {

    /// Builds a palette of up to `maxColors` (≤255) colors from BGRA sample pixels.
    /// `samples` is packed 0xAARRGGBB / BGRA byte order — we take r,g,b explicitly.
    static func build(samples: [(UInt8, UInt8, UInt8)], maxColors: Int) -> Palette {
        let maxColors = min(maxColors, 255)
        var colors: [(r: UInt8, g: UInt8, b: UInt8)]

        if samples.isEmpty {
            colors = [(0, 0, 0)]
        } else {
            colors = medianCut(samples: samples, maxColors: maxColors)
        }

        // Build the RGB555 nearest-neighbor lookup table.
        var lookup = [UInt8](repeating: 0, count: 32768)
        let n = colors.count
        colors.withUnsafeBufferPointer { pal in
            lookup.withUnsafeMutableBufferPointer { lut in
                for r5 in 0..<32 {
                    let r = r5 << 3 | r5 >> 2
                    for g5 in 0..<32 {
                        let g = g5 << 3 | g5 >> 2
                        for b5 in 0..<32 {
                            let b = b5 << 3 | b5 >> 2
                            var best = 0
                            var bestDist = Int.max
                            for i in 0..<n {
                                let c = pal[i]
                                let dr = r - Int(c.r), dg = g - Int(c.g), db = b - Int(c.b)
                                // Perceptual-ish weighting: green matters most.
                                let dist = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                                if dist < bestDist { bestDist = dist; best = i }
                            }
                            lut[(r5 << 10) | (g5 << 5) | b5] = UInt8(best)
                        }
                    }
                }
            }
        }
        return Palette(colors: colors, lookup: lookup, transparentIndex: colors.count < 256 ? colors.count : 255)
    }

    private struct Box {
        var lo: Int          // range into the shared sample array
        var hi: Int          // exclusive
        var rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0

        var count: Int { hi - lo }
        var longestChannel: Int {
            let dr = rMax - rMin, dg = gMax - gMin, db = bMax - bMin
            if dg >= dr && dg >= db { return 1 }
            if dr >= db { return 0 }
            return 2
        }
        var volumeScore: Int {
            // Prioritize boxes with many pixels and wide spread.
            let spread = max(rMax - rMin, gMax - gMin, bMax - bMin)
            return count * max(spread, 1)
        }
        var splittable: Bool { count > 1 && (rMax > rMin || gMax > gMin || bMax > bMin) }
    }

    private static func medianCut(
        samples: [(UInt8, UInt8, UInt8)], maxColors: Int
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        var px = samples
        var boxes: [Box] = []

        func measure(_ box: inout Box) {
            var rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0
            for i in box.lo..<box.hi {
                let (r, g, b) = px[i]
                rMin = min(rMin, Int(r)); rMax = max(rMax, Int(r))
                gMin = min(gMin, Int(g)); gMax = max(gMax, Int(g))
                bMin = min(bMin, Int(b)); bMax = max(bMax, Int(b))
            }
            box.rMin = rMin; box.rMax = rMax
            box.gMin = gMin; box.gMax = gMax
            box.bMin = bMin; box.bMax = bMax
        }

        var first = Box(lo: 0, hi: px.count)
        measure(&first)
        boxes.append(first)

        while boxes.count < maxColors {
            // Pick the best splittable box.
            var bestIdx = -1
            var bestScore = 0
            for (i, b) in boxes.enumerated() where b.splittable {
                if b.volumeScore > bestScore { bestScore = b.volumeScore; bestIdx = i }
            }
            if bestIdx < 0 { break }
            let box = boxes[bestIdx]

            // Sort the box's slice along its longest channel, split at the median.
            let ch = box.longestChannel
            px[box.lo..<box.hi].sort { a, b in
                switch ch {
                case 0: return a.0 < b.0
                case 1: return a.1 < b.1
                default: return a.2 < b.2
                }
            }
            let mid = box.lo + box.count / 2
            var left = Box(lo: box.lo, hi: mid)
            var right = Box(lo: mid, hi: box.hi)
            measure(&left)
            measure(&right)
            boxes[bestIdx] = left
            boxes.append(right)
        }

        // Average each box to get its representative color.
        var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
        out.reserveCapacity(boxes.count)
        for box in boxes where box.count > 0 {
            var rs = 0, gs = 0, bs = 0
            for i in box.lo..<box.hi {
                let (r, g, b) = px[i]
                rs += Int(r); gs += Int(g); bs += Int(b)
            }
            let n = box.count
            out.append((UInt8(rs / n), UInt8(gs / n), UInt8(bs / n)))
        }
        return out
    }
}
