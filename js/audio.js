// Microphone → voice EQ → noise reduction / auto level / limiter (worklet) → stream for recording.
export class AudioChain {
  async init(stream, settings) {
    const AC = window.AudioContext || window.webkitAudioContext;
    this.ctx = new AC({ latencyHint: 'interactive' });
    await this.ctx.audioWorklet.addModule(new URL('./voice-worklet.js', import.meta.url));
    const fs = this.ctx.sampleRate;
    this.source = this.ctx.createMediaStreamSource(stream);

    const nodes = [];
    const hp = this.ctx.createBiquadFilter();
    hp.type = 'highpass'; hp.frequency.value = 80; hp.Q.value = 0.707;
    nodes.push(hp);
    if (settings.voiceEQ) {
      const mud = this.ctx.createBiquadFilter();
      mud.type = 'peaking'; mud.frequency.value = 250; mud.Q.value = 1; mud.gain.value = -3;
      const presence = this.ctx.createBiquadFilter();
      presence.type = 'peaking'; presence.frequency.value = 3500; presence.Q.value = 0.9; presence.gain.value = 3;
      const air = this.ctx.createBiquadFilter();
      air.type = 'highshelf'; air.frequency.value = Math.min(10000, fs / 2 - 1000); air.gain.value = 1.5;
      nodes.push(mud, presence, air);
    }
    this.worklet = new AudioWorkletNode(this.ctx, 'voice-processor', {
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
      channelCount: 1,
      channelCountMode: 'explicit',
      processorOptions: {
        reductionDB: settings.noiseReduction,
        targetLUFS: settings.targetLUFS,
        startGainDB: settings.learnedGainDB ?? 12,
      },
    });
    this.destination = this.ctx.createMediaStreamDestination();
    let previous = this.source;
    for (const node of [...nodes, this.worklet]) { previous.connect(node); previous = node; }
    previous.connect(this.destination);

    this.level = { gainDB: settings.learnedGainDB ?? 12, lufs: null };
    this.worklet.port.onmessage = (e) => {
      if (e.data.type === 'level') {
        this.level = e.data;
        if (e.data.final && this.finalResolve) { this.finalResolve(e.data); this.finalResolve = null; }
      }
    };
  }

  get track() { return this.destination.stream.getAudioTracks()[0]; }

  resume() { return this.ctx.state === 'running' ? Promise.resolve() : this.ctx.resume(); }

  learnNoise(on) { this.worklet.port.postMessage({ type: 'learn', on }); }

  startMeter() { this.worklet.port.postMessage({ type: 'meter', on: true }); }

  /** Stops metering and resolves with the integrated loudness of what was recorded. */
  stopMeter() {
    return new Promise((resolve) => {
      this.finalResolve = resolve;
      this.worklet.port.postMessage({ type: 'meter', on: false });
      setTimeout(() => { if (this.finalResolve) { this.finalResolve(this.level); this.finalResolve = null; } }, 1000);
    });
  }

  close() { try { this.ctx.close(); } catch { /* already closed */ } }
}
