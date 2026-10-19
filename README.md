# AutoPrompter

App web para grabar el vídeo diario desde el iPhone: **Pegar → Grabar → Guardar**.

- **Guion**: pega el texto. El chino del principio y del final lleva pinyin encima (con tildes o con números). Toca el pinyin para corregirlo; la corrección se recuerda.
- **Teleprompter**: el texto va arriba, junto a la cámara, y avanza siguiendo tu voz (o a velocidad fija). Toca una palabra para saltar a ella. Tamaño, márgenes, opacidad, sombra y alto se ajustan con el botón «Aa».
- **Fondo**: difuminado, color o imagen, recortando a la persona en el propio iPhone (MediaPipe).
- **Audio**: reducción de ruido (aprende el ruido de la sala durante la cuenta atrás), ecualizador de voz, nivel automático hacia −14 LUFS y limitador.
- **Guardar**: «Guardar en Fotos» abre el menú de compartir del iPhone → «Guardar vídeo».

Todo se procesa en el teléfono; nada se sube a ningún servidor (salvo el reconocimiento de voz de Safari, que usa el servicio de Apple).

## Usarla en el iPhone

1. Abre el enlace en **Safari**.
2. Botón compartir → **Añadir a pantalla de inicio**. Se abre como una app.
3. La primera vez, permite cámara y micrófono.

## Estructura

| Ruta | Qué hay |
| --- | --- |
| `index.html`, `style.css` | Pantallas: guion, grabación, resultado, plantilla |
| `js/app.js` | Flujo de la app y ajustes guardados |
| `js/script.js` | Guion → palabras y caracteres chinos con pinyin (pinyin-pro) |
| `js/matcher.js`, `js/speech.js` | Seguimiento de la voz |
| `js/compositor.js` | Recorte de la persona y fondo, a 9:16 |
| `js/audio.js`, `js/voice-worklet.js` | Cadena de audio |
| `vendor/` | MediaPipe Tasks Vision 0.10.14, modelo selfie_segmenter, pinyin-pro 3.26.0 |
| `native-ios/` | Versión nativa en SwiftUI (necesita Xcode en un Mac) |

Se publica sola en GitHub Pages con cada cambio en `main` (`.github/workflows/pages.yml`).
