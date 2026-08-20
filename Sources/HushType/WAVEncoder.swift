import Foundation

/// Encodes Float32 sample buffers into in-memory RIFF/WAVE files
/// (16-bit PCM, mono) for upload to cloud STT APIs.
enum WAVEncoder {
    /// 16 kHz mono 16-bit PCM WAV. `samples` are Float32, nominally in -1.0...1.0
    /// but MAY overshoot (hot mics / converter transients) — clamping is mandatory.
    static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        let dataSize = UInt32(samples.count) * 2
        let chunkSize = UInt32(36) + dataSize // everything after the "RIFF" size field

        var data = Data(capacity: Int(chunkSize) + 8)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))

        // "fmt " subchunk
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))                 // subchunk size (PCM)
        appendLE(UInt16(1))                  // audio format: 1 = PCM
        appendLE(UInt16(1))                  // channels: mono
        appendLE(UInt32(sampleRate))         // sample rate
        appendLE(UInt32(sampleRate) * 2)     // byte rate = sampleRate * blockAlign
        appendLE(UInt16(2))                  // block align = channels * bits/8
        appendLE(UInt16(16))                 // bits per sample

        // "data" subchunk
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)

        // Payload: Int16 little-endian, clamped (naive Int16(sample * 32767)
        // is a Swift runtime trap on overshoot — do not remove the clamp).
        for sample in samples {
            let v = Int16(max(-32768.0, min(32767.0, (sample * 32767.0).rounded())))
            appendLE(v)
        }

        return data
    }
}
