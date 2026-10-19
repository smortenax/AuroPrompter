# AutoPrompter

An iPhone app for the daily routine: **Paste → Record → Export**.

1. **Paste** today's script. Chinese at the start and end of the script gets pinyin (with tone marks, or numbers) shown above each character. Tap any pinyin line to correct it; corrections are remembered for that phrase.
2. **Record** with the front camera. The script sits in a panel right under the lens and scrolls by following your voice (on-device speech recognition). Tap any word to re-sync. Size, margins, text opacity, shade and panel height can be adjusted on the record screen.
3. **Export** happens automatically when you stop: the background is replaced (blur, solid colour or your own image) using on-device person segmentation, the audio gets noise reduction, a voice EQ and loudness normalisation to −14 LUFS, and the video is rendered at 1080p or 4K, 30 fps, as MP4 or MOV. Save to Photos or share in one tap.

All settings live in one saved template (slider icon on the main screen), so every day's video comes out the same.

## Putting it on your iPhone

You need a Mac with Xcode 16 or newer (free from the Mac App Store) and a USB cable. A free Apple ID is enough.

1. Copy this whole `AutoPrompter` folder to the Mac and double-click `AutoPrompter.xcodeproj`.
2. In Xcode, click the **AutoPrompter** project in the left sidebar → **Signing & Capabilities** → **Team** → pick or add your Apple ID.
   If Xcode says the bundle identifier is taken, change `com.smortenax.AutoPrompter` to something unique, e.g. `com.yourname.AutoPrompter`.
3. Plug in the iPhone, unlock it, and choose it in the device menu at the top of the Xcode window.
4. Press **Run** (▶).
5. First time only, on the iPhone: **Settings → Privacy & Security → Developer Mode** → on (the phone restarts), then **Settings → General → VPN & Device Management** → trust your Apple ID.

With a free Apple ID the app keeps working for 7 days, after which you press Run again. A paid Apple Developer account ($99/year) removes that limit and allows TestFlight.

## What's where

| Folder | Contents |
| --- | --- |
| `App/` | App entry point, the saved template, app state |
| `Script/` | Script parsing and on-device pinyin (`CFStringTransform`, with 一/不 tone changes) |
| `Teleprompter/` | Voice-following (`SFSpeechRecognizer`), the script matcher, the scrolling prompter view |
| `Capture/` | Front (TrueDepth) camera capture to a portrait movie, live preview |
| `Processing/` | Background replacement (Vision person segmentation + Core Image), audio chain (spectral noise reduction, EQ, compressor, BS.1770 loudness, limiter), export, Save to Photos |
| `Views/` | Script screen, record screen, result screen, template settings |

`.github/workflows/build.yml` compiles the app on GitHub's Macs whenever the folder is pushed to a GitHub repository.

## Notes

- Requires iOS 17 or later.
- Processing time is roughly the length of the video on a recent iPhone. Keep the app open until it finishes.
- If voice following is unavailable for the chosen language, the prompter scrolls at a constant speed instead (also selectable in the template).
