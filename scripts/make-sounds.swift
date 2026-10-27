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
        // Top 32 bits of the 64-bit state (a >> 33 would leave only 31 bits
        // and map every sample into [-1, 0) — a half-wave DC skew).
        return Float((state >> 32) & 0xFFFF_FFFF) / Float(UInt32.max) * 2 - 1
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

// Campfire: leaky-integrator rumble (deep fire body) with sparse randomized
// crackle impulses — short exponentially decaying noise bursts, unlike the
// continuous filtered-noise beds of rain/forest. Intensity swells twice per
// loop; loop length 14 s.
try render("campfire", seconds: 14) { rate, samples in
    let random = lcg(0x46495245) // "FIRE"
    var rumble: Float = 0
    var mid: Float = 0
    var pops: [(age: Double, amp: Float, decay: Double)] = []
    for _ in 0..<Int(14 * rate) {
        let white = random()
        rumble += 0.015 * (white - rumble) // ~105 Hz one-pole: fire roar
        mid += 0.25 * (white - mid)        // brighter bed the crackles ride on
        let t = Double(Double(samples.count)) / rate
        let swell = 0.75 + 0.25 * sin(t * 2 * .pi / 7) // 2 cycles per loop
        // Poisson-ish thinning: ~20 triggers/s; amplitude biased small,
        // decay 2–10 ms. coin() folds the [-1, 1) stream to [0, 1) so
        // probability draws and the decay range stay nonnegative.
        func coin() -> Float { (random() + 1) * 0.5 }
        if coin() < 0.000_45 {
            let a = Double(coin())
            pops.append((0, Float(0.08 + 0.5 * a * a), 0.002 + 0.008 * Double(coin())))
        }
        var crackle: Float = 0
        var alive: [(age: Double, amp: Float, decay: Double)] = []
        for var p in pops {
            crackle += p.amp * Float(exp(-p.age / p.decay)) * random()
            p.age += 1 / rate
            if p.age < p.decay * 7 { alive.append(p) }
        }
        pops = alive
        let body = (rumble * 0.4 + mid * 0.06) * Float(swell) + crackle * 0.12
        // Fire pops stack up; soft-clip the bus so bursts stay punchy but the
        // file never exceeds full scale.
        samples.append(body <= -1 ? -1 : (body >= 1 ? 1 : Float(tanh(Double(body) * 0.75) / tanh(0.75))))
    }
}

// Ocean waves: a quiet distant-surf bed under a periodic surge every 8 s —
// fast attack, long wash-out — whose bright noise layer opens only at the
// wave peak. Waves alternate big/small once per loop (16 s), so both
// modulators complete whole cycles at the seam.
try render("ocean-waves", seconds: 16) { rate, samples in
    let random = lcg(0x4F434541) // "OCEA"
    var surf: Float = 0
    var bright: Float = 0
    for _ in 0..<Int(16 * rate) {
        let white = random()
        surf += 0.01 * (white - surf)     // distant surf bed (~70 Hz)
        bright += 0.16 * (white - bright) // breaking wash (~1.1 kHz)
        let t = Double(Double(samples.count)) / rate
        let p = t.truncatingRemainder(dividingBy: 8) / 8 // one wave per 8 s
        let env: Double
        if p < 0.3 {
            env = 0.5 - 0.5 * cos(.pi * p / 0.3)          // steep rise ~2.4 s
        } else {
            env = 0.5 + 0.5 * cos(.pi * (p - 0.3) / 0.7)  // slow wash-out ~5.6 s
        }
        // Alternate big/small waves: exactly 1 cycle per 16 s loop.
        let size = 0.6 + 0.4 * sin(t * 2 * .pi / 16)
        let wave = 0.06 + 0.94 * env * size
        samples.append(surf * 0.3 + bright * Float(wave) * 0.85)
    }
}

// Morning birdsong: a lighter, brighter air bed than forest's dark one, with
// busier higher-pitched birds — fast-trilled syllables at 3–5 kHz, a long
// warble, and soft low dove coos (~600 Hz) for timbre contrast. Syllables are
// swept sine bursts with raised-cosine envelopes placed away from the seam;
// loop length 18 s.
try render("morning-birds", seconds: 18) { rate, samples in
    let random = lcg(0x4441574E) // "DAWN"
    // One syllable: FM sweep with optional fast warble, raised-cosine envelope.
    func bird(_ t: Double, at start: Double, dur: Double, from f0: Double, to f1: Double,
              warble: Double = 0, rate w: Double = 0, gain: Double) -> Double {
        let p = t - start
        guard 0..<dur ~= p else { return 0 }
        var env = sin(.pi * p / dur)
        env *= env
        let f = f0 + (f1 - f0) * (p / dur) + warble * sin(2 * .pi * w * p)
        return gain * env * sin(2 * .pi * f * p)
    }
    for _ in 0..<Int(18 * rate) {
        let white = random()
        var air: Float = 0
        air += 0.35 * (white - air) // light high morning air (~2.4 kHz)
        let t = Double(Double(samples.count)) / rate
        let dawn = 1 + 0.2 * sin(t * 2 * .pi / 9) // gentle glow, 2 cycles/loop
        var value = Float(air) * 0.04 * Float(dawn)
        // Quick bright trill: three short syllables.
        for s in [1.3, 1.48, 1.66] {
            value += Float(bird(t, at: s, dur: 0.09, from: 3_900, to: 4_200, warble: 250, rate: 38, gain: 0.045))
        }
        // Two descending whistles.
        value += Float(bird(t, at: 4.6, dur: 0.28, from: 5_200, to: 3_600, gain: 0.05))
        value += Float(bird(t, at: 5.05, dur: 0.22, from: 5_000, to: 3_700, gain: 0.04))
        // Long fast warble.
        value += Float(bird(t, at: 8.2, dur: 0.42, from: 3_100, to: 3_100, warble: 320, rate: 42, gain: 0.045))
        // Mid trill pair.
        for s in [11.4, 11.62] {
            value += Float(bird(t, at: s, dur: 0.16, from: 2_800, to: 3_400, warble: 200, rate: 30, gain: 0.04))
        }
        // Soft low dove coos, well below forest's chirp range.
        for s in [13.0, 13.55, 14.1] {
            value += Float(bird(t, at: s, dur: 0.3, from: 640, to: 560, gain: 0.05))
        }
        // A closing chip near the end (still clear of the seam).
        value += Float(bird(t, at: 16.4, dur: 0.12, from: 4_300, to: 4_100, warble: 150, rate: 35, gain: 0.035))
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
