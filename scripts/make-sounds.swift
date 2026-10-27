// Generates the built-in soundscapes as loopable .caf files.
// Usage: swift scripts/make-sounds.swift <output-dir>
// Each file is a seamless loop of a few seconds; everything is synthesized so
// the repository carries no binary audio assets.
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sounds"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

// 32-bit float mono CAF writer (AudioFile API via CoreAudio headers needs C
// glue; a hand-rolled CAF container is small and dependency-free).
struct CAFWriter {
    let sampleRate: Double
    var samples: [Float] = []

    mutating func write(to url: URL) throws {
        var data = Data()
        func appendBE32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func appendBE64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func appendHost<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        // File header: mFileType 'caff', mFileVersion 1, mFileFlags 0
        data.append(contentsOf: [0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00])
        // Audio description chunk ('desc'): CAFAudioDescription, 32 bytes, all
        // big-endian — rate(8) formatID(4) flags(4) bytesPerPacket(4)
        // framesPerPacket(4) channelsPerFrame(4) bitsPerChannel(4).
        // (No mBytesPerFrame / mReserved: unlike the CoreAudio ASBD.)
        appendBE32(0x64657363) // 'desc'
        appendBE64(32)
        appendBE64(sampleRate.bitPattern) // big-endian float64
        appendBE32(0x6C70636D) // format 'lpcm'
        appendBE32(3) // flags: little-endian (bit0) + float (bit1), per CAF spec
        appendBE32(4) // bytes per packet (mono float32)
        appendBE32(1) // frames per packet
        appendBE32(1) // channels per frame (mono)
        appendBE32(32) // bits per channel (float32)
        // Data chunk
        appendBE32(0x64617461) // 'data'
        appendBE64(UInt64(samples.count * 4))
        for sample in samples { appendHost(sample) }
        try data.write(to: url, options: .atomic)
    }
}

func render(_ name: String, sampleRate: Double = 44_100, seconds: Double, _ synth: (Double, inout [Float]) -> Void) throws {
    var samples: [Float] = []
    synth(sampleRate, &samples)
    // Fade the seam so the loop point is inaudible.
    let fade = Int(min(0.02, seconds / 20) * sampleRate)
    if samples.count > 2 * fade {
        for i in 0..<fade {
            let factor = Float(i) / Float(fade)
            samples[i] *= factor
            samples[samples.count - 1 - i] *= factor
        }
    }
    var writer = CAFWriter(sampleRate: sampleRate, samples: samples)
    try writer.write(to: URL(fileURLWithPath: "\(output)/\(name).caf"))
    print("\(name).caf: \(samples.count) samples (\(seconds)s)")
}

func lcg(_ seed: UInt64) -> () -> Float {
    var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    return {
        state &*= 6_364_136_223_846_793_005
        state &+= 1_442_695_040_888_963_407
        return Float((state >> 33) & 0xFFFF_FFFF) / Float(UInt32.max) * 2 - 1
    }
}

// White noise: uniform random, loop-consistent by wrapping the stream.
try render("white-noise", seconds: 8) { rate, samples in
    let random = lcg(0x57484954)
    for _ in 0..<Int(8 * rate) { samples.append(random() * 0.16) }
}

// Rain: filtered noise shaped into droplet bursts over a soft bed.
try render("rain", seconds: 12) { rate, samples in
    let random = lcg(0x5241494E)
    var lowpass: Float = 0
    var medium: Float = 0
    for i in 0..<Int(12 * rate) {
        let white = random()
        lowpass += 0.06 * (white - lowpass)
        medium += 0.012 * (white - medium)
        let t = Double(i) / rate
        // Slow amplitude breathing so the loop seam is masked.
        let swell = 0.72 + 0.28 * sin(t * 2 * .pi / 6)
        samples.append((lowpass * 0.28 + medium * 0.5) * Float(swell))
    }
}

// Forest ambience: warm filtered noise bed plus sparse soft bird chirps.
try render("forest", seconds: 16) { rate, samples in
    let random = lcg(0x464F5245)
    var bed: Float = 0
    for i in 0..<Int(16 * rate) {
        let white = random()
        bed += 0.008 * (white - bed)
        let t = Double(i) / rate
        var value = Float(bed) * 0.22
        // Two deterministic chirp clusters per loop, sine sweeps around 2–3 kHz.
        for (start, base) in [(2.4, 2_300.0), (6.1, 2_900.0), (10.8, 2_600.0)] {
            let phase = t - start
            if 0..<0.18 ~= phase {
                let env = sin(phase / 0.18 * .pi)
                let freq = base + 420 * sin(phase * 34)
                value += Float(env * 0.05 * sin(2 * .pi * freq * phase))
            }
        }
        samples.append(value)
    }
}

// Evening pad: a slowly beating minor-add9 chord, pure synthesized calm.
try render("evening-pad", seconds: 20) { rate, samples in
    let chord: [Double] = [220.0, 261.63, 329.63, 493.88, 550.0]
    let gains: [Double] = [0.16, 0.13, 0.11, 0.07, 0.06]
    let beats: [Double] = [0.35, -0.4, 0.3, -0.25, 0.2]
    for i in 0..<Int(20 * rate) {
        let t = Double(i) / rate
        var value = 0.0
        for (voice, b) in zip(chord.indices, beats) {
            let freq = chord[voice] + b * 0.5
            let g = gains[voice]
            value += g * sin(2 * .pi * freq * t)
            // Slow detune shimmer.
            value += g * 0.4 * sin(2 * .pi * (freq + 1.5) * t)
        }
        let swell = 0.8 + 0.2 * sin(t * 2 * .pi / 10)
        samples.append(Float(value * 0.42 * swell))
    }
}
