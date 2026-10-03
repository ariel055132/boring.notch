//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0

    private struct ScrollIdentity: Hashable {
        let text: String
        let textWidth: CGFloat
        let frameWidth: CGFloat
    }
    
    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }
    
    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }

    private var scrollIdentity: ScrollIdentity {
        ScrollIdentity(text: text, textWidth: textSize.width, frameWidth: frameWidth)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 20) {
                    Text(text)
                    Text(text)
                        .opacity(needsScrolling ? 1 : 0)
                }
                .id(text)
                .font(font)
                .foregroundColor(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: self.animate ? offset : 0)
                .animation(
                    self.animate ?
                        .linear(duration: Double(textSize.width / 30))
                        .delay(minDuration)
                        .repeatForever(autoreverses: false) : .linear(duration: 0),
                    value: self.animate
                )
                .id(scrollIdentity)
                .background(backgroundColor)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    // The HStack contains two copies separated by a 20-point gap.
                    textSize = CGSize(width: max(0, (size.width - 20) / 2), height: size.height)
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: NSFont.preferredFont(forTextStyle: nsFont).pointSize * 1.3)
        .task(id: scrollIdentity) {
            // Reset when the text or its available width changes, including mirror toggles.
            animate = false
            offset = 0
            guard frameWidth > 0, needsScrolling else { return }
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            offset = -(textSize.width + 20)
            animate = true
        }
    }
}
