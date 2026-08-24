import Foundation

/// Streams an animated GIF89a to disk: global palette, per-frame delta encoding
/// with transparency, correct frame timing, infinite loop.
final class GIFWriter {
    private let handle: FileHandle
    private let width: Int
    private let height: Int
    private let palette: Palette
    private let loopForever: Bool
    private let useDelta: Bool

    private var previousIndices: [UInt8]?
    private var wroteHeader = false
    private(set) var bytesWritten: Int = 0
    private(set) var framesWritten: Int = 0

    init(url: URL, width: Int, height: Int, palette: Palette, loopForever: Bool, useDelta: Bool) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        self.width = width
        self.height = height
        self.palette = palette
        self.loopForever = loopForever
        self.useDelta = useDelta
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }

    private func writeHeader() throws {
        var d = Data()
        d.append(contentsOf: Array("GIF89a".utf8))
        appendU16(&d, width)
        appendU16(&d, height)
        // Global color table: present, 8 bits/channel resolution, 256 entries.
        d.append(0b1111_0111)
        d.append(0) // background color index
        d.append(0) // pixel aspect ratio
        d.append(palette.colorTableData)
        if loopForever {
            // NETSCAPE2.0 looping extension, loop count 0 = forever.
            d.append(contentsOf: [0x21, 0xFF, 0x0B])
            d.append(contentsOf: Array("NETSCAPE2.0".utf8))
            d.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        }
        try write(d)
        wroteHeader = true
    }

    /// Adds one full frame of palette indices (width × height). `delayCS` is the
    /// frame delay in centiseconds (clamped to ≥ 2 by the caller).
    func addFrame(indices: [UInt8], delayCS: Int) throws {
        if !wroteHeader { try writeHeader() }

        var rect = (x: 0, y: 0, w: width, h: height)
        var payload = indices
        var hasTransparency = false

        if useDelta, let prev = previousIndices, palette.transparentIndex < 256 {
            // Find the bounding box of changed pixels.
            var minX = width, minY = height, maxX = -1, maxY = -1
            indices.withUnsafeBufferPointer { cur in
                prev.withUnsafeBufferPointer { old in
                    let c = cur.baseAddress!, o = old.baseAddress!
                    for y in 0..<height {
                        let row = y * width
                        var x = 0
                        while x < width {
                            if c[row + x] != o[row + x] {
                                if x < minX { minX = x }
                                if x > maxX { maxX = x }
                                if y < minY { minY = y }
                                maxY = y
                            }
                            x += 1
                        }
                    }
                }
            }

            if maxX < 0 {
                // Identical frame: extend previous frame's delay by re-emitting a
                // 1×1 transparent patch (simplest reliable way to add time).
                rect = (0, 0, 1, 1)
                payload = [UInt8(palette.transparentIndex)]
                hasTransparency = true
            } else {
                rect = (minX, minY, maxX - minX + 1, maxY - minY + 1)
                var patch = [UInt8](repeating: 0, count: rect.w * rect.h)
                let tIdx = UInt8(palette.transparentIndex)
                indices.withUnsafeBufferPointer { cur in
                    previousIndices!.withUnsafeBufferPointer { old in
                        patch.withUnsafeMutableBufferPointer { dst in
                            let c = cur.baseAddress!, o = old.baseAddress!, d = dst.baseAddress!
                            for y in 0..<rect.h {
                                let src = (rect.y + y) * width + rect.x
                                let drow = y * rect.w
                                for x in 0..<rect.w {
                                    let cv = c[src + x]
                                    d[drow + x] = (cv == o[src + x]) ? tIdx : cv
                                }
                            }
                        }
                    }
                }
                payload = patch
                hasTransparency = true
            }
        }

        var d = Data()
        // Graphic Control Extension
        d.append(contentsOf: [0x21, 0xF9, 0x04])
        // Disposal method 1 (do not dispose) so deltas composite over prior frames.
        d.append(UInt8((1 << 2) | (hasTransparency ? 1 : 0)))
        appendU16(&d, max(2, delayCS))
        d.append(UInt8(hasTransparency ? palette.transparentIndex : 0))
        d.append(0)
        // Image descriptor
        d.append(0x2C)
        appendU16(&d, rect.x)
        appendU16(&d, rect.y)
        appendU16(&d, rect.w)
        appendU16(&d, rect.h)
        d.append(0) // no local color table, not interlaced
        LZWEncoder.encode(payload, into: &d)
        try write(d)

        previousIndices = indices
        framesWritten += 1
    }

    func finish() throws {
        if !wroteHeader { try writeHeader() }
        try write(Data([0x3B]))
        try handle.close()
    }

    func abort() {
        try? handle.close()
    }
}

@inline(__always)
private func appendU16(_ d: inout Data, _ v: Int) {
    d.append(UInt8(v & 0xFF))
    d.append(UInt8((v >> 8) & 0xFF))
}
