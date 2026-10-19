import PhotosUI
import Speech
import SwiftUI

/// The daily template. Everything here is saved and reused for every recording.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?

    private struct Language: Identifiable {
        let id: String
        let name: String
    }

    private let languages: [Language] = {
        let current = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { Language(id: $0.identifier, name: current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("Teleprompter") {
                    Picker("Scrolling", selection: $store.template.scrollMode) {
                        ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                    }
                    if store.template.scrollMode == .voice {
                        Picker("Spoken language", selection: $store.template.speechLocale) {
                            ForEach(languages) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        Stepper("Speed: \(Int(store.template.wordsPerMinute)) words/min",
                                value: $store.template.wordsPerMinute, in: 60...260, step: 10)
                    }
                    labeled("Font size", value: $store.template.fontSize, range: 18...72, format: "%.0f pt")
                    labeled("Margins", value: $store.template.margin, range: 0...80, format: "%.0f pt")
                    labeled("Text opacity", value: $store.template.textOpacity, range: 0.3...1, percent: true)
                    labeled("Shade behind text", value: $store.template.panelOpacity, range: 0...0.9, percent: true)
                    labeled("Prompter height", value: $store.template.panelHeight, range: 0.2...0.8, percent: true)
                    labeled("Reading line", value: $store.template.readingLine, range: 0...0.6, percent: true)
                }

                Section {
                    Picker("Show pinyin for", selection: $store.template.pinyinScope) {
                        ForEach(PinyinScope.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Style", selection: $store.template.pinyinStyle) {
                        ForEach(PinyinStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Tone changes for 一 and 不", isOn: $store.template.toneSandhi)
                    if !store.pinyinOverrides.isEmpty {
                        Button("Forget \(store.pinyinOverrides.count) pinyin corrections", role: .destructive) {
                            store.pinyinOverrides = [:]
                        }
                    }
                } header: {
                    Text("Pinyin")
                }

                Section("Background") {
                    Picker("Background", selection: $store.template.backgroundMode) {
                        ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch store.template.backgroundMode {
                    case .original:
                        Text("The real background is kept.").foregroundStyle(.secondary)
                    case .blur:
                        labeled("Blur strength", value: $store.template.blurRadius, range: 5...60, format: "%.0f")
                    case .color:
                        ColorPicker("Color", selection: Binding(
                            get: { store.template.backgroundColor.color },
                            set: { store.template.backgroundColor = RGBA($0) }
                        ), supportsOpacity: false)
                    case .image:
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            HStack {
                                Text(store.backgroundImage == nil ? "Choose image" : "Change image")
                                Spacer()
                                if let image = store.backgroundImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Clean up audio", isOn: $store.template.enhanceAudio)
                    if store.template.enhanceAudio {
                        labeled("Noise reduction", value: $store.template.noiseReductionDB, range: 0...24, format: "%.0f dB")
                        Toggle("Voice EQ", isOn: $store.template.voiceEQ)
                        Picker("Loudness", selection: $store.template.targetLUFS) {
                            Text("−14 LUFS (YouTube, Spotify)").tag(-14.0)
                            Text("−15 LUFS").tag(-15.0)
                            Text("−16 LUFS (Apple)").tag(-16.0)
                        }
                    }
                } header: {
                    Text("Audio")
                }

                Section("Export") {
                    Picker("Resolution", selection: $store.template.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Format", selection: $store.template.fileFormat) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Mirror video", isOn: $store.template.mirrorVideo)
                    Toggle("Save to Photos automatically", isOn: $store.template.autoSaveToPhotos)
                }

                Section {
                    Button("Reset template to defaults", role: .destructive) { store.resetTemplate() }
                }
            }
            .navigationTitle("Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { store.setBackgroundImage(image) }
                    }
                }
            }
        }
    }

    private func labeled(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                         format: String = "%.0f", percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int(value.wrappedValue * 100))%" : String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
