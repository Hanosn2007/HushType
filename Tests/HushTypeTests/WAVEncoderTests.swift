import XCTest
@testable import HushType

final class WAVEncoderTests: XCTestCase {
    private func u32le(_ data: Data, offset: Int) -> UInt32 {
        let b = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        var v: UInt32 = 0
        for (i, byte) in b.enumerated() { v |= UInt32(byte) << (8 * i) }
        return v
    }

    private func payloadInt16(_ data: Data, index: Int) -> Int16 {
        let lo = data[data.startIndex + 44 + index * 2]
        let hi = data[data.startIndex + 44 + index * 2 + 1]
        return Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
    }

    func testHeaderCorrectness() {
        let data = WAVEncoder.encode(samples: Array(repeating: 0, count: 1600))
        XCTAssertEqual(data.count, 44 + 3200)
        XCTAssertEqual(
            String(bytes: data[data.startIndex ..< data.startIndex + 4], encoding: .ascii),
            "RIFF"
        )
        XCTAssertEqual(
            String(bytes: data[data.startIndex + 8 ..< data.startIndex + 12], encoding: .ascii),
            "WAVE"
        )
        XCTAssertEqual(u32le(data, offset: 24), 16000) // sample rate
        XCTAssertEqual(u32le(data, offset: 40), 3200)  // data size
    }

    func testClampPositive() {
        let data = WAVEncoder.encode(samples: [2.0])
        XCTAssertEqual(payloadInt16(data, index: 0), 32767)
    }

    func testClampNegative() {
        let data = WAVEncoder.encode(samples: [-2.0])
        XCTAssertEqual(payloadInt16(data, index: 0), -32768)
    }

    func testExactFullScale() {
        let pos = WAVEncoder.encode(samples: [1.0])
        XCTAssertEqual(payloadInt16(pos, index: 0), 32767)
        let neg = WAVEncoder.encode(samples: [-1.0])
        XCTAssertEqual(payloadInt16(neg, index: 0), -32767)
    }

    func testZero() {
        let data = WAVEncoder.encode(samples: [0.0])
        XCTAssertEqual(payloadInt16(data, index: 0), 0)
    }

    func testEmptyInput() {
        let data = WAVEncoder.encode(samples: [])
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(u32le(data, offset: 40), 0)
    }

    func testRounding() {
        let data = WAVEncoder.encode(samples: [0.5])
        XCTAssertEqual(payloadInt16(data, index: 0), 16384)
    }
}
