// Draws every camera frame into a 9:16 canvas, replacing the background behind the person.

export class Compositor {
  constructor(canvas, video) {
    this.canvas = canvas;
    this.video = video;
    this.ctx = canvas.getContext('2d', { alpha: false });
    this.person = document.createElement('canvas');
    this.pctx = this.person.getContext('2d');
    this.mask = document.createElement('canvas');
    this.mctx = this.mask.getContext('2d');
    this.tiny = document.createElement('canvas');
    this.small = document.createElement('canvas');
    this.segmenter = null;
    this.running = false;
    this.mode = 'blur';
    this.color = '#174a3c';
    this.image = null;
    this.smoothed = null;
    this.lastVideoTime = -1;
    this.frameTimes = [];
  }

  setSize(width, height) {
    this.canvas.width = this.person.width = width;
    this.canvas.height = this.person.height = height;
    this.tiny.width = Math.round(width / 40); this.tiny.height = Math.round(height / 40);
    this.small.width = Math.round(width / 10); this.small.height = Math.round(height / 10);
  }

  setBackground(mode, color, image) {
    this.mode = mode;
    this.color = color;
    this.image = image;
  }

  /** Loads the on-device person segmentation model. Falls back to the CPU, then to no segmentation. */
  async init() {
    const base = new URL('../vendor/', import.meta.url).href;
    const { FilesetResolver, ImageSegmenter } = await import('../vendor/mediapipe/vision_bundle.mjs');
    const fileset = await FilesetResolver.forVisionTasks(base + 'mediapipe/wasm');
    for (const delegate of ['GPU', 'CPU']) {
      try {
        this.segmenter = await ImageSegmenter.createFromOptions(fileset, {
          baseOptions: { modelAssetPath: base + 'models/selfie_segmenter.tflite', delegate },
          runningMode: 'VIDEO',
          outputCategoryMask: false,
          outputConfidenceMasks: true,
        });
        this.delegate = delegate;
        return true;
      } catch (error) {
        console.warn('Segmenter failed on', delegate, error);
      }
    }
    return false;
  }

  start() {
    if (this.running) return;
    this.running = true;
    const v = this.video;
    if (v.requestVideoFrameCallback) {
      // Draw once per camera frame.
      const onFrame = () => {
        if (!this.running) return;
        this.draw();
        v.requestVideoFrameCallback(onFrame);
      };
      v.requestVideoFrameCallback(onFrame);
    } else {
      const loop = () => {
        if (!this.running) return;
        this.draw();
        requestAnimationFrame(loop);
      };
      requestAnimationFrame(loop);
    }
  }

  stop() {
    this.running = false;
  }

  /** Frames per second actually drawn over the last two seconds. */
  get fps() {
    const now = performance.now();
    this.frameTimes = this.frameTimes.filter((t) => now - t < 2000);
    return this.frameTimes.length / 2;
  }

  draw() {
    const v = this.video;
    if (v.readyState < 2 || !v.videoWidth) return;
    this.frameTimes.push(performance.now());

    const W = this.canvas.width, H = this.canvas.height;
    const vw = v.videoWidth, vh = v.videoHeight;
    // Centre crop of the camera frame with the canvas's aspect ratio.
    const scale = Math.max(W / vw, H / vh);
    const sw = W / scale, sh = H / scale;
    const sx = (vw - sw) / 2, sy = (vh - sh) / 2;
    const ctx = this.ctx;

    const maskReady = this.mode !== 'original' && this.segmenter && this.#updateMask(v);
    if (!maskReady) {
      ctx.drawImage(v, sx, sy, sw, sh, 0, 0, W, H);
      return;
    }

    // Background
    if (this.mode === 'color') {
      ctx.fillStyle = this.color;
      ctx.fillRect(0, 0, W, H);
    } else if (this.mode === 'image' && this.image) {
      const im = this.image;
      const s = Math.max(W / im.width, H / im.height);
      const iw = W / s, ih = H / s;
      ctx.drawImage(im, (im.width - iw) / 2, (im.height - ih) / 2, iw, ih, 0, 0, W, H);
    } else {
      // Blur by shrinking hard and scaling back up in two smooth steps (works on every Safari).
      const t = this.tiny.getContext('2d'), s = this.small.getContext('2d');
      t.imageSmoothingQuality = 'high';
      t.drawImage(v, sx, sy, sw, sh, 0, 0, this.tiny.width, this.tiny.height);
      s.imageSmoothingQuality = 'high';
      s.drawImage(this.tiny, 0, 0, this.small.width, this.small.height);
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(this.small, 0, 0, W, H);
    }

    // Person, cut out with the (soft, upscaled) mask
    const p = this.pctx;
    p.globalCompositeOperation = 'copy';
    p.drawImage(v, sx, sy, sw, sh, 0, 0, W, H);
    p.globalCompositeOperation = 'destination-in';
    p.imageSmoothingQuality = 'high';
    const mx = this.mask.width / vw, my = this.mask.height / vh;
    p.drawImage(this.mask, sx * mx, sy * my, sw * mx, sh * my, 0, 0, W, H);
    p.globalCompositeOperation = 'source-over';
    ctx.drawImage(this.person, 0, 0);
  }

  #updateMask(video) {
    let result;
    try {
      result = this.segmenter.segmentForVideo(video, performance.now());
    } catch (error) {
      console.warn('Segmentation failed', error);
      return false;
    }
    const masks = result?.confidenceMasks;
    if (!masks || !masks.length) { result?.close?.(); return false; }
    const m = masks[0];
    const w = m.width, h = m.height;
    const conf = m.getAsFloat32Array();
    if (this.mask.width !== w || this.mask.height !== h) {
      this.mask.width = w; this.mask.height = h;
      this.maskData = this.mctx.createImageData(w, h);
      this.smoothed = new Float32Array(w * h);
      this.maskData.data.fill(255);
    }
    const data = this.maskData.data, sm = this.smoothed;
    for (let i = 0; i < conf.length; i++) {
      // Light temporal smoothing against flicker, then a contrast curve for a cleaner edge.
      sm[i] = sm[i] * 0.35 + conf[i] * 0.65;
      const a = Math.min(1, Math.max(0, (sm[i] - 0.25) / 0.5));
      data[i * 4 + 3] = a * 255;
    }
    this.mctx.putImageData(this.maskData, 0, 0);
    result.close?.();
    return true;
  }
}
