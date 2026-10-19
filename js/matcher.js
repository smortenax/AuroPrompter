// Works out where in the script the speaker is from the recognizer's running transcript.
// Only moves forward, and only on a confident match, so a misheard word never jumps the text.
import { normalize } from './script.js?v=2';

const TAIL = 4;
const LOOK_BEHIND = 2;
const LOOK_AHEAD = 45;

function editDistance(a, b) {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = a[i - 1] === b[j - 1] ? prev[j - 1] : 1 + Math.min(prev[j - 1], prev[j], cur[j - 1]);
    }
    prev = cur;
  }
  return prev[b.length];
}

function similar(a, b) {
  if (a === b) return true;
  if (a.length < 4 || b.length < 4) return false;
  // Tolerate small recognition differences: "color"/"colour", "organise"/"organize".
  return a.startsWith(b.slice(0, 4)) && editDistance(a, b) <= Math.max(1, Math.floor(Math.min(a.length, b.length) / 4));
}

export class ScriptMatcher {
  constructor(words) {
    this.words = words;
    /** Index of the next word the speaker is expected to say. */
    this.position = 0;
  }

  jump(index) {
    this.position = Math.max(0, Math.min(index, this.words.length));
  }

  /** Feed the whole transcript so far. Returns true when the position moved. */
  update(transcript) {
    const heard = transcript.split(/\s+/).map(normalize).filter(Boolean);
    if (!heard.length || !this.words.length) return false;
    const tail = heard.slice(-TAIL);
    const lo = Math.max(0, this.position - LOOK_BEHIND);
    const hi = Math.min(this.words.length - 1, this.position + LOOK_AHEAD);
    let best = null;
    for (let end = lo; end <= hi; end++) {
      if (!similar(this.words[end], tail[tail.length - 1])) continue;
      let score = 0;
      for (let k = 0; k < tail.length && end - k >= 0; k++) {
        if (similar(this.words[end - k], tail[tail.length - 1 - k])) score++;
      }
      if (!best || score > best.score ||
          (score === best.score && Math.abs(end - this.position) < Math.abs(best.end - this.position))) {
        best = { end, score };
      }
    }
    if (!best) return false;
    const required = tail.length >= 2 ? 2 : 1;
    // A single matching word is only trusted right next to the current position.
    if (best.score < required && best.end - this.position > 2) return false;
    if (best.end + 1 <= this.position) return false;
    this.position = best.end + 1;
    return true;
  }
}
