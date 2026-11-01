import CAdwaita
import Foundation

/// QR codes for the Receive and Buy sheets. Upstream draws them with Core Image's
/// `CIQRCodeGenerator`; here the symbol is encoded in Swift (byte mode, any version, the four
/// error-correction levels; the construction follows ISO/IEC 18004 as Project Nayuki's QR code
/// generator lays it out), so no QR library is needed on Linux or the BSDs. Upstream's `decode`
/// is for its tests only and has no counterpart.
enum QRCode {
    /// A crisp QR code for `text`, about `size` pixels square, drawn with whole pixels per module.
    static func image(for text: String, size: CGFloat = 240, correction: String = "M") -> PlatformImage? {
        guard let symbol = Symbol(text: text, correction: Correction(correction)) else { return nil }
        let count = symbol.size
        let scale = max(1, Int(size) / count)
        let side = count * scale
        var pixels = [UInt8](repeating: 0xFF, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side where symbol.modules[y / scale][x / scale] {
                let i = (y * side + x) * 4
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
            }
        }
        return pixels.withUnsafeBytes { raw -> PlatformImage? in
            guard let bytes = g_bytes_new(raw.baseAddress, gsize(raw.count)) else { return nil }
            defer { g_bytes_unref(bytes) }
            guard let texture = gdk_memory_texture_new(Int32(side), Int32(side), GDK_MEMORY_R8G8B8A8, bytes, gsize(side * 4)) else { return nil }
            return PlatformImage(texture: texture)
        }
    }

    /// The dark (true) and light modules of `text`'s symbol, row by row, without a quiet zone.
    static func modules(for text: String, correction: String = "M") -> [[Bool]]? {
        Symbol(text: text, correction: Correction(correction))?.modules
    }

    /// The modules of one symbol with the given mask, for checking against another encoder.
    static func modules(for text: String, correction: String, mask: Int) -> [[Bool]]? {
        Symbol(text: text, correction: Correction(correction), mask: mask)?.modules
    }

    enum Correction: Int {
        case low, medium, quartile, high

        init(_ letter: String) {
            switch letter.uppercased() {
            case "L": self = .low
            case "Q": self = .quartile
            case "H": self = .high
            default: self = .medium
            }
        }

        /// The two bits the format information carries for this level.
        var formatBits: Int { [1, 0, 3, 2][rawValue] }
    }

    private struct Symbol {
        let version: Int
        let size: Int
        private(set) var modules: [[Bool]]
        private var isFunction: [[Bool]]

        init?(text: String, correction: Correction, mask forcedMask: Int? = nil) {
            let data = Array(text.utf8)
            // The smallest version whose capacity holds the data in byte mode.
            guard let version = (1...40).first(where: { Symbol.dataBits(data.count, version: $0) <= Symbol.dataCodewords($0, correction) * 8 }) else { return nil }
            self.version = version
            size = version * 4 + 17
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules

            drawFunctionPatterns(correction: correction)
            let codewords = Symbol.addECCAndInterleave(Symbol.dataCodewords(of: data, version: version, correction: correction), version: version, correction: correction)
            drawCodewords(codewords)

            let mask: Int
            if let forcedMask {
                guard (0..<8).contains(forcedMask) else { return nil }
                mask = forcedMask
            } else {
                var best = 0, bestPenalty = Int.max
                for candidate in 0..<8 {
                    applyMask(candidate)
                    drawFormatBits(correction: correction, mask: candidate)
                    let penalty = penaltyScore()
                    if penalty < bestPenalty { best = candidate; bestPenalty = penalty }
                    applyMask(candidate)   // XOR undoes it
                }
                mask = best
            }
            applyMask(mask)
            drawFormatBits(correction: correction, mask: mask)
        }

        // MARK: Data

        /// Bits of a byte-mode segment: mode, character count, data.
        static func dataBits(_ count: Int, version: Int) -> Int {
            let countBits = version < 10 ? 8 : 16
            guard count < 1 << countBits else { return .max }
            return 4 + countBits + count * 8
        }

        static func dataCodewords(of data: [UInt8], version: Int, correction: Correction) -> [UInt8] {
            var bits: [Bool] = []
            func append(_ value: Int, _ length: Int) {
                for i in stride(from: length - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
            }
            append(0x4, 4)
            append(data.count, version < 10 ? 8 : 16)
            for byte in data { append(Int(byte), 8) }
            let capacity = dataCodewords(version, correction) * 8
            append(0, min(4, capacity - bits.count))   // terminator
            append(0, (8 - bits.count % 8) % 8)
            var bytes: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { start in
                bits[start..<start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
            }
            var pad: UInt8 = 0xEC
            while bytes.count < capacity / 8 {
                bytes.append(pad)
                pad ^= 0xEC ^ 0x11
            }
            return bytes
        }

        static func rawDataModules(_ version: Int) -> Int {
            var result = (16 * version + 128) * version + 64
            if version >= 2 {
                let alignments = version / 7 + 2
                result -= (25 * alignments - 10) * alignments - 55
                if version >= 7 { result -= 36 }
            }
            return result
        }

        static func dataCodewords(_ version: Int, _ correction: Correction) -> Int {
            rawDataModules(version) / 8 - eccCodewordsPerBlock[correction.rawValue][version] * errorCorrectionBlocks[correction.rawValue][version]
        }

        static func addECCAndInterleave(_ data: [UInt8], version: Int, correction: Correction) -> [UInt8] {
            let blockCount = errorCorrectionBlocks[correction.rawValue][version]
            let eccLength = eccCodewordsPerBlock[correction.rawValue][version]
            let rawCodewords = rawDataModules(version) / 8
            let shortBlocks = blockCount - rawCodewords % blockCount
            let shortLength = rawCodewords / blockCount
            let divisor = reedSolomonDivisor(degree: eccLength)
            var blocks: [[UInt8]] = []
            var offset = 0
            for i in 0..<blockCount {
                let length = shortLength - eccLength + (i < shortBlocks ? 0 : 1)
                var block = Array(data[offset..<offset + length])
                offset += length
                let ecc = reedSolomonRemainder(block, divisor: divisor)
                if i < shortBlocks { block.append(0) }
                blocks.append(block + ecc)
            }
            var result: [UInt8] = []
            for i in 0..<blocks[0].count {
                for (j, block) in blocks.enumerated() where i != shortLength - eccLength || j >= shortBlocks {
                    result.append(block[i])
                }
            }
            return result
        }

        static func reedSolomonDivisor(degree: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: degree - 1) + [1]
            var root: UInt8 = 1
            for _ in 0..<degree {
                for j in 0..<result.count {
                    result[j] = multiply(result[j], root)
                    if j + 1 < result.count { result[j] ^= result[j + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func reedSolomonRemainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: divisor.count)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for i in 0..<result.count { result[i] ^= multiply(divisor[i], factor) }
            }
            return result
        }

        /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            for i in stride(from: 7, through: 0, by: -1) {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= ((Int(y) >> i) & 1) * Int(x)
            }
            return UInt8(z & 0xFF)
        }

        // MARK: Drawing

        private mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y][x] = dark
            isFunction[y][x] = true
        }

        private mutating func drawFunctionPatterns(correction: Correction) {
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            let positions = alignmentPositions
            let last = positions.count - 1
            for (i, x) in positions.enumerated() {
                for (j, y) in positions.enumerated() where !((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0)) {
                    drawAlignment(x, y)
                }
            }
            drawFormatBits(correction: correction, mask: 0)   // reserved now, drawn for real later
            drawVersion()
        }

        private var alignmentPositions: [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
            var result = [Int](repeating: 6, count: count)
            var position = size - 7
            for i in stride(from: count - 1, through: 1, by: -1) {
                result[i] = position
                position -= step
            }
            return result
        }

        private mutating func drawFinder(_ x: Int, _ y: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    let (xx, yy) = (x + dx, y + dy)
                    if (0..<size).contains(xx), (0..<size).contains(yy) { set(xx, yy, distance != 2 && distance != 4) }
                }
            }
        }

        private mutating func drawAlignment(_ x: Int, _ y: Int) {
            for dy in -2...2 {
                for dx in -2...2 { set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
            }
        }

        private mutating func drawFormatBits(correction: Correction, mask: Int) {
            let data = correction.formatBits << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }
            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)   // the dark module
        }

        private mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        private mutating func drawCodewords(_ data: [UInt8]) {
            var i = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !isFunction[y][x], i < data.count * 8 {
                            modules[y][x] = (data[i >> 3] >> (7 - (i & 7))) & 1 == 1
                            i += 1
                        }
                    }
                }
                right -= 2
            }
        }

        private mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y][x] {
                    let invert = switch mask {
                    case 0: (x + y) % 2 == 0
                    case 1: y % 2 == 0
                    case 2: x % 3 == 0
                    case 3: (x + y) % 3 == 0
                    case 4: (x / 3 + y / 2) % 2 == 0
                    case 5: x * y % 2 + x * y % 3 == 0
                    case 6: (x * y % 2 + x * y % 3) % 2 == 0
                    default: ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y][x].toggle() }
                }
            }
        }

        // MARK: Choosing the mask

        /// The standard's penalty: runs of five or more, 2×2 blocks, finder-like patterns, and
        /// the balance of dark and light.
        private func penaltyScore() -> Int {
            var penalty = 0
            let lines = modules + (0..<size).map { x in (0..<size).map { y in modules[y][x] } }
            for line in lines {
                var run = 1
                for i in 1...line.count {
                    if i < line.count, line[i] == line[i - 1] { run += 1; continue }
                    if run >= 5 { penalty += run - 2 }
                    run = 1
                }
                // 1:1:3:1:1 with four light modules on either side.
                let pattern: [Bool] = [true, false, true, true, true, false, true]
                for i in 0...(line.count - 7) where Array(line[i..<i + 7]) == pattern {
                    let before = i >= 4 && line[(i - 4)..<i].allSatisfy { !$0 }
                    let after = i + 11 <= line.count && line[(i + 7)..<(i + 11)].allSatisfy { !$0 }
                    if before || after { penalty += 40 }
                    if before && after { penalty += 40 }
                }
            }
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let colour = modules[y][x]
                    if colour == modules[y][x + 1], colour == modules[y + 1][x], colour == modules[y + 1][x + 1] { penalty += 3 }
                }
            }
            let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            penalty += k * 10
            return penalty
        }

        // MARK: Tables (index 0 unused), by level: low, medium, quartile, high

        static let eccCodewordsPerBlock: [[Int]] = [
            [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
            [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
            [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
            [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        ]

        static let errorCorrectionBlocks: [[Int]] = [
            [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
            [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
            [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
            [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
        ]
    }
}
