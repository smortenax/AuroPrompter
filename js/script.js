// Turns the pasted script into tokens: words, Chinese characters (with pinyin) and line breaks.
import { pinyin } from '../vendor/pinyin-pro.mjs';

const HAN = /\p{Script=Han}/u;
export const isHan = (ch) => HAN.test(ch);

/** Lowercased letters and digits only, so "Don't," matches the recognizer's "don't". */
export function normalize(word) {
  return word
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, '');
}

const MARKED = {
  ā: ['a', 1], á: ['a', 2], ǎ: ['a', 3], à: ['a', 4],
  ē: ['e', 1], é: ['e', 2], ě: ['e', 3], è: ['e', 4],
  ī: ['i', 1], í: ['i', 2], ǐ: ['i', 3], ì: ['i', 4],
  ō: ['o', 1], ó: ['o', 2], ǒ: ['o', 3], ò: ['o', 4],
  ū: ['u', 1], ú: ['u', 2], ǔ: ['u', 3], ù: ['u', 4],
  ǖ: ['ü', 1], ǘ: ['ü', 2], ǚ: ['ü', 3], ǜ: ['ü', 4],
  ń: ['n', 2], ň: ['n', 3], ǹ: ['n', 4], ḿ: ['m', 2],
};

/** "hǎo" → "hao3"; neutral tone gets no number. */
export function toNumbered(syllable) {
  let base = '';
  let tone = '';
  for (const ch of syllable.normalize('NFC')) {
    const m = MARKED[ch];
    if (m) { base += m[0]; tone = String(m[1]); } else base += ch;
  }
  return base + tone;
}

export function displaySyllable(syllable, style) {
  return style === 'num' ? toNumbered(syllable) : syllable;
}

/** One syllable per character, with the 一 / 不 tone changes applied. */
export function autoSyllables(run) {
  const chars = [...run];
  let result = pinyin(run, { type: 'array', toneType: 'symbol' });
  if (result.length !== chars.length) {
    result = chars.map((c) => pinyin(c, { toneType: 'symbol' }));
  }
  return result;
}

/**
 * @returns {{tokens: Array<{i:number,kind:'word'|'han'|'br',text:string,pinyin?:string}>,
 *            runs: Array<{first:number,text:string,syllables:string[],auto:string[]}>,
 *            spoken: Array<{norm:string,token:number}>}}
 */
export function parseScript(text, { scope = 'edges', style = 'marks', overrides = {} } = {}) {
  const tokens = [];
  const add = (kind, t) => tokens.push({ i: tokens.length, kind, text: t });

  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  lines.forEach((line, n) => {
    let word = '';
    for (const ch of line) {
      if (isHan(ch)) {
        if (word) { add('word', word); word = ''; }
        add('han', ch);
      } else if (/\s/.test(ch)) {
        if (word) { add('word', word); word = ''; }
      } else {
        word += ch;
      }
    }
    if (word) add('word', word);
    if (n < lines.length - 1) add('br', '\n');
  });

  const spoken = [];
  for (const t of tokens) {
    if (t.kind !== 'word') continue;
    const norm = normalize(t.text);
    if (norm) spoken.push({ norm, token: t.i });
  }

  // Pinyin only before the first / after the last spoken word, unless asked for everywhere.
  const first = spoken.length ? spoken[0].token : Infinity;
  const last = spoken.length ? spoken[spoken.length - 1].token : -Infinity;
  const wants = (i) => scope === 'all' || !spoken.length || i < first || i > last;

  const runs = [];
  for (let i = 0; i < tokens.length; ) {
    if (tokens[i].kind !== 'han' || !wants(i)) { i++; continue; }
    let end = i;
    while (end + 1 < tokens.length && tokens[end + 1].kind === 'han' && wants(end + 1)) end++;
    const runText = tokens.slice(i, end + 1).map((t) => t.text).join('');
    const auto = autoSyllables(runText);
    let syllables = auto;
    const fix = overrides[runText];
    if (fix) {
      const parts = fix.trim().split(/\s+/);
      if (parts.length === auto.length) syllables = parts;
    }
    syllables.forEach((s, k) => { tokens[i + k].pinyin = displaySyllable(s, style); });
    runs.push({ first: i, text: runText, syllables, auto });
    i = end + 1;
  }
  return { tokens, runs, spoken };
}
