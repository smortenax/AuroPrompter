// Live speech recognition (Safari's webkitSpeechRecognition), restarted whenever iOS ends a session.
export class VoiceFollower {
  constructor({ onTranscript, onError }) {
    this.onTranscript = onTranscript;
    this.onError = onError;
    this.running = false;
    this.rec = null;
    this.failures = 0;
  }

  static get supported() {
    return Boolean(window.SpeechRecognition || window.webkitSpeechRecognition);
  }

  start(lang) {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) return false;
    this.SR = SR;
    this.lang = lang;
    this.running = true;
    this.failures = 0;
    this.#begin();
    return true;
  }

  stop() {
    this.running = false;
    try { this.rec?.abort(); } catch { /* already stopped */ }
    this.rec = null;
  }

  #begin() {
    if (!this.running) return;
    const rec = new this.SR();
    rec.lang = this.lang;
    rec.continuous = true;
    rec.interimResults = true;
    rec.maxAlternatives = 1;
    rec.onresult = (event) => {
      this.failures = 0;
      let text = '';
      for (let i = 0; i < event.results.length; i++) text += event.results[i][0].transcript + ' ';
      this.onTranscript(text);
    };
    rec.onerror = (event) => {
      if (event.error === 'not-allowed' || event.error === 'service-not-allowed' || event.error === 'language-not-supported') {
        this.running = false;
        this.onError?.(event.error);
      } else if (event.error !== 'no-speech' && event.error !== 'aborted') {
        this.failures++;
      }
    };
    rec.onend = () => {
      if (!this.running || this.rec !== rec) return;
      if (this.failures > 5) {
        this.running = false;
        this.onError?.('unstable');
        return;
      }
      setTimeout(() => this.#begin(), 120);
    };
    this.rec = rec;
    try {
      rec.start();
    } catch (error) {
      this.running = false;
      this.onError?.(String(error));
    }
  }
}
