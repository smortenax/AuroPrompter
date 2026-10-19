// Runs on the audio thread: spectral noise reduction (noise learned during the countdown),
// automatic gain towards the loudness target, a look-ahead peak limiter, and a BS.1770 loudness meter.

class Biquad {
  constructor(b0, b1, b2, a0, a1, a2) {
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0;
    this.z1 = 0; this.z2 = 0;
  }
  process(x) {
    const y = this.b0 * x + this.z1;
    this.z1 = this.b1 * x - this.a1 * y + this.z2;
    this.z2 = this.b2 * x - this.a2 * y;
    return y;
  }
  static highPass(f, q, fs) {
    const w = 2 * Math.PI * f / fs, c = Math.cos(w), al = Math.sin(w) / (2 * q);
    return new Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
  }
  static highShelf(f, g, q, fs) {
    const A = 10 ** (g / 40), w = 2 * Math.PI * f / fs, c = Math.cos(w), al = Math.sin(w) / (2 * q), t = 2 * Math.sqrt(A) * al;
    return new Biquad(A * ((A + 1) + (A - 1) * c + t), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - t),
      (A + 1) - (A - 1) * c + t, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - t);
  }
}

class FFT {
  constructor(n) {
    this.n = n;
    this.cos = new Float64Array(n / 2);
    this.sin = new Float64Array(n / 2);
    for (let k = 0; k < n / 2; k++) { this.cos[k] = Math.cos(2 * Math.PI * k / n); this.sin[k] = Math.sin(2 * Math.PI * k / n); }
    const bits = Math.log2(n);
    this.rev = new Uint32Array(n);
    for (let i = 0; i < n; i++) {
      let r = 0, v = i;
      for (let b = 0; b < bits; b++) { r = (r << 1) | (v & 1); v >>= 1; }
      this.rev[i] = r;
    }
  }
  transform(re, im, inverse) {
    const n = this.n;
    for (let i = 0; i < n; i++) {
      const j = this.rev[i];
      if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    const sign = inverse ? 1 : -1;
    for (let len = 2; len <= n; len <<= 1) {
      const half = len >> 1, step = n / len;
      for (let s = 0; s < n; s += len) {
        for (let k = 0; k < half; k++) {
          const wr = this.cos[k * step], wi = sign * this.sin[k * step];
          const a = s + k, b = a + half;
          const tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
        }
      }
    }
    if (inverse) for (let i = 0; i < n; i++) { re[i] /= n; im[i] /= n; }
  }
}

const N = 1024, HOP = 256, LAT = N - HOP, BINS = N / 2 + 1;

class VoiceProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = options.processorOptions || {};
    const fs = sampleRate;
    this.reductionDB = o.reductionDB ?? 12;
    this.target = o.targetLUFS ?? -14;
    this.gainDB = o.startGainDB ?? 12;
    this.ceiling = 10 ** (-1.5 / 20);

    // Noise reduction state
    this.fft = new FFT(N);
    this.win = new Float64Array(N);
    for (let i = 0; i < N; i++) this.win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / N);
    this.inFifo = new Float64Array(N);
    this.outFifo = new Float64Array(N);
    this.accum = new Float64Array(2 * N);
    this.re = new Float64Array(N);
    this.im = new Float64Array(N);
    this.rover = LAT;
    this.noise = null;
    this.noiseSum = new Float64Array(BINS);
    this.noiseFrames = 0;
    this.learning = false;
    this.prevGain = new Float64Array(BINS).fill(1);
    this.gain = new Float64Array(BINS);

    // Loudness: K-weighting for the AGC detector and for the output meter
    this.kInShelf = Biquad.highShelf(1681.974450955533, 3.999843853973347, 0.7071752369554196, fs);
    this.kInHp = Biquad.highPass(38.13547087602444, 0.5003270373238773, fs);
    this.kOutShelf = Biquad.highShelf(1681.974450955533, 3.999843853973347, 0.7071752369554196, fs);
    this.kOutHp = Biquad.highPass(38.13547087602444, 0.5003270373238773, fs);
    this.momentaryCoef = Math.exp(-1 / (0.4 * fs));
    this.momentary = 0;
    this.shortTermLUFS = null;
    this.blockSize = Math.round(0.1 * fs);
    this.blockAcc = 0; this.blockCount = 0;
    this.subBlocks = [];
    this.blocks = [];
    this.metering = false;

    // Limiter: look-ahead delay line with a sliding-window peak
    this.look = Math.round(0.005 * fs);
    this.delay = new Float64Array(this.look);
    this.dpos = 0;
    this.peakWin = new Float64Array(this.look);
    this.limGain = 1;
    this.attack = Math.exp(-1 / (this.look / 4));
    this.release = Math.exp(-1 / (0.08 * fs));
    this.reportCountdown = 0;

    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'learn') {
        if (m.on) { this.learning = true; this.noiseSum.fill(0); this.noiseFrames = 0; }
        else {
          this.learning = false;
          if (this.noiseFrames > 20) {
            this.noise = new Float64Array(BINS);
            for (let k = 0; k < BINS; k++) this.noise[k] = this.noiseSum[k] / this.noiseFrames;
          }
        }
      } else if (m.type === 'meter') {
        this.metering = m.on;
        if (m.on) { this.blocks = []; this.subBlocks = []; this.blockAcc = 0; this.blockCount = 0; }
        else this.report(true);
      } else if (m.type === 'settings') {
        if (m.reductionDB != null) this.reductionDB = m.reductionDB;
        if (m.targetLUFS != null) this.target = m.targetLUFS;
      }
    };
  }

  spectralFrame() {
    const { re, im, win, fft } = this;
    for (let i = 0; i < N; i++) { re[i] = this.inFifo[i] * win[i]; im[i] = 0; }
    fft.transform(re, im, false);
    if (this.learning) {
      for (let k = 0; k < BINS; k++) this.noiseSum[k] += re[k] * re[k] + im[k] * im[k];
      this.noiseFrames++;
    }
    if (this.noise && this.reductionDB > 0) {
      const minGain = 10 ** (-this.reductionDB / 20);
      const g = this.gain, pg = this.prevGain;
      for (let k = 0; k < BINS; k++) {
        const p = re[k] * re[k] + im[k] * im[k] + 1e-20;
        const raw = Math.max(minGain, 1 - 2 * this.noise[k] / p);
        g[k] = raw > pg[k] ? raw : 0.6 * pg[k] + 0.4 * raw;
      }
      for (let k = 0; k < BINS; k++) {
        const s = 0.25 * g[Math.max(0, k - 1)] + 0.5 * g[k] + 0.25 * g[Math.min(BINS - 1, k + 1)];
        re[k] *= s; im[k] *= s;
        if (k > 0 && k < N / 2) { re[N - k] *= s; im[N - k] *= s; }
      }
      this.prevGain = g; this.gain = pg;
    }
    fft.transform(re, im, true);
    for (let i = 0; i < N; i++) this.accum[i] += re[i] * win[i] / 1.5;
    for (let i = 0; i < HOP; i++) this.outFifo[i] = this.accum[i];
    this.accum.copyWithin(0, HOP);
    this.accum.fill(0, 2 * N - HOP);
    this.inFifo.copyWithin(0, HOP, N);
  }

  lufs(z) { return -0.691 + 10 * Math.log10(z); }

  integrated() {
    const abs = this.blocks.filter((z) => z > 0 && this.lufs(z) > -70);
    if (!abs.length) return null;
    const rel = this.lufs(abs.reduce((a, b) => a + b, 0) / abs.length) - 10;
    const gated = abs.filter((z) => this.lufs(z) > rel);
    return gated.length ? this.lufs(gated.reduce((a, b) => a + b, 0) / gated.length) : null;
  }

  report(final) {
    this.port.postMessage({ type: 'level', final, gainDB: this.gainDB, lufs: this.integrated(), shortTerm: this.shortTermLUFS });
  }

  process(inputs, outputs) {
    const input = inputs[0] && inputs[0][0];
    const output = outputs[0];
    const n = output[0].length;
    for (let i = 0; i < n; i++) {
      const x = input ? input[i] : 0;

      // 1. Noise reduction (overlap-add STFT, LAT samples of latency)
      this.inFifo[this.rover] = x;
      let y = this.outFifo[this.rover - LAT];
      this.rover++;
      if (this.rover >= N) { this.rover = LAT; this.spectralFrame(); }

      // 2. Automatic gain: follow the speech loudness slowly, never pump on pauses
      const k = this.kInHp.process(this.kInShelf.process(y));
      this.momentary = this.momentaryCoef * this.momentary + (1 - this.momentaryCoef) * k * k;
      y *= 10 ** (this.gainDB / 20);

      // 3. Look-ahead limiter
      const delayed = this.delay[this.dpos];
      this.delay[this.dpos] = y;
      this.peakWin[this.dpos] = Math.abs(y);
      this.dpos = (this.dpos + 1) % this.look;
      // Window peak, recomputed cheaply every 16 samples
      if ((i & 15) === 0) {
        let peak = 0;
        for (let j = 0; j < this.look; j++) if (this.peakWin[j] > peak) peak = this.peakWin[j];
        this.windowPeak = peak;
      } else if (Math.abs(y) > this.windowPeak) {
        this.windowPeak = Math.abs(y);
      }
      const need = this.windowPeak > this.ceiling ? this.ceiling / this.windowPeak : 1;
      const coef = need < this.limGain ? this.attack : this.release;
      this.limGain = coef * this.limGain + (1 - coef) * need;
      let out = delayed * Math.min(this.limGain, need);
      if (out > this.ceiling) out = this.ceiling; else if (out < -this.ceiling) out = -this.ceiling;

      for (let c = 0; c < output.length; c++) output[c][i] = out;

      // 4. Meter the output (BS.1770: 400 ms blocks, 75% overlap)
      if (this.metering) {
        const m = this.kOutHp.process(this.kOutShelf.process(out));
        this.blockAcc += m * m;
        if (++this.blockCount >= this.blockSize) {
          this.subBlocks.push(this.blockAcc / this.blockCount);
          this.blockAcc = 0; this.blockCount = 0;
          if (this.subBlocks.length > 4) this.subBlocks.shift();
          if (this.subBlocks.length === 4) this.blocks.push((this.subBlocks[0] + this.subBlocks[1] + this.subBlocks[2] + this.subBlocks[3]) / 4);
        }
      }
    }

    // AGC update once per render quantum
    const momentaryLUFS = this.momentary > 0 ? this.lufs(this.momentary) : -100;
    const noiseFloorLUFS = -60;
    if (momentaryLUFS > Math.max(-55, noiseFloorLUFS)) {
      // Short-term estimate of the speech loudness before gain (about 3 s memory)
      const a = Math.exp(-n / (3 * sampleRate));
      this.shortTermLUFS = this.shortTermLUFS == null ? momentaryLUFS : a * this.shortTermLUFS + (1 - a) * momentaryLUFS;
      const wanted = Math.max(-6, Math.min(36, this.target - this.shortTermLUFS + 1));
      const maxStep = 3 * n / sampleRate; // at most 3 dB per second
      this.gainDB += Math.max(-maxStep, Math.min(maxStep, wanted - this.gainDB));
    }

    if (++this.reportCountdown >= 375) { this.reportCountdown = 0; this.report(false); } // ~1 s
    return true;
  }
}

registerProcessor('voice-processor', VoiceProcessor);
