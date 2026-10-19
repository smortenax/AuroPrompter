import Foundation

/// Voice clean-up chain: noise reduction, vocal EQ, gentle compression, loudness normalisation
/// (ITU-R BS.1770 / EBU R128 integrated loudness) and a peak limiter. Pure Swift, mono, offline.
enum AudioDSP {
    struct Settings {
        var noiseReductionDB: Double = 12
        var voiceEQ: Bool = true
        var targetLUFS: Double = -14
        var ceilingDB: Double = -1.5
    }

    struct Output {
        var samples: [Float]
        var inputLUFS: Double
        var outputLUFS: Double
    }

    static func enhance(_ input: [Float], sampleRate fs: Double, settings: Settings) -> Output {
        var x = input
        let inputLUFS = integratedLoudness(x, sampleRate: fs)

        if settings.noiseReductionDB > 0 {
            x = reduceNoise(x, reductionDB: settings.noiseReductionDB)
        }

        // Rumble and mains hum sit below the voice: always cut them.
        var filters = [Biquad.highPass(frequency: 80, q: 0.707, sampleRate: fs)]
        if settings.voiceEQ {
            filters += [
                Biquad.peaking(frequency: 250, gainDB: -3, q: 1.0, sampleRate: fs),   // less mud
                Biquad.peaking(frequency: 3500, gainDB: 3, q: 0.9, sampleRate: fs),   // presence
                Biquad.highShelf(frequency: 10000, gainDB: 1.5, q: 0.707, sampleRate: fs), // air
            ]
        }
        for i in filters.indices { filters[i].process(&x) }

        var loudness = integratedLoudness(x, sampleRate: fs)
        guard loudness.isFinite else {
            return Output(samples: x, inputLUFS: inputLUFS, outputLUFS: loudness)
        }

        compress(&x, thresholdDB: loudness + 8, ratio: 2.5, attackMs: 5, releaseMs: 120, sampleRate: fs)

        // A few rounds, because the limiter takes a little loudness back.
        for _ in 0..<3 {
            loudness = integratedLoudness(x, sampleRate: fs)
            guard loudness.isFinite, abs(settings.targetLUFS - loudness) > 0.3 else { break }
            applyGain(&x, db: settings.targetLUFS - loudness)
            limit(&x, ceilingDB: settings.ceilingDB, attackMs: 3, releaseMs: 80, sampleRate: fs)
        }
        return Output(samples: x, inputLUFS: inputLUFS, outputLUFS: integratedLoudness(x, sampleRate: fs))
    }

    // MARK: - Loudness (BS.1770-4)

    static func integratedLoudness(_ x: [Float], sampleRate fs: Double) -> Double {
        guard !x.isEmpty else { return -.infinity }
        var shelf = Biquad.highShelf(frequency: 1681.974450955533, gainDB: 3.999843853973347,
                                     q: 0.7071752369554196, sampleRate: fs)
        var highPass = Biquad.highPass(frequency: 38.13547087602444, q: 0.5003270373238773, sampleRate: fs)

        var cumulative = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count {
            let y = highPass.process(shelf.process(Double(x[i])))
            cumulative[i + 1] = cumulative[i] + y * y
        }

        let block = Int(0.4 * fs)
        let step = Int(0.1 * fs)
        var energies: [Double] = []
        if x.count >= block {
            var start = 0
            while start + block <= x.count {
                energies.append((cumulative[start + block] - cumulative[start]) / Double(block))
                start += step
            }
        } else {
            energies = [cumulative[x.count] / Double(x.count)]
        }

        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let absoluteGated = energies.filter { $0 > 0 && lufs($0) > -70 }
        guard !absoluteGated.isEmpty else { return -.infinity }
        let relativeGate = lufs(absoluteGated.reduce(0, +) / Double(absoluteGated.count)) - 10
        let gated = absoluteGated.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    // MARK: - Dynamics

    static func applyGain(_ x: inout [Float], db: Double) {
        let gain = Float(pow(10, db / 20))
        for i in x.indices { x[i] *= gain }
    }

    static func compress(_ x: inout [Float], thresholdDB: Double, ratio: Double,
                         attackMs: Double, releaseMs: Double, sampleRate fs: Double) {
        let attack = exp(-1 / (attackMs * 0.001 * fs))
        let release = exp(-1 / (releaseMs * 0.001 * fs))
        var envelope = 0.0
        for i in x.indices {
            let level = Double(abs(x[i]))
            let coefficient = level > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * level
            let levelDB = 20 * log10(envelope + 1e-9)
            let over = levelDB - thresholdDB
            if over > 0 {
                x[i] *= Float(pow(10, -over * (1 - 1 / ratio) / 20))
            }
        }
    }

    /// Look-ahead-free brickwall limiter: a backward pass ramps the gain down ahead of each peak,
    /// a forward pass lets it recover smoothly. The result never exceeds the ceiling.
    static func limit(_ x: inout [Float], ceilingDB: Double, attackMs: Double, releaseMs: Double, sampleRate fs: Double) {
        guard !x.isEmpty else { return }
        let ceiling = pow(10, ceilingDB / 20)
        let attack = exp(-1 / (attackMs * 0.001 * fs))
        let release = exp(-1 / (releaseMs * 0.001 * fs))
        var gain = [Double](repeating: 1, count: x.count)
        for i in x.indices {
            let peak = Double(abs(x[i]))
            if peak > ceiling { gain[i] = ceiling / peak }
        }
        var next = 1.0
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            next = min(gain[i], 1 - (1 - next) * attack)
            gain[i] = next
        }
        var previous = 1.0
        for i in x.indices {
            previous = min(gain[i], 1 - (1 - previous) * release)
            x[i] = Float(Double(x[i]) * previous)
        }
    }

    // MARK: - Noise reduction (spectral gating)

    /// Learns the noise spectrum from the quietest moments and turns down every frequency band
    /// that is not clearly above it, by at most `reductionDB`.
    static func reduceNoise(_ input: [Float], reductionDB: Double) -> [Float] {
        let size = 1024
        let hop = size / 4
        guard input.count > size * 8 else { return input }

        let bins = size / 2 + 1
        let window = (0..<size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)) }
        let fft = FFT(size: size)
        let padded = [Float](repeating: 0, count: size) + input + [Float](repeating: 0, count: size)
        let frameCount = (padded.count - size) / hop + 1

        // 1. Find the quietest 10% of frames and average their spectra: that is the noise profile.
        var energies: [(index: Int, energy: Double)] = []
        energies.reserveCapacity(frameCount)
        for f in 0..<frameCount {
            var energy = 0.0
            let start = f * hop
            for i in 0..<size {
                let v = Double(padded[start + i]) * window[i]
                energy += v * v
            }
            energies.append((f, energy))
        }
        // Skip the zero padding at either end when picking quiet frames.
        let candidates = energies.filter { $0.energy > 1e-12 }.sorted { $0.energy < $1.energy }
        let quiet = candidates.prefix(max(8, candidates.count / 10))
        guard !quiet.isEmpty else { return input }

        var noise = [Double](repeating: 0, count: bins)
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for frame in quiet {
            let start = frame.index * hop
            for i in 0..<size { re[i] = Double(padded[start + i]) * window[i]; im[i] = 0 }
            fft.transform(&re, &im, inverse: false)
            for k in 0..<bins { noise[k] += re[k] * re[k] + im[k] * im[k] }
        }
        for k in 0..<bins { noise[k] /= Double(quiet.count) }

        // 2. Gate each frame against the profile and overlap-add the result.
        let minGain = pow(10, -reductionDB / 20)
        let oversubtraction = 2.0
        var output = [Double](repeating: 0, count: padded.count)
        var previousGain = [Double](repeating: 1, count: bins)
        var gain = [Double](repeating: 1, count: bins)
        for f in 0..<frameCount {
            let start = f * hop
            for i in 0..<size { re[i] = Double(padded[start + i]) * window[i]; im[i] = 0 }
            fft.transform(&re, &im, inverse: false)

            for k in 0..<bins {
                let power = re[k] * re[k] + im[k] * im[k] + 1e-20
                let raw = max(minGain, 1 - oversubtraction * noise[k] / power)
                // Smooth over time so the noise floor does not "twinkle".
                gain[k] = raw > previousGain[k] ? raw : 0.6 * previousGain[k] + 0.4 * raw
            }
            // Smooth across neighbouring bands as well.
            for k in 0..<bins {
                let lower = gain[max(0, k - 1)], upper = gain[min(bins - 1, k + 1)]
                let smoothed = 0.25 * lower + 0.5 * gain[k] + 0.25 * upper
                re[k] *= smoothed; im[k] *= smoothed
                if k > 0 && k < size / 2 {
                    re[size - k] *= smoothed; im[size - k] *= smoothed
                }
            }
            swap(&previousGain, &gain)

            fft.transform(&re, &im, inverse: true)
            for i in 0..<size { output[start + i] += re[i] * window[i] }
        }

        // Hann analysis + Hann synthesis at 75% overlap sums to 1.5.
        return (0..<input.count).map { Float(output[size + $0] / 1.5) }
    }
}

/// Second-order IIR filter (Robert Bristow-Johnson's cookbook), transposed direct form II.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func process(_ samples: inout [Float]) {
        for i in samples.indices { samples[i] = Float(process(Double(samples[i]))) }
    }

    static func highPass(frequency: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / fs
        let cosW = cos(w0), alpha = sin(w0) / (2 * q)
        return Biquad(b0: (1 + cosW) / 2, b1: -(1 + cosW), b2: (1 + cosW) / 2,
                      a0: 1 + alpha, a1: -2 * cosW, a2: 1 - alpha)
    }

    static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / fs
        let cosW = cos(w0), alpha = sin(w0) / (2 * q)
        return Biquad(b0: 1 + alpha * a, b1: -2 * cosW, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * cosW, a2: 1 - alpha / a)
    }

    static func highShelf(frequency: Double, gainDB: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / fs
        let cosW = cos(w0), alpha = sin(w0) / (2 * q)
        let twoRootAAlpha = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) + (a - 1) * cosW + twoRootAAlpha),
                      b1: -2 * a * ((a - 1) + (a + 1) * cosW),
                      b2: a * ((a + 1) + (a - 1) * cosW - twoRootAAlpha),
                      a0: (a + 1) - (a - 1) * cosW + twoRootAAlpha,
                      a1: 2 * ((a - 1) - (a + 1) * cosW),
                      a2: (a + 1) - (a - 1) * cosW - twoRootAAlpha)
    }
}

/// Iterative radix-2 complex FFT. `size` must be a power of two.
struct FFT {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitReversed: [Int]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosTable = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        bitReversed = (0..<size).map { index in
            var reversed = 0
            var value = index
            for _ in 0..<bits { reversed = (reversed << 1) | (value & 1); value >>= 1 }
            return reversed
        }
    }

    /// In place. The inverse transform is scaled by 1/size.
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = size
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                for i in 0..<n {
                    let j = bitReversed[i]
                    if j > i { re.swapAt(i, j); im.swapAt(i, j) }
                }
                let sign: Double = inverse ? 1 : -1
                var length = 2
                while length <= n {
                    let half = length / 2
                    let tableStep = n / length
                    var start = 0
                    while start < n {
                        for k in 0..<half {
                            let wr = cosTable[k * tableStep]
                            let wi = sign * sinTable[k * tableStep]
                            let a = start + k, b = a + half
                            let tr = re[b] * wr - im[b] * wi
                            let ti = re[b] * wi + im[b] * wr
                            re[b] = re[a] - tr; im[b] = im[a] - ti
                            re[a] += tr; im[a] += ti
                        }
                        start += length
                    }
                    length <<= 1
                }
                if inverse {
                    let scale = 1 / Double(n)
                    for i in 0..<n { re[i] *= scale; im[i] *= scale }
                }
            }
        }
    }
}
