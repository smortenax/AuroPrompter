import SwiftUI

/// Everything that controls how a recording looks and sounds. Saved once and reused every day
/// so the output is identical from one video to the next.
struct Template: Codable, Equatable {
    // Teleprompter
    var fontSize: Double = 30
    var margin: Double = 24
    var textOpacity: Double = 1.0
    var panelOpacity: Double = 0.45
    /// Fraction of the screen height used by the prompter panel (pinned to the top, next to the lens).
    var panelHeight: Double = 0.42
    /// Where the line being read sits inside the panel (0 = top edge).
    var readingLine: Double = 0.2
    var scrollMode: ScrollMode = .voice
    var wordsPerMinute: Double = 140
    var speechLocale: String = "en-US"

    // Pinyin
    var pinyinStyle: PinyinStyle = .toneMarks
    var pinyinScope: PinyinScope = .edges
    var toneSandhi: Bool = true

    // Background
    var backgroundMode: BackgroundMode = .blur
    var backgroundColor: RGBA = RGBA(red: 0.09, green: 0.36, blue: 0.29)
    var blurRadius: Double = 25

    // Audio
    var enhanceAudio: Bool = true
    var noiseReductionDB: Double = 12
    var voiceEQ: Bool = true
    var targetLUFS: Double = -14

    // Export
    var resolution: ExportResolution = .hd1080
    var fileFormat: ExportFormat = .mp4
    var mirrorVideo: Bool = false
    var autoSaveToPhotos: Bool = false
}

enum ScrollMode: String, Codable, CaseIterable, Identifiable {
    case voice, constant
    var id: String { rawValue }
    var label: String { self == .voice ? "Follow my voice" : "Constant speed" }
}

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case original, blur, color, image
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .blur: return "Blur"
        case .color: return "Color"
        case .image: return "Image"
        }
    }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080, uhd4K
    var id: String { rawValue }
    var label: String { self == .hd1080 ? "1080p" : "4K" }
    /// Portrait output size.
    var renderSize: CGSize { self == .hd1080 ? CGSize(width: 1080, height: 1920) : CGSize(width: 2160, height: 3840) }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct RGBA: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
}
