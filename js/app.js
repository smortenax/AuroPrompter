// AutoPrompter: Pegar → Grabar → Guardar, on iPhone Safari.
import { parseScript, normalize } from './script.js?v=6';
import { ScriptMatcher } from './matcher.js?v=6';
import { VoiceFollower } from './speech.js?v=6';

// Camera, background and audio code load only when the record screen opens,
// so the script screen always works even if one of them can't run on this phone.
const loadCompositor = () => import('./compositor.js?v=6').then((m) => m.Compositor);
const loadAudio = () => import('./audio.js?v=6').then((m) => m.AudioChain);

// Show any unexpected error on screen, so a problem on the phone can be reported.
function showError(message) {
  const box = document.getElementById('error-banner');
  if (!box) return;
  box.textContent = 'Error: ' + message;
  box.hidden = false;
}
window.addEventListener('error', (e) => showError(e.message || String(e.error)));
window.addEventListener('unhandledrejection', (e) => showError(e.reason?.message || String(e.reason)));
const withTimeout = (promise, ms) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve('timeout'), ms))]);

const VERSION = '1.2.0';

const DEFAULTS = {
  fontSize: 30, margin: 18, textOpacity: 1, shade: 0.45, panelHeight: 0.42, readingLine: 0.18,
  scrollMode: 'voice', wpm: 140, lang: 'en-US', hanRate: 3,
  pinyinScope: 'edges', pinyinStyle: 'marks', pinyinDisplay: 'only',
  bgEnabled: true, bgMode: 'blur', bgColor: '#174a3c',
  noiseReduction: 12, voiceEQ: true, targetLUFS: -14, learnedGainDB: 12,
  quality: '1080',
};

// ---------- storage (per-device conveniences; everything still works without it) ----------
const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem('ap.' + key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem('ap.' + key, JSON.stringify(value)); } catch { /* storage full or blocked */ }
  },
};

let settings = { ...DEFAULTS, ...store.get('settings', {}) };
// Older versions had "original" as a background kind; it is now the on/off switch.
if (settings.bgMode === 'original') { settings.bgMode = 'blur'; settings.bgEnabled = false; }
let scriptText = store.get('script', '');
let overrides = store.get('overrides', {});
let bgImage = null;
let parsed = parseScript('', {});

const $ = (id) => document.getElementById(id);
const saveSettings = () => store.set('settings', settings);

function loadBackgroundImage() {
  const data = store.get('bgImage', null);
  if (!data) { bgImage = null; return; }
  const img = new Image();
  img.onload = () => { bgImage = img; };
  img.src = data;
  $('bg-thumb').src = data;
  $('bg-thumb').hidden = false;
}

// ---------- 1. Script screen ----------
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const CJK_PUNCT = { '，': ',', '、': ',', '。': '.', '！': '!', '？': '?', '：': ':', '；': ';' };

function prompterHTML(tokens) {
  const only = settings.pinyinDisplay === 'only';
  let html = '';
  let prev = null;
  for (const t of tokens) {
    if (t.kind === 'br') { html += '<br>'; prev = t; continue; }
    // In pinyin-only mode, Chinese punctuation becomes its Latin form and sticks to the syllable before it.
    const text = only && t.kind === 'word' ? t.text.replace(/[，、。！？：；]/g, (c) => CJK_PUNCT[c]) : t.text;
    const joinHan = prev && prev.kind === 'han' && t.kind === 'han' && !(only && t.pinyin);
    const gluePunct = only && prev?.kind === 'han' && t.kind === 'word' && /^[,.!?:;]/.test(text);
    if (prev && prev.kind !== 'br' && !joinHan && !gluePunct) html += ' ';
    if (t.kind === 'han' && t.pinyin && only) html += `<span class="t py" data-i="${t.i}">${esc(t.pinyin)}</span>`;
    else if (t.kind === 'han' && t.pinyin) html += `<ruby class="t" data-i="${t.i}">${esc(t.text)}<rt>${esc(t.pinyin)}</rt></ruby>`;
    else html += `<span class="t" data-i="${t.i}">${esc(text)}</span>`;
    prev = t;
  }
  return html;
}

function reparse() {
  // With pinyin only, every Chinese character is shown as pinyin, so all of them need it.
  const scope = settings.pinyinDisplay === 'only' ? 'all' : settings.pinyinScope;
  parsed = parseScript(scriptText, { scope, style: settings.pinyinStyle, overrides });
  // What the prompter steps through: every spoken word and every Chinese character, in order.
  // Chinese has an empty key, so the English recognizer never matches it; it is timed instead.
  parsed.track = parsed.tokens
    .filter((t) => t.kind === 'han' || (t.kind === 'word' && normalize(t.text)))
    .map((t) => ({ norm: t.kind === 'han' ? '' : normalize(t.text), token: t.i, han: t.kind === 'han' }));
  const words = parsed.spoken.length;
  const seconds = Math.round(words / settings.wpm * 60);
  $('script-meta').textContent = words
    ? `${words} palabras · unos ${seconds < 60 ? seconds + ' s' : Math.floor(seconds / 60) + ' min ' + (seconds % 60) + ' s'}`
    : '';
  $('preview').innerHTML = prompterHTML(parsed.tokens);
  $('preview').style.fontSize = Math.min(settings.fontSize, 24) + 'px';
  renderRuns();
  $('go-record').disabled = parsed.tokens.length === 0;
  $('forget-fixes').hidden = Object.keys(overrides).length === 0;
}

// ---------- Pronunciation playback (the iPhone's own Chinese voice) ----------
function chineseVoice() {
  const voices = window.speechSynthesis?.getVoices() || [];
  return voices.find((v) => /^zh[-_]CN/i.test(v.lang)) || voices.find((v) => /^zh/i.test(v.lang)) || null;
}
window.speechSynthesis?.getVoices(); // starts loading the voice list

function speakChinese(text, rate, button) {
  const synth = window.speechSynthesis;
  if (!synth) { alert('Este navegador no puede leer en voz alta.'); return; }
  const wasPlaying = button.classList.contains('playing');
  synth.cancel();
  document.querySelectorAll('.play.playing').forEach((b) => b.classList.remove('playing'));
  if (wasPlaying) return;
  const u = new SpeechSynthesisUtterance(text);
  u.lang = 'zh-CN';
  const voice = chineseVoice();
  if (voice) u.voice = voice;
  u.rate = rate;
  u.onend = u.onerror = () => button.classList.remove('playing');
  button.classList.add('playing');
  synth.speak(u);
}

function renderRuns() {
  const box = $('runs');
  box.innerHTML = '';
  $('runs-block').hidden = parsed.runs.length === 0;
  for (const run of parsed.runs) {
    const el = document.createElement('div');
    el.className = 'run';
    const fixed = run.syllables.join(' ') !== run.auto.join(' ');
    el.innerHTML = `
      <div class="run-top">
        <span class="run-han"></span>
        <div class="run-play">
          <button class="play" aria-label="Escuchar"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l10-6.5z"/></svg></button>
          <button class="play slow" aria-label="Escuchar despacio">Lento</button>
        </div>
      </div>
      ${fixed ? '<button class="reset">Volver al automático</button>' : ''}
      <input type="text" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false" enterkeyhint="done">
      <p class="warn" hidden></p>`;
    el.querySelector('.run-han').textContent = run.text;
    const input = el.querySelector('input');
    input.id = 'run-' + run.first;
    input.value = run.syllables.join(' ');
    const warn = el.querySelector('.warn');
    const count = [...run.text].length;
    const commit = () => {
      const parts = input.value.trim().split(/\s+/).filter(Boolean);
      if (parts.length !== count) {
        warn.textContent = `Escribe ${count} sílabas separadas por espacios.`;
        warn.hidden = false;
        return;
      }
      warn.hidden = true;
      const value = parts.join(' ');
      if (value === run.auto.join(' ')) delete overrides[run.text]; else overrides[run.text] = value;
      store.set('overrides', overrides);
      reparse();
    };
    input.addEventListener('change', commit);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); input.blur(); } });
    for (const btn of el.querySelectorAll('.play')) {
      btn.addEventListener('click', () => speakChinese(run.text, btn.classList.contains('slow') ? 0.5 : 0.85, btn));
    }
    el.querySelector('.reset')?.addEventListener('click', () => {
      delete overrides[run.text];
      store.set('overrides', overrides);
      reparse();
    });
    box.appendChild(el);
  }
}

$('script').value = scriptText;
let parseTimer;
$('script').addEventListener('input', () => {
  scriptText = $('script').value;
  store.set('script', scriptText);
  clearTimeout(parseTimer);
  parseTimer = setTimeout(reparse, 250);
});
$('paste').addEventListener('click', async () => {
  try {
    const text = await navigator.clipboard.readText();
    if (text) { scriptText = text; $('script').value = text; store.set('script', text); reparse(); }
  } catch {
    $('script').focus();
    $('script').select();
  }
});
$('clear').addEventListener('click', () => {
  scriptText = ''; $('script').value = ''; store.set('script', ''); reparse();
});

// ---------- Settings sheet ----------
function bindRange(id, key, outId, fmt) {
  const input = $(id);
  input.value = settings[key];
  const show = () => { if (outId) $(outId).textContent = fmt(settings[key]); };
  show();
  input.addEventListener('input', () => {
    settings[key] = Number(input.value);
    saveSettings();
    show();
    applyPrompterLook();
    if (key === 'fontSize' || key === 'wpm') reparse();
  });
}

function syncSegments() {
  document.querySelectorAll('.seg').forEach((seg) => {
    const key = seg.dataset.key;
    seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', String(settings[key]) === b.dataset.value));
  });
  $('row-scope').hidden = settings.pinyinDisplay === 'only';
  $('row-color').hidden = settings.bgMode !== 'color';
  $('row-image').hidden = settings.bgMode !== 'image';
}

document.querySelectorAll('.seg').forEach((seg) => {
  seg.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const key = seg.dataset.key;
    settings[key] = seg.hasAttribute('data-number') ? Number(b.dataset.value) : b.dataset.value;
    saveSettings();
    syncSegments();
    if (key.startsWith('pinyin')) reparse();
  });
});

bindRange('s-wpm', 'wpm', 'o-wpm', (v) => `${v} pal/min`);
bindRange('s-han', 'hanRate', 'o-han', (v) => `${v} sílabas/s`);
bindRange('s-size', 'fontSize', 'o-size', (v) => `${v} pt`);
bindRange('s-line', 'readingLine', 'o-line', (v) => `${Math.round(v * 100)} %`);
bindRange('s-nr', 'noiseReduction', 'o-nr', (v) => (v ? `${v} dB` : 'apagada'));
$('s-lang').value = settings.lang;
$('s-lang').addEventListener('change', () => { settings.lang = $('s-lang').value; saveSettings(); });
$('s-color').value = settings.bgColor;
$('s-color').addEventListener('input', () => { settings.bgColor = $('s-color').value; saveSettings(); });
$('s-bg-on').checked = settings.bgEnabled;
$('s-bg-on').addEventListener('change', () => { settings.bgEnabled = $('s-bg-on').checked; saveSettings(); applyBackground(); });
$('s-eq').checked = settings.voiceEQ;
$('s-eq').addEventListener('change', () => { settings.voiceEQ = $('s-eq').checked; saveSettings(); });
$('s-image').addEventListener('change', async () => {
  const file = $('s-image').files?.[0];
  if (!file) return;
  const url = URL.createObjectURL(file);
  const img = new Image();
  img.onload = () => {
    // Store a 1080×1920 cover crop, small enough for local storage.
    const c = document.createElement('canvas');
    c.width = 1080; c.height = 1920;
    const s = Math.max(c.width / img.width, c.height / img.height);
    const w = c.width / s, h = c.height / s;
    c.getContext('2d').drawImage(img, (img.width - w) / 2, (img.height - h) / 2, w, h, 0, 0, c.width, c.height);
    store.set('bgImage', c.toDataURL('image/jpeg', 0.82));
    URL.revokeObjectURL(url);
    loadBackgroundImage();
  };
  img.src = url;
});
$('forget-fixes').addEventListener('click', () => { overrides = {}; store.set('overrides', overrides); reparse(); });
$('reset-settings').addEventListener('click', () => {
  settings = { ...DEFAULTS, learnedGainDB: settings.learnedGainDB };
  saveSettings();
  location.reload();
});
$('open-settings').addEventListener('click', () => { syncSegments(); $('settings').hidden = false; });
$('close-settings').addEventListener('click', () => { $('settings').hidden = true; });
$('settings').addEventListener('click', (e) => { if (e.target === $('settings')) $('settings').hidden = true; });
$('version').textContent = 'AutoPrompter ' + VERSION;

// ---------- 2. Record screen ----------
const rec = {
  stream: null, compositor: null, audio: null, follower: null, matcher: null,
  recorder: null, chunks: [], mime: '', wakeLock: null, timer: null, raf: null, pos: 0, lines: null, visibleEnd: null,
  state: 'idle', // idle | countdown | recording | stopping
  current: 0, startedAt: 0,
};

function applyPrompterLook() {
  const p = $('prompter');
  const text = $('prompter-text');
  text.style.fontSize = settings.fontSize + 'px';
  text.style.opacity = settings.textOpacity;
  text.style.paddingLeft = text.style.paddingRight = settings.margin + 'px';
  p.style.setProperty('--shade', settings.shade);
  p.style.height = `calc(${Math.round(settings.panelHeight * 100)}dvh - 8px)`;
  const h = p.clientHeight || window.innerHeight * settings.panelHeight;
  text.style.paddingTop = Math.round(h * settings.readingLine) + 'px';
  text.style.paddingBottom = Math.round(h) + 'px';
  document.querySelector('.reading-line').style.top = Math.round(h * settings.readingLine) + 'px';
  for (const [id, key] of [['tc-size', 'fontSize'], ['tc-margin', 'margin'], ['tc-opacity', 'textOpacity'], ['tc-shade', 'shade'], ['tc-height', 'panelHeight'], ['tc-speed', 'wpm']]) {
    if (document.activeElement !== $(id)) $(id).value = settings[key];
  }
}

for (const [id, key] of [['tc-size', 'fontSize'], ['tc-margin', 'margin'], ['tc-opacity', 'textOpacity'], ['tc-shade', 'shade'], ['tc-height', 'panelHeight'], ['tc-speed', 'wpm']]) {
  $(id).addEventListener('input', () => {
    settings[key] = Number($(id).value);
    saveSettings();
    applyPrompterLook();
    scrollToCurrent();
  });
}

// Drag the bar at the bottom of the text panel to make it taller or shorter.
$('prompter-grip').addEventListener('pointerdown', (e) => {
  e.preventDefault();
  const grip = $('prompter-grip');
  grip.setPointerCapture(e.pointerId);
  const top = $('prompter').getBoundingClientRect().top;
  const move = (ev) => {
    settings.panelHeight = Math.min(0.92, Math.max(0.2, (ev.clientY - top + 12) / window.innerHeight));
    applyPrompterLook();
    scrollToCurrent();
  };
  const up = () => {
    grip.removeEventListener('pointermove', move);
    saveSettings();
  };
  grip.addEventListener('pointermove', move);
  grip.addEventListener('pointerup', up, { once: true });
  grip.addEventListener('pointercancel', up, { once: true });
});

function setNotice(text) {
  $('notice').textContent = text || '';
  $('notice').hidden = !text;
}

/** Highlights the word at the reading point. */
function setCurrent(tokenIndex) {
  if (rec.current === tokenIndex) return;
  rec.current = tokenIndex;
  const nodes = $('prompter-text').querySelectorAll('.t');
  for (const n of nodes) {
    const i = Number(n.dataset.i);
    n.classList.toggle('done', i < tokenIndex);
    n.classList.toggle('now', i === tokenIndex);
  }
}

/** Where each line of the prompter starts: its top and the first tracked word on it. */
function measureLines() {
  const box = $('prompter-text');
  const lines = [];
  parsed.track.forEach((w, k) => {
    const el = box.querySelector(`.t[data-i="${w.token}"]`);
    if (!el) return;
    const top = el.offsetTop;
    if (!lines.length || top > lines[lines.length - 1].top + 2) lines.push({ top, first: k });
  });
  const lastEl = box.querySelector('.t:last-of-type');
  const end = lines.length ? lines[lines.length - 1].top + (lastEl?.offsetHeight || 40) : 0;
  lines.push({ top: end, first: parsed.track.length });
  rec.lines = lines;
  return lines;
}

/**
 * Scrolls so the reading point `pos` (in words, fractional) sits on the reading line.
 * The text glides through each line in proportion to the words read, so it never jumps.
 */
function renderPosition(pos) {
  const box = $('prompter-text');
  const lines = rec.lines || measureLines();
  if (lines.length < 2) return;
  let i = 0;
  while (i < lines.length - 2 && lines[i + 1].first <= pos) i++;
  const a = lines[i];
  const b = lines[i + 1];
  const frac = b.first > a.first ? Math.min(1, Math.max(0, (pos - a.first) / (b.first - a.first))) : 0;
  const y = a.top + frac * (b.top - a.top);
  box.scrollTop = Math.max(0, y - parseFloat(box.style.paddingTop || 0));
  // The voice may only land on words that are visible in the panel.
  const bottom = box.scrollTop + box.clientHeight;
  let v = i;
  while (v < lines.length - 1 && lines[v + 1].top + 4 < bottom) v++;
  rec.visibleEnd = lines[Math.min(v + 1, lines.length - 1)].first - 1;
  setCurrent(tokenForWord(Math.floor(pos)));
}

function scrollToCurrent() {
  rec.lines = null;
  renderPosition(rec.pos || 0);
}

function wordIndexForToken(tokenIndex) {
  const idx = parsed.track.findIndex((w) => w.token >= tokenIndex);
  return idx === -1 ? parsed.track.length : idx;
}

function tokenForWord(wordIndex) {
  return wordIndex < parsed.track.length ? parsed.track[wordIndex].token : parsed.tokens.length;
}

$('prompter-text').addEventListener('click', (e) => {
  const t = e.target.closest('.t');
  if (!t || !rec.matcher) return;
  const k = wordIndexForToken(Number(t.dataset.i));
  rec.matcher.jump(k);
  rec.pos = k;
  renderPosition(k);
});

async function openRecorder() {
  reparse();
  $('screen-script').hidden = true;
  $('screen-record').hidden = false;
  $('prompter-text').innerHTML = prompterHTML(parsed.tokens);
  applyPrompterLook();
  rec.matcher = new ScriptMatcher(parsed.track.map((w) => w.norm));
  rec.pos = 0;
  rec.current = -1;
  scrollToCurrent();
  $('shutter').disabled = true;
  setNotice('Preparando la cámara…');

  try {
    rec.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'user', width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } },
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 },
    });
  } catch (error) {
    setNotice('No puedo usar la cámara o el micrófono. En Ajustes del iPhone → Safari → Cámara y Micrófono, elige «Permitir», y vuelve a abrir esta pantalla.');
    return;
  }

  const video = $('camera');
  video.srcObject = rec.stream;
  try { await video.play(); } catch { /* starts on the next tap */ }

  const size = settings.quality === '720' ? [720, 1280] : [1080, 1920];
  let Compositor;
  try {
    Compositor = await loadCompositor();
  } catch (error) {
    showError('no se pudo cargar el módulo de vídeo (' + (error?.message || error) + ')');
    return;
  }
  rec.compositor = new Compositor($('stage'), video);
  rec.compositor.setSize(...size);
  rec.compositor.start();
  rec.segmenterLoading = null;

  // Audio clean-up: wait a few seconds at most, otherwise record the plain microphone.
  setNotice('Preparando el audio…');
  try {
    const AudioChain = await loadAudio();
    const audio = new AudioChain();
    const outcome = await withTimeout(audio.init(rec.stream, settings), 5000);
    if (outcome === 'timeout') throw new Error('timeout');
    rec.audio = audio;
    setNotice('');
  } catch (error) {
    console.warn('Audio chain failed', error);
    rec.audio = null;
    setNotice('La limpieza de audio no está disponible: se grabará el sonido tal cual.');
  }
  $('shutter').disabled = false;

  applyBackground();

  try { rec.wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* optional */ }
}

/** Turns background replacement on or off for the live picture and the recording. */
function applyBackground() {
  const on = settings.bgEnabled;
  $('toggle-bg').classList.toggle('on', on);
  $('toggle-bg').setAttribute('aria-pressed', String(on));
  $('toggle-bg-label').textContent = on ? 'Fondo' : 'Sin fondo';
  if (!rec.compositor) return;
  rec.compositor.setBackground(on ? settings.bgMode : 'original', settings.bgColor, bgImage);
  if (!on || rec.compositor.segmenter || rec.segmenterLoading) return;
  // The background model is large; it loads while you can already record, and applies as soon as it is ready.
  const compositor = rec.compositor;
  if (!$('notice').textContent) setNotice('Cargando el fondo… Puedes grabar ya; se aplica en cuanto esté listo.');
  rec.segmenterLoading = compositor.init().then((ok) => {
    if (rec.compositor !== compositor) return;
    if (!ok) setNotice('El cambio de fondo no está disponible en este iPhone. Se grabará el fondo real.');
    else if ($('notice').textContent.startsWith('Cargando el fondo')) setNotice('');
  }).catch((error) => setNotice('El cambio de fondo ha fallado: ' + (error?.message || error)));
}

$('toggle-bg').addEventListener('click', () => {
  settings.bgEnabled = !settings.bgEnabled;
  saveSettings();
  $('s-bg-on').checked = settings.bgEnabled;
  if (!settings.bgEnabled && $('notice').textContent.startsWith('Cargando el fondo')) setNotice('');
  applyBackground();
});

function closeRecorder() {
  stopFollowing();
  rec.compositor?.stop();
  rec.stream?.getTracks().forEach((t) => t.stop());
  rec.audio?.close();
  try { rec.wakeLock?.release(); } catch { /* already released */ }
  Object.assign(rec, { stream: null, compositor: null, audio: null, recorder: null, state: 'idle', wakeLock: null });
  $('screen-record').classList.remove('recording');
  $('shutter').classList.remove('on');
  $('countdown').hidden = true;
  $('timer').hidden = true;
  $('text-controls').hidden = true;
  setNotice('');
  $('screen-record').hidden = true;
  $('screen-script').hidden = false;
}

function pickMime() {
  const types = ['video/mp4;codecs=avc1.640028,mp4a.40.2', 'video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm'];
  return types.find((t) => window.MediaRecorder?.isTypeSupported?.(t)) || '';
}

function startFollowing() {
  rec.voice = settings.scrollMode === 'voice' && VoiceFollower.supported;
  if (!rec.voice) return;
  rec.follower = new VoiceFollower({
    onTranscript: (text) => {
      if (rec.state !== 'recording') return;
      rec.matcher.update(text, rec.visibleEnd ?? Infinity);
    },
    onError: () => {
      rec.voice = false;
      setNotice('El seguimiento por voz se ha detenido. Sigo a velocidad fija; toca una palabra para saltar a ella.');
    },
  });
  rec.follower.start(settings.lang);
}

/**
 * The text always moves forward at the chosen speed. The voice only steers that speed:
 * faster when you are ahead of the text, slower when you are behind, so it never jumps.
 */
function startScrolling() {
  let last = performance.now();
  rec.rate = 1;
  const frame = (now) => {
    if (rec.state !== 'recording') return;
    const dt = Math.max(0, Math.min(0.1, (now - last) / 1000));
    last = now;
    const track = parsed.track;
    let target = 1;
    if (rec.voice) {
      // Chinese can't be heard by the recognizer: the voice reference follows the text through it.
      while (track[rec.matcher.position]?.han && rec.matcher.position < Math.floor(rec.pos)) rec.matcher.position++;
      // The recognizer reports a word just after it is said, so the speaker is about half a word further on.
      const gap = rec.matcher.position + 0.5 - rec.pos;
      target = Math.min(3.5, Math.max(0.15, 1 + 0.3 * gap));
    }
    rec.rate += (target - rec.rate) * Math.min(1, dt * 2.5);
    const item = track[Math.floor(rec.pos)];
    if (item) {
      const seconds = item.han ? 1 / settings.hanRate : 60 / settings.wpm;
      rec.pos = Math.min(track.length, rec.pos + (dt / seconds) * rec.rate);
    }
    renderPosition(rec.pos);
    rec.raf = requestAnimationFrame(frame);
  };
  rec.raf = requestAnimationFrame(frame);
}

function stopFollowing() {
  cancelAnimationFrame(rec.raf);
  rec.raf = null;
  rec.follower?.stop();
  rec.follower = null;
}

async function startRecording() {
  if (!rec.stream) return;
  $('text-controls').hidden = true;
  rec.state = 'countdown';
  // Speech recognition and audio have to start from the tap itself on iOS, before any waiting.
  startFollowing();
  const resumed = rec.audio ? withTimeout(rec.audio.resume(), 1500) : null;
  $('countdown-num').textContent = 3;
  $('countdown').hidden = false;
  if ((await resumed) === 'timeout') console.warn('Audio did not resume');
  rec.audio?.learnNoise(true);

  $('countdown').hidden = false;
  for (const n of [3, 2, 1]) {
    $('countdown-num').textContent = n;
    await new Promise((r) => setTimeout(r, 1000));
    if (rec.state !== 'countdown') return;
  }
  $('countdown').hidden = true;
  rec.audio?.learnNoise(false);

  const canvasStream = $('stage').captureStream(30);
  const tracks = [...canvasStream.getVideoTracks()];
  const audioTrack = rec.audio?.track || rec.stream.getAudioTracks()[0];
  if (audioTrack) tracks.push(audioTrack);
  rec.mime = pickMime();
  rec.chunks = [];
  try {
    rec.recorder = new MediaRecorder(new MediaStream(tracks), {
      mimeType: rec.mime || undefined,
      videoBitsPerSecond: settings.quality === '720' ? 6_000_000 : 10_000_000,
      audioBitsPerSecond: 160_000,
    });
  } catch (error) {
    setNotice('Este navegador no puede grabar vídeo. Abre la página en Safari.');
    rec.state = 'idle';
    stopFollowing();
    return;
  }
  rec.recorder.ondataavailable = (e) => { if (e.data.size) rec.chunks.push(e.data); };
  rec.recorder.start(1000);
  rec.audio?.startMeter();
  rec.state = 'recording';
  startScrolling();
  rec.startedAt = Date.now();
  $('screen-record').classList.add('recording');
  $('shutter').classList.add('on');
  $('timer').hidden = false;
  rec.timer = setInterval(() => {
    const s = Math.floor((Date.now() - rec.startedAt) / 1000);
    $('timer').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }, 250);
}

async function stopRecording() {
  if (rec.state === 'countdown') {
    rec.state = 'idle';
    $('countdown').hidden = true;
    rec.audio?.learnNoise(false);
    stopFollowing();
    return;
  }
  if (rec.state !== 'recording') return;
  rec.state = 'stopping';
  stopFollowing();
  clearInterval(rec.timer);
  const level = rec.audio ? await rec.audio.stopMeter() : null;
  if (level?.gainDB != null) { settings.learnedGainDB = Math.round(level.gainDB * 10) / 10; saveSettings(); }
  const done = new Promise((resolve) => { rec.recorder.onstop = resolve; });
  rec.recorder.stop();
  await done;
  const type = rec.mime.split(';')[0] || rec.chunks[0]?.type || 'video/mp4';
  const blob = new Blob(rec.chunks, { type });
  const ext = type.includes('webm') ? 'webm' : 'mp4';
  showResult(blob, ext, level?.lufs);
  closeRecorder();
  $('screen-script').hidden = true;
}

$('go-record').addEventListener('click', openRecorder);
$('close-record').addEventListener('click', closeRecorder);
$('toggle-text').addEventListener('click', () => { $('text-controls').hidden = !$('text-controls').hidden; applyPrompterLook(); });
$('shutter').addEventListener('click', () => {
  if (rec.state === 'idle') startRecording(); else stopRecording();
});
window.addEventListener('resize', () => { if (!$('screen-record').hidden) { applyPrompterLook(); scrollToCurrent(); } });

// ---------- 3. Result ----------
let result = null;

function showResult(blob, ext, lufs) {
  if (result?.url) URL.revokeObjectURL(result.url);
  const stamp = new Date().toISOString().slice(0, 16).replace(/[T:]/g, '-');
  result = { blob, url: URL.createObjectURL(blob), name: `AutoPrompter-${stamp}.${ext}` };
  $('result-video').src = result.url;
  const mb = (blob.size / 1048576).toFixed(1);
  $('result-meta').textContent = (lufs != null ? `Audio a ${lufs.toFixed(1)} LUFS · ` : '') + `${mb} MB · ${ext.toUpperCase()}`;
  $('save').disabled = false;
  $('save').textContent = 'Guardar en Fotos';
  $('screen-result').hidden = false;
}

$('save').addEventListener('click', async () => {
  if (!result) return;
  const file = new File([result.blob], result.name, { type: result.blob.type });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
      $('save').textContent = 'Listo';
    } catch (error) {
      if (error?.name !== 'AbortError') $('save-hint').textContent = 'No se pudo abrir el menú de compartir. Mantén pulsado el vídeo y elige «Guardar».';
    }
    return;
  }
  // Fallback for browsers without file sharing: a regular download.
  const a = document.createElement('a');
  a.href = result.url;
  a.download = result.name;
  document.body.appendChild(a);
  a.click();
  a.remove();
});
$('again').addEventListener('click', () => { $('screen-result').hidden = true; $('result-video').pause(); openRecorder(); });
$('done').addEventListener('click', () => { $('screen-result').hidden = true; $('result-video').pause(); $('screen-script').hidden = false; });

// ---------- start ----------
loadBackgroundImage();
syncSegments();
reparse();
