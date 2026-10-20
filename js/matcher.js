// Works out where in the script the speaker is from the recognizer's running transcript.
// Only moves forward, and only on a confident match, so a misheard word never jumps the text.
import { normalize } from './script.js?v=5';

const TAIL = 4;
const LOOK_BEHIND = 2;
const LOOK_AHEAD = 25;

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
    this.heardCount = 0;
    this.lastKey = '';
  }

  jump(index) {
    this.position = Math.max(0, Math.min(index, this.words.length));
  }

  /**
   * Feed the whole transcript so far. `limit` is the last word index allowed (the end of the
   * visible text), so the position can never land on a word that is not on screen.
   * Returns true when the position moved.
   */
  update(transcript, limit = Infinity) {
    const heard = transcript.split(/\s+/).map(normalize).filter(Boolean);
    if (heard.length < this.heardCount) this.heardCount = 0; // the recognizer restarted
    if (!heard.length || !this.words.length) return false;
    const tail = heard.slice(-TAIL);
    // The recognizer repeats and refines the same words many times. A word that already moved
    // the text cannot move it again: only newly heard words count.
    const key = tail.join(' ');
    if (heard.length <= this.heardCount && key === this.lastKey) return false;
    const last = tail[tail.length - 1];
    const lo = Math.max(0, this.position - LOOK_BEHIND);
    const hi = Math.min(this.words.length - 1, this.position + LOOK_AHEAD, limit);
    // Take the FIRST place that fits, not the best-scoring one further down: the speaker
    // reads in order, so the nearest copy of a repeated word is the one being said.
    // The further ahead a match is, the more surrounding words must agree with it.
    for (let end = lo; end <= hi; end++) {
      if (!similar(this.words[end], last)) continue;
      let score = 0;
      for (let k = 0; k < tail.length && end - k >= 0; k++) {
        if (similar(this.words[end - k], tail[tail.length - 1 - k])) score++;
        else break;
      }
      const ahead = end - this.position;
      const required = ahead <= 1 ? 1 : ahead <= 6 ? 2 : 3;
      if (score < required) continue;
      // The nearest fit is the word just read (heard again): stay put.
      if (end < this.position) return false;
      this.position = end + 1;
      this.heardCount = heard.length;
      this.lastKey = key;
      return true;
    }
    return false;
  }
}
