import Foundation

/// GIF-flavored LZW encoder (variable code width, 12-bit max, deferred clear).
/// Port of the classic ppmtogif/giflib compression logic.
enum LZWEncoder {

    /// Compresses `indices` (palette indices, one byte per pixel) into GIF LZW
    /// data sub-blocks (each ≤255 bytes, length-prefixed), appended to `out`.
    /// Always uses a minimum code size of 8 (palette indices 0...255).
    static func encode(_ indices: [UInt8], into out: inout Data) {
        out.append(8) // LZW minimum code size

        let minCodeSize = 8
        let clearCode = 1 << minCodeSize       // 256
        let eoiCode = clearCode + 1            // 257
        let maxMaxCode = 1 << 12               // 4096

        var nBits = minCodeSize + 1
        var maxCode = (1 << nBits) - 1
        var freeEnt = eoiCode + 1

        // Dictionary: (currentCode << 8 | nextByte) -> code. Flat table, -1 = empty.
        var table = [Int32](repeating: -1, count: 4096 * 256)

        // Bit accumulator
        var bitBuf: UInt32 = 0
        var bitCount = 0

        // Sub-block chunk buffer
        var chunk = [UInt8]()
        chunk.reserveCapacity(255)

        func flushChunk() {
            if !chunk.isEmpty {
                out.append(UInt8(chunk.count))
                out.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }

        func outputCode(_ code: Int) {
            bitBuf |= UInt32(code) << UInt32(bitCount)
            bitCount += nBits
            while bitCount >= 8 {
                chunk.append(UInt8(bitBuf & 0xFF))
                bitBuf >>= 8
                bitCount -= 8
                if chunk.count == 255 { flushChunk() }
            }
            if freeEnt > maxCode {
                if nBits < 12 {
                    nBits += 1
                    maxCode = (1 << nBits) - 1
                } else {
                    maxCode = maxMaxCode // stop growing; wait for clear
                }
            }
        }

        indices.withUnsafeBufferPointer { px in
            guard let base = px.baseAddress, px.count > 0 else {
                // Empty image: still emit a valid stream.
                outputCode(clearCode)
                outputCode(eoiCode)
                return
            }
            table.withUnsafeMutableBufferPointer { tbl in
                let t = tbl.baseAddress!

                outputCode(clearCode)
                var cur = Int(base[0])

                for i in 1..<px.count {
                    let c = Int(base[i])
                    let key = (cur << 8) | c
                    let found = t[key]
                    if found >= 0 {
                        cur = Int(found)
                        continue
                    }
                    outputCode(cur)
                    if freeEnt < maxMaxCode {
                        t[key] = Int32(freeEnt)
                        freeEnt += 1
                    } else {
                        // Table full: clear and restart.
                        outputCode(clearCode)
                        for j in 0..<(4096 * 256) { t[j] = -1 }
                        freeEnt = eoiCode + 1
                        nBits = minCodeSize + 1
                        maxCode = (1 << nBits) - 1
                    }
                    cur = c
                }
                outputCode(cur)
                outputCode(eoiCode)
            }
        }

        // Flush remaining bits.
        while bitCount > 0 {
            chunk.append(UInt8(bitBuf & 0xFF))
            bitBuf >>= 8
            bitCount -= 8
            if chunk.count == 255 { flushChunk() }
        }
        flushChunk()
        out.append(0) // block terminator
    }
}
