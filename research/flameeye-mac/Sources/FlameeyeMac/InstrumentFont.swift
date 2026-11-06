import AppKit
import SwiftUI

enum InstrumentFont {
    private static let regularName = availableName("LG1055-Regular")
    private static let lightName = availableName("LG1055Light-Light")

    static func style(_ textStyle: Font.TextStyle, light: Bool = false) -> Font {
        let points: CGFloat
        switch textStyle {
        case .largeTitle: points = 26
        case .title: points = 22
        case .title2: points = 17
        case .title3: points = 15
        case .headline, .body: points = 13
        case .callout: points = 12
        case .subheadline: points = 11
        case .footnote, .caption, .caption2: points = 10
        @unknown default: points = 13
        }

        if let name = name(light: light) {
            return .custom(name, size: points, relativeTo: textStyle)
        }
        return .system(textStyle)
    }

    static func size(_ points: CGFloat, light: Bool = false) -> Font {
        if let name = name(light: light) {
            return .custom(name, fixedSize: points)
        }
        return .system(size: points, weight: light ? .light : .regular)
    }

    static func controlText(_ title: String) -> Text {
        Text(title).font(style(.body))
    }

    static func controlLabel(_ title: String, systemImage: String) -> some View {
        Label {
            controlText(title)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    static func native(_ points: CGFloat) -> NSFont {
        regularName.flatMap { NSFont(name: $0, size: points) } ?? .systemFont(ofSize: points)
    }

    private static func name(light: Bool) -> String? {
        light ? lightName ?? regularName : regularName
    }

    private static func availableName(_ name: String) -> String? {
        NSFont(name: name, size: 13) == nil ? nil : name
    }
}

struct InstrumentPopup<Value: Equatable>: NSViewRepresentable {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, values: options.map(\.value)) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.font = InstrumentFont.native(NSFont.systemFontSize)
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectValue(_:))
        control.setAccessibilityLabel(label)
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.values = options.map(\.value)
        let titles = options.map(\.title)
        if control.itemTitles != titles {
            control.removeAllItems()
            control.addItems(withTitles: titles)
            let font = control.font ?? InstrumentFont.native(NSFont.systemFontSize)
            for item in control.itemArray {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
        control.selectItem(at: context.coordinator.values.firstIndex(of: selection) ?? 0)
        control.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        var values: [Value]

        init(selection: Binding<Value>, values: [Value]) {
            self.selection = selection
            self.values = values
        }

        @objc func selectValue(_ control: NSPopUpButton) {
            let index = control.indexOfSelectedItem
            guard values.indices.contains(index) else { return }
            selection.wrappedValue = values[index]
        }
    }
}
