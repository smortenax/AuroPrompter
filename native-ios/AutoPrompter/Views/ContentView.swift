import SwiftUI

/// Paste → check pinyin → Record.
struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSettings = false
    @State private var recording: RecordingRequest?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            let parsed = store.parsedScript
            List {
                Section {
                    TextEditor(text: $store.script)
                        .focused($editorFocused)
                        .frame(minHeight: 180)
                        .font(.body)
                    HStack {
                        Button {
                            if let text = UIPasteboard.general.string { store.script = text }
                        } label: {
                            Label("Paste today's script", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        if !store.script.isEmpty {
                            Button(role: .destructive) { store.script = "" } label: { Text("Clear") }
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Script")
                } footer: {
                    Text("\(parsed.spokenWords.count) words · about \(readingTime(parsed.spokenWords.count))")
                }

                if !parsed.runs.isEmpty {
                    Section {
                        ForEach(parsed.runs) { run in
                            PinyinRow(run: run, style: store.template.pinyinStyle)
                        }
                    } header: {
                        Text("Pronunciation")
                    } footer: {
                        Text("Tap the pinyin to correct it. Your fix is remembered for this phrase.")
                    }
                }

                Section {
                    PromptPreview(script: parsed, template: store.template)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle("AutoPrompter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    editorFocused = false
                    recording = RecordingRequest(script: parsed)
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(parsed.tokens.isEmpty)
                .padding()
                .background(.bar)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(store)
            }
            .fullScreenCover(item: $recording) { request in
                RecordView(script: request.script).environmentObject(store)
            }
        }
    }

    private func readingTime(_ words: Int) -> String {
        let seconds = Int(Double(words) / 140 * 60)
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

private struct RecordingRequest: Identifiable {
    let id = UUID()
    let script: ParsedScript
}

private struct PinyinRow: View {
    @EnvironmentObject private var store: AppStore
    let run: ChineseRun
    let style: PinyinStyle
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.text).font(.title3.bold())
                Spacer()
                if run.isOverridden {
                    Button("Reset") {
                        store.pinyinOverrides[run.text] = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            TextField("pinyin", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Color.yellow)
                .onSubmit(save)
            if syllableCount != run.text.count {
                Text("Use \(run.text.count) syllables separated by spaces.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { text = run.syllables.joined(separator: " ") }
        .onChange(of: run) { _, newRun in text = newRun.syllables.joined(separator: " ") }
    }

    private var syllableCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    private func save() {
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard syllableCount == run.text.count else { return }
        if cleaned == run.autoSyllables.joined(separator: " ") {
            store.pinyinOverrides[run.text] = nil
        } else {
            store.pinyinOverrides[run.text] = cleaned
        }
    }
}

/// A non-scrolling look at how the prompter will render.
private struct PromptPreview: View {
    let script: ParsedScript
    let template: Template

    var body: some View {
        TeleprompterView(controller: PrompterController(script: script), template: previewTemplate, interactive: false)
            .background(Color.black)
    }

    private var previewTemplate: Template {
        var t = template
        t.readingLine = 0.05
        t.fontSize = min(template.fontSize, 24)
        t.margin = 16
        return t
    }
}
