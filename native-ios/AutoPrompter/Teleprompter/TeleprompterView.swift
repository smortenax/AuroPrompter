import SwiftUI

/// The scrolling script, with pinyin above Chinese characters and the current line held at the reading line.
struct TeleprompterView: View {
    @ObservedObject var controller: PrompterController
    let template: Template
    var interactive = true

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    FlowLayout(spacing: template.fontSize * 0.28,
                               lineSpacing: template.fontSize * 0.35,
                               paragraphSpacing: template.fontSize * 0.6) {
                        ForEach(controller.script.tokens) { token in
                            tokenView(token)
                                .id(token.id)
                        }
                    }
                    .padding(.top, geometry.size.height * template.readingLine)
                    .padding(.bottom, geometry.size.height)
                    .padding(.horizontal, template.margin)
                }
                .scrollDisabled(!interactive)
                .onChange(of: controller.currentToken) { _, token in
                    let target = min(token, max(controller.script.tokens.count - 1, 0))
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: template.readingLine))
                    }
                }
                .onAppear {
                    proxy.scrollTo(controller.currentToken, anchor: UnitPoint(x: 0.5, y: template.readingLine))
                }
            }
        }
        .opacity(template.textOpacity)
    }

    @ViewBuilder
    private func tokenView(_ token: ScriptToken) -> some View {
        let done = token.id < controller.currentToken
        let current = token.id == controller.currentToken
        switch token.kind {
        case .lineBreak:
            Color.clear.frame(width: 0, height: 0).layoutValue(key: LineBreakKey.self, value: true)
        case .han:
            VStack(spacing: 0) {
                if let pinyin = token.pinyin {
                    Text(pinyin)
                        .font(.system(size: template.fontSize * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.yellow)
                }
                Text(token.text)
                    .font(.system(size: template.fontSize, weight: .semibold))
            }
            .foregroundStyle(.white)
            .opacity(done ? 0.4 : 1)
            .onTapGesture { if interactive { controller.jump(toToken: token.id) } }
        case .word:
            Text(token.text)
                .font(.system(size: template.fontSize, weight: .semibold))
                .foregroundStyle(current ? Color.yellow : Color.white)
                .opacity(done ? 0.4 : 1)
                .onTapGesture { if interactive { controller.jump(toToken: token.id) } }
        }
    }
}

struct LineBreakKey: LayoutValueKey {
    static let defaultValue = false
}

/// Wraps words like text, bottom-aligning each row so pinyin sits above its characters.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let frames = arrange(width: width, subviews: subviews)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var row: [Int] = []

        func finishRow() {
            for i in row { frames[i].origin.y = y + rowHeight - frames[i].height }
            y += rowHeight + lineSpacing
            x = 0
            rowHeight = 0
            row.removeAll()
        }

        for (index, subview) in subviews.enumerated() {
            if subview[LineBreakKey.self] {
                if row.isEmpty { y += paragraphSpacing } else { finishRow() }
                frames[index] = CGRect(x: 0, y: y, width: 0, height: 0)
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { finishRow() }
            frames[index] = CGRect(origin: CGPoint(x: x, y: 0), size: size)
            row.append(index)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if !row.isEmpty { finishRow() }
        return frames
    }
}
