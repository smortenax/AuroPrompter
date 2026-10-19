import SwiftUI

/// App-wide state: today's script, the saved template, pronunciation fixes and the custom backdrop.
final class AppStore: ObservableObject {
    @Published var script: String {
        didSet { defaults.set(script, forKey: Keys.script) }
    }
    @Published var template: Template {
        didSet { if let data = try? JSONEncoder().encode(template) { defaults.set(data, forKey: Keys.template) } }
    }
    /// Pinyin the user corrected by hand, keyed by the Chinese phrase. Remembered across days.
    @Published var pinyinOverrides: [String: String] {
        didSet { defaults.set(pinyinOverrides, forKey: Keys.overrides) }
    }
    @Published private(set) var backgroundImage: UIImage?

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let script = "script"
        static let template = "template"
        static let overrides = "pinyinOverrides"
    }

    static var backgroundImageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("background.jpg")
    }

    init() {
        let defaults = UserDefaults.standard
        script = defaults.string(forKey: Keys.script) ?? ""
        if let data = defaults.data(forKey: Keys.template),
           let saved = try? JSONDecoder().decode(Template.self, from: data) {
            template = saved
        } else {
            template = Template()
        }
        pinyinOverrides = defaults.dictionary(forKey: Keys.overrides) as? [String: String] ?? [:]
        backgroundImage = UIImage(contentsOfFile: Self.backgroundImageURL.path)
    }

    var parsedScript: ParsedScript {
        ScriptParser.parse(script,
                           scope: template.pinyinScope,
                           style: template.pinyinStyle,
                           sandhi: template.toneSandhi,
                           overrides: pinyinOverrides)
    }

    func setBackgroundImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        try? data.write(to: Self.backgroundImageURL, options: .atomic)
        backgroundImage = image
    }

    func resetTemplate() {
        template = Template()
    }
}
